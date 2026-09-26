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
        signal(process, with: SIGTERM)
        if process.isRunning {
            let deadline = ProviderDeadline(after: gracePeriod)
            while process.isRunning && !deadline.hasExpired {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        // The direct child can exit while a descendant still owns a pipe.
        signal(process, with: SIGKILL)
        terminationWaiter.waitUntilTerminated()
    }

    static func signal(_ process: Process, with signal: Int32) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        // Foundation spawns Process children in their own process group on
        // macOS. The group id remains the original child's pid after exit.
        _ = Darwin.kill(-pid, signal)
        if process.isRunning { _ = Darwin.kill(pid, signal) }
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
        startedHandler: (@Sendable (pid_t) -> Void)? = nil,
        registry: ProviderProcessRegistry = .shared
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
        let outputReader = ProviderPipeReader(handle: output.fileHandleForReading) {
            collector.append($0)
        }
        let errorReader = ProviderPipeReader(handle: errors.fileHandleForReading) {
            errorCollector.append($0)
        }
        defer {
            outputReader.finish()
            errorReader.finish()
        }

        do {
            try outputReader.validate()
            try errorReader.validate()
            try registry.start(process, waiter: terminationWaiter)
            startedHandler?(process.processIdentifier)
        } catch ProviderProcessFailure.cancelled {
            throw ProviderProcessFailure.cancelled
        } catch {
            throw ProviderProcessFailure.launchFailed
        }
        defer {
            ProviderProcessLifecycle.terminateAndReap(
                process, terminationWaiter: terminationWaiter
            )
            registry.remove(process)
        }

        let deadline = ProviderDeadline(after: timeout)
        var exitGrace: ProviderDeadline?
        while true {
            if cancellationCheck() { throw ProviderProcessFailure.cancelled }
            let outputEnded = outputReader.drain()
            let errorsEnded = errorReader.drain()
            if !process.isRunning {
                if outputEnded && errorsEnded { break }
                if exitGrace == nil { exitGrace = ProviderDeadline(after: 0.25) }
                if exitGrace?.hasExpired == true || deadline.hasExpired { break }
            } else if deadline.hasExpired {
                throw ProviderProcessFailure.timedOut
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        ProviderProcessLifecycle.terminateAndReap(process, terminationWaiter: terminationWaiter)
        outputReader.finish()
        errorReader.finish()
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
        startedHandler: (@Sendable (pid_t) -> Void)? = nil,
        registry: ProviderProcessRegistry = .shared
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
                            startedHandler: startedHandler,
                            registry: registry
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

/// One reader owns each pipe. Reads are nonblocking and serialized with
/// teardown, so removing a Foundation callback cannot race the final drain.
final class ProviderPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let receive: @Sendable (Data) -> Void
    private let lock = NSLock()
    private let isReady: Bool
    private var reachedEOF = false
    private var stopped = false

    init(handle: FileHandle, receive: @escaping @Sendable (Data) -> Void) {
        self.handle = handle
        self.receive = receive
        let flags = fcntl(handle.fileDescriptor, F_GETFL)
        isReady = flags != -1
            && fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) != -1
    }

    func validate() throws {
        guard isReady else { throw ProviderProcessFailure.launchFailed }
    }

    @discardableResult
    func drain() -> Bool {
        lock.withLock {
            guard !stopped else { return true }
            return readAvailable()
        }
    }

    func finish() {
        lock.withLock {
            guard !stopped else { return }
            _ = readAvailable()
            stopped = true
            try? handle.close()
        }
    }

    private func readAvailable() -> Bool {
        guard isReady, !reachedEOF else { return true }
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        // Bound each pass even if a provider writes continuously, so the
        // caller can still check cancellation and its operation deadline.
        for _ in 0..<64 {
            let count = Darwin.read(handle.fileDescriptor, &buffer, buffer.count)
            if count > 0 {
                receive(Data(buffer.prefix(count)))
            } else if count == 0 {
                reachedEOF = true
                return true
            } else if errno != EINTR {
                if errno != EAGAIN && errno != EWOULDBLOCK {
                    reachedEOF = true
                }
                return reachedEOF
            }
        }
        return false
    }
}

/// Keeps provider children reachable by the synchronous application-exit
/// callback. Closing admission under the same lock as spawn covers workers
/// that were queued when the app began quitting.
final class ProviderProcessRegistry: @unchecked Sendable {
    static let shared = ProviderProcessRegistry()

    private struct Entry {
        let process: Process
        let waiter: ProviderProcessTerminationWaiter
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var isTerminating = false

    func start(_ process: Process, waiter: ProviderProcessTerminationWaiter) throws {
        try lock.withLock {
            guard !isTerminating else { throw ProviderProcessFailure.cancelled }
            try process.run()
            entries[ObjectIdentifier(process)] = Entry(process: process, waiter: waiter)
        }
    }

    func remove(_ process: Process) {
        _ = lock.withLock { entries.removeValue(forKey: ObjectIdentifier(process)) }
    }

    func terminateAll() {
        let active = lock.withLock {
            isTerminating = true
            return Array(entries.values)
        }
        // Signal every group first; quit time does not grow by one grace
        // period for each simultaneous account operation.
        for entry in active {
            ProviderProcessLifecycle.signal(entry.process, with: SIGKILL)
        }
        for entry in active {
            entry.waiter.waitUntilTerminated()
        }
    }
}
