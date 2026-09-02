import Darwin
import Foundation

struct ProviderSubprocessEnvironment {
    private static let safePath =
        "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    private static let inheritedLocaleKeys: Set<String> = [
        "LANG",
        "LC_ALL",
        "LC_COLLATE",
        "LC_CTYPE",
        "LC_MESSAGES",
        "LC_MONETARY",
        "LC_NUMERIC",
        "LC_TIME",
        "__CF_USER_TEXT_ENCODING",
    ]
    private static let allowedAdditions: Set<String> = [
        "CLAUDE_CONFIG_DIR",
        "CODEX_HOME",
        "LANG",
        "LC_ALL",
        "TZ",
    ]

    static func make(
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        identity: ChildEnvironmentIdentity = .current,
        additions: [String: String] = [:]
    ) -> [String: String] {
        var environment = processEnvironment.filter {
            inheritedLocaleKeys.contains($0.key)
        }
        environment["PATH"] = safePath
        environment["HOME"] = identity.homeDirectory
        environment["USER"] = identity.userName
        environment["LOGNAME"] = identity.userName
        environment["TMPDIR"] = identity.temporaryDirectory
        for (key, value) in additions where allowedAdditions.contains(key) {
            environment[key] = value
        }
        return environment
    }
}

final class ProviderProcessOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()

    init(maximumBytes: Int = 64 * 1_024) {
        self.maximumBytes = maximumBytes
    }

    func append(_ incoming: Data) {
        guard !incoming.isEmpty else { return }
        lock.withLock {
            data.append(incoming)
            if data.count > maximumBytes {
                data = Data(data.suffix(maximumBytes))
            }
        }
    }

    func string() -> String {
        lock.withLock {
            String(data: data, encoding: .utf8) ?? ""
        }
    }
}

struct ProviderDeadline: Sendable {
    private let uptime: TimeInterval

    init(after seconds: TimeInterval) {
        uptime = ProcessInfo.processInfo.systemUptime + max(0, seconds)
    }

    var hasExpired: Bool {
        ProcessInfo.processInfo.systemUptime >= uptime
    }
}

enum ProviderProcessFailure: Error, Equatable {
    case unsafeExecutable
    case launchFailed
    case timedOut
    case cancelled
}

struct ProviderProcessResult: Equatable {
    let status: Int32
    /// Standard output only. Provider JSON is parsed from this stream, so
    /// stderr diagnostics can never corrupt it.
    let output: String
    let errorOutput: String

    init(status: Int32, output: String, errorOutput: String = "") {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
    }
}


enum ProviderProcessLifecycle {
    static func terminateAndReap(
        _ process: Process,
        terminationWaiter: ProviderProcessTerminationWaiter,
        gracePeriod: TimeInterval = 0.25
    ) {
        if process.isRunning {
            process.terminate()
            let deadline = ProviderDeadline(after: gracePeriod)
            while process.isRunning && !deadline.hasExpired {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        terminationWaiter.waitUntilTerminated()
    }
}

/// Waits for Foundation's process-termination callback without depending on
/// the run loop of whichever executor thread performs teardown.
final class ProviderProcessTerminationWaiter: @unchecked Sendable {
    private let condition = NSCondition()
    private var terminated = false

    func install(on process: Process) {
        process.terminationHandler = { [weak self] _ in
            self?.recordTermination()
        }
    }

    func waitUntilTerminated() {
        condition.lock()
        defer { condition.unlock() }
        while !terminated {
            condition.wait()
        }
    }

    private func recordTermination() {
        condition.lock()
        terminated = true
        condition.broadcast()
        condition.unlock()
    }
}

struct ProviderProcessRunner {
    static func run(
        executable: TrustedProviderExecutable,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        cancellationCheck: @escaping @Sendable () -> Bool = { false },
        startedHandler: (@Sendable (pid_t) -> Void)? = nil
    ) throws -> ProviderProcessResult {
        guard timeout.isFinite, timeout > 0 else {
            throw ProviderProcessFailure.timedOut
        }

        let executableURL: URL
        do {
            executableURL = try executable.revalidatedURL()
        } catch {
            throw ProviderProcessFailure.unsafeExecutable
        }
        guard !cancellationCheck() else {
            throw ProviderProcessFailure.cancelled
        }

        let process = Process()
        let terminationWaiter = ProviderProcessTerminationWaiter()
        let output = Pipe()
        let errors = Pipe()
        let collector = ProviderProcessOutputCollector(maximumBytes: 256 * 1_024)
        let errorCollector = ProviderProcessOutputCollector()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProviderSubprocessEnvironment.make(
            additions: environment
        )
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        terminationWaiter.install(on: process)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            collector.append(data)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            errorCollector.append(data)
        }

        do {
            try process.run()
            startedHandler?(process.processIdentifier)
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            throw ProviderProcessFailure.launchFailed
        }

        let deadline = ProviderDeadline(after: timeout)
        var failure: ProviderProcessFailure?
        while process.isRunning {
            if cancellationCheck() {
                failure = .cancelled
                break
            }
            if deadline.hasExpired {
                failure = .timedOut
                break
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        if failure != nil {
            ProviderProcessLifecycle.terminateAndReap(
                process,
                terminationWaiter: terminationWaiter
            )
        } else {
            terminationWaiter.waitUntilTerminated()
        }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        if let failure {
            // A killed child may have left a grandchild holding the pipe's
            // write end; draining to EOF here could block indefinitely and the
            // partial output is discarded anyway.
            throw failure
        }
        collector.append(output.fileHandleForReading.readDataToEndOfFile())
        errorCollector.append(errors.fileHandleForReading.readDataToEndOfFile())
        return ProviderProcessResult(
            status: process.terminationStatus,
            output: collector.string().trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            errorOutput: errorCollector.string().trimmingCharacters(
                in: .whitespacesAndNewlines
            )
        )
    }

    private static let blockingQueue = DispatchQueue(
        label: "com.parallax.provider-process",
        qos: .utility,
        attributes: .concurrent
    )

    /// Runs the blocking runner on a dedicated dispatch queue so a slow
    /// provider tool never pins a thread of the Swift cooperative pool.
    /// Cancelling the calling task terminates and reaps the child.
    static func runDetached(
        executable: TrustedProviderExecutable,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval,
        startedHandler: (@Sendable (pid_t) -> Void)? = nil
    ) async throws -> ProviderProcessResult {
        guard !Task.isCancelled else {
            throw ProviderProcessFailure.cancelled
        }
        let flag = CancellationFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                blockingQueue.async {
                    do {
                        let result = try run(
                            executable: executable,
                            arguments: arguments,
                            environment: environment,
                            timeout: timeout,
                            cancellationCheck: { flag.isCancelled },
                            startedHandler: startedHandler
                        )
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }
}
