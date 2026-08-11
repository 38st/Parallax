import Darwin
import Foundation

public enum RelayGitOutputStream: String, Equatable, Sendable {
    case standardOutput
    case standardError
}

public enum RelayGitCommandError: Error, Equatable, Sendable {
    case unsafeExecutable(String)
    case invalidWorkingDirectory(String)
    case launchFailed
    case timedOut
    case outputLimitExceeded(stream: RelayGitOutputStream, limit: Int)
    case rejectedExitStatus(Int32)
}

public struct RelayGitCommandResult: Equatable, Sendable {
    public let standardOutput: Data
    public let standardError: Data
    public let exitStatus: Int32

    public init(
        standardOutput: Data,
        standardError: Data,
        exitStatus: Int32
    ) {
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.exitStatus = exitStatus
    }
}

public protocol RelayGitCommandRunning: Sendable {
    func run(
        arguments: [String],
        workingDirectory: URL?,
        standardOutputLimit: Int,
        standardErrorLimit: Int,
        timeout: TimeInterval,
        acceptedExitStatuses: Set<Int32>
    ) throws -> RelayGitCommandResult
}

extension RelayGitCommandRunning {
    public func run(
        arguments: [String],
        workingDirectory: URL?,
        standardOutputLimit: Int,
        standardErrorLimit: Int = 64 * 1_024,
        timeout: TimeInterval = 30,
        acceptedExitStatuses: Set<Int32> = [0]
    ) throws -> RelayGitCommandResult {
        try run(
            arguments: arguments,
            workingDirectory: workingDirectory,
            standardOutputLimit: standardOutputLimit,
            standardErrorLimit: standardErrorLimit,
            timeout: timeout,
            acceptedExitStatuses: acceptedExitStatuses
        )
    }
}

/// Runs only a caller-supplied argument vector. Repository hooks, interactive
/// prompting, pagers, ambient Git configuration, and optional lock writes are
/// disabled for every custody operation.
public struct RelaySystemGitRunner: RelayGitCommandRunning, Sendable {
    private let gitURL: URL
    private let currentUserID: uid_t

    public init(
        gitURL: URL = URL(fileURLWithPath: "/usr/bin/git"),
        currentUserID: uid_t = getuid()
    ) {
        self.gitURL = gitURL
        self.currentUserID = currentUserID
    }

    public func run(
        arguments: [String],
        workingDirectory: URL?,
        standardOutputLimit: Int,
        standardErrorLimit: Int,
        timeout: TimeInterval,
        acceptedExitStatuses: Set<Int32>
    ) throws -> RelayGitCommandResult {
        guard standardOutputLimit >= 0, standardErrorLimit >= 0 else {
            throw RelayGitCommandError.outputLimitExceeded(
                stream: .standardOutput,
                limit: max(0, standardOutputLimit)
            )
        }
        guard timeout.isFinite, timeout > 0 else {
            throw RelayGitCommandError.timedOut
        }

        let executable = try trustedExecutable()
        if let workingDirectory {
            guard
                workingDirectory.isFileURL,
                FileManager.default.fileExists(
                    atPath: workingDirectory.path,
                    isDirectory: nil
                )
            else {
                throw RelayGitCommandError.invalidWorkingDirectory(
                    workingDirectory.path
                )
            }
        }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let output = RelayBoundedGitOutput(limit: standardOutputLimit)
        let errors = RelayBoundedGitOutput(limit: standardErrorLimit)

        process.executableURL = executable
        process.arguments = Self.policyArguments + arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = Self.environment()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        outputPipe.fileHandleForReading.readabilityHandler = { handle in
            output.append(handle.availableData)
        }
        errorPipe.fileHandleForReading.readabilityHandler = { handle in
            errors.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            throw RelayGitCommandError.launchFailed
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning,
              ProcessInfo.processInfo.systemUptime < deadline
        {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
            let terminationDeadline =
                ProcessInfo.processInfo.systemUptime + 0.25
            while process.isRunning,
                  ProcessInfo.processInfo.systemUptime < terminationDeadline
            {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            outputPipe.fileHandleForReading.readabilityHandler = nil
            errorPipe.fileHandleForReading.readabilityHandler = nil
            output.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
            errors.append(errorPipe.fileHandleForReading.readDataToEndOfFile())
            throw RelayGitCommandError.timedOut
        }

        process.waitUntilExit()
        outputPipe.fileHandleForReading.readabilityHandler = nil
        errorPipe.fileHandleForReading.readabilityHandler = nil
        output.append(outputPipe.fileHandleForReading.readDataToEndOfFile())
        errors.append(errorPipe.fileHandleForReading.readDataToEndOfFile())

        if output.didExceedLimit {
            throw RelayGitCommandError.outputLimitExceeded(
                stream: .standardOutput,
                limit: standardOutputLimit
            )
        }
        if errors.didExceedLimit {
            throw RelayGitCommandError.outputLimitExceeded(
                stream: .standardError,
                limit: standardErrorLimit
            )
        }
        guard acceptedExitStatuses.contains(process.terminationStatus) else {
            throw RelayGitCommandError.rejectedExitStatus(
                process.terminationStatus
            )
        }
        return RelayGitCommandResult(
            standardOutput: output.data,
            standardError: errors.data,
            exitStatus: process.terminationStatus
        )
    }

    private func trustedExecutable() throws -> URL {
        guard gitURL.isFileURL, gitURL.path.hasPrefix("/") else {
            throw RelayGitCommandError.unsafeExecutable(gitURL.path)
        }
        guard let resolved = realpath(gitURL.path, nil) else {
            throw RelayGitCommandError.unsafeExecutable(gitURL.path)
        }
        defer { free(resolved) }
        let canonical = URL(fileURLWithPath: String(cString: resolved))
        var facts = stat()
        guard
            lstat(canonical.path, &facts) == 0,
            facts.st_mode & S_IFMT == S_IFREG,
            facts.st_mode & 0o022 == 0,
            facts.st_uid == 0 || facts.st_uid == currentUserID,
            access(canonical.path, X_OK) == 0
        else {
            throw RelayGitCommandError.unsafeExecutable(gitURL.path)
        }
        return canonical
    }

    private static let policyArguments = [
        "--no-pager",
        "-c", "core.hooksPath=/dev/null",
        "-c", "core.fsmonitor=false",
        "-c", "core.untrackedCache=false",
        "-c", "credential.helper=",
    ]

    private static func environment() -> [String: String] {
        var result = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LC_ALL": "C",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_PAGER": "cat",
            "PAGER": "cat",
        ]
        if let temporary = ProcessInfo.processInfo.environment["TMPDIR"] {
            result["TMPDIR"] = temporary
        }
        return result
    }
}

private final class RelayBoundedGitOutput: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var storage = Data()
    private var exceeded = false

    init(limit: Int) {
        self.limit = max(0, limit)
    }

    func append(_ incoming: Data) {
        guard !incoming.isEmpty else { return }
        lock.withLock {
            let remaining = max(0, limit - storage.count)
            if remaining > 0 {
                storage.append(incoming.prefix(remaining))
            }
            if incoming.count > remaining {
                exceeded = true
            }
        }
    }

    var data: Data {
        lock.withLock { storage }
    }

    var didExceedLimit: Bool {
        lock.withLock { exceeded }
    }
}
