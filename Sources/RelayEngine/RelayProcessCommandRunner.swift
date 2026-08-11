import CryptoKit
import Darwin
import Foundation
import RelayCore

public protocol RelayCommandProcessLaunching: Sendable {
    var capabilityReport: RelaySandboxCapabilityReport { get }

    func launch(
        executable: RelayExecutableIdentity,
        arguments: [String],
        workingDirectory: URL,
        environment: RelayMinimalEnvironment,
        onStandardOutput: @escaping @Sendable (Data) -> Void,
        onStandardError: @escaping @Sendable (Data) -> Void
    ) throws -> RelayManagedProcess
}

/// The only bundled process launcher in the local MVP. Its capability report
/// is intentionally unsafe, so secure-default command authorization blocks it.
public struct RelayUnsafeHostCommandLauncher:
    RelayCommandProcessLaunching,
    Sendable
{
    public let capabilityReport = RelaySandboxCapabilityReport.unsafeHostProcess

    public init() {}

    public func launch(
        executable: RelayExecutableIdentity,
        arguments: [String],
        workingDirectory: URL,
        environment: RelayMinimalEnvironment,
        onStandardOutput: @escaping @Sendable (Data) -> Void,
        onStandardError: @escaping @Sendable (Data) -> Void
    ) throws -> RelayManagedProcess {
        try RelayManagedProcess.launch(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            onStandardOutput: onStandardOutput,
            onStandardError: onStandardError,
            publishesOutputStreams: false
        )
    }
}

public struct RelayAuthorizedCommandRunner<Launcher: RelayCommandProcessLaunching>:
    Sendable
{
    public let launcher: Launcher
    public let redactor: RelayEvidenceRedactor

    public init(
        launcher: Launcher,
        redactor: RelayEvidenceRedactor = RelayEvidenceRedactor()
    ) {
        self.launcher = launcher
        self.redactor = redactor
    }

    public func run(
        authorization: RelayStageExecutionAuthorization,
        arguments: [String],
        workingDirectory: URL,
        environment: RelayMinimalEnvironment
    ) async -> RelayCommandEvidence {
        let started = ContinuousClock.now
        let commandDigest = Self.commandDigest(
            executable: authorization.executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment
        )
        let budget = authorization.policy.commandBudget
        let output = RelayBoundedCommandStream(
            limit: budget.maximumStandardOutputBytes
        )
        let standardError = RelayBoundedCommandStream(
            limit: budget.maximumStandardErrorBytes
        )

        guard !authorization.revocation.isRevoked else {
            return rejectedEvidence(
                authorization: authorization,
                commandDigest: commandDigest,
                rejection: .stageCapabilityRejected,
                output: output,
                error: standardError,
                started: started
            )
        }

        switch RelaySandboxValidator().validate(
            launcher.capabilityReport,
            against: authorization.policy.sandboxRequirements
        ) {
        case .blocked(let blockers):
            return rejectedEvidence(
                authorization: authorization,
                commandDigest: commandDigest,
                rejection: .sandboxUnsupported(blockers),
                output: output,
                error: standardError,
                started: started
            )
        case .authorized(let actual):
            guard actual == authorization.sandbox else {
                return rejectedEvidence(
                    authorization: authorization,
                    commandDigest: commandDigest,
                    rejection: .stageCapabilityRejected,
                    output: output,
                    error: standardError,
                    started: started
                )
            }
        }

        guard Self.isSafeWorkingDirectory(
            workingDirectory,
            workspace: authorization.policy.workspaceIdentity
        ) else {
            return rejectedEvidence(
                authorization: authorization,
                commandDigest: commandDigest,
                rejection: .invalidWorkingDirectory,
                output: output,
                error: standardError,
                started: started
            )
        }
        guard authorization.executable.matchesCurrentFile() else {
            return rejectedEvidence(
                authorization: authorization,
                commandDigest: commandDigest,
                rejection: .executableChanged,
                output: output,
                error: standardError,
                started: started
            )
        }

        let process: RelayManagedProcess
        do {
            process = try launcher.launch(
                executable: authorization.executable,
                arguments: arguments,
                workingDirectory: workingDirectory,
                environment: environment,
                onStandardOutput: output.append,
                onStandardError: standardError.append
            )
        } catch RelayManagedProcessError.processIdentityUnavailable {
            return rejectedEvidence(
                authorization: authorization,
                commandDigest: commandDigest,
                rejection: .processIdentityUnavailable,
                output: output,
                error: standardError,
                started: started
            )
        } catch {
            return rejectedEvidence(
                authorization: authorization,
                commandDigest: commandDigest,
                rejection: .processLaunchFailed,
                output: output,
                error: standardError,
                started: started
            )
        }

        let outcome = await awaitOutcome(
            process: process,
            authorization: authorization,
            started: started
        )
        return RelayCommandEvidence(
            commandDigest: commandDigest,
            workspaceDigest: authorization.policy.workspaceDigest,
            sandboxCapabilityDigest: authorization.sandbox.capabilityDigest,
            executableIdentity: authorization.executable,
            processIdentity: process.processIdentity,
            termination: outcome,
            standardOutput: output.finalize(redactor: redactor),
            standardError: standardError.finalize(redactor: redactor),
            elapsed: started.duration(to: .now)
        )
    }

    private func awaitOutcome(
        process: RelayManagedProcess,
        authorization: RelayStageExecutionAuthorization,
        started: ContinuousClock.Instant
    ) async -> RelayCommandTermination {
        let budget = authorization.policy.commandBudget
        let pollInterval = Duration.milliseconds(25)

        while true {
            if let termination = await process.waitUntilExit(upTo: pollInterval) {
                return Self.commandTermination(termination)
            }
            if Task.isCancelled || authorization.revocation.isRevoked {
                let control = await process.terminateAndReap(
                    interruptGrace: budget.interruptGrace,
                    terminateGrace: budget.terminateGrace
                )
                if case .reaped = control { return .cancelled }
                return .launchRejected(.processControlFailed(control))
            }
            if started.duration(to: .now) >= budget.wallTime {
                let control = await process.terminateAndReap(
                    interruptGrace: budget.interruptGrace,
                    terminateGrace: budget.terminateGrace
                )
                if case .reaped = control { return .timedOut }
                return .launchRejected(.processControlFailed(control))
            }
        }
    }

    private func rejectedEvidence(
        authorization: RelayStageExecutionAuthorization,
        commandDigest: String,
        rejection: RelayCommandLaunchRejection,
        output: RelayBoundedCommandStream,
        error: RelayBoundedCommandStream,
        started: ContinuousClock.Instant
    ) -> RelayCommandEvidence {
        RelayCommandEvidence(
            commandDigest: commandDigest,
            workspaceDigest: authorization.policy.workspaceDigest,
            sandboxCapabilityDigest: authorization.sandbox.capabilityDigest,
            executableIdentity: authorization.executable,
            processIdentity: nil,
            termination: .launchRejected(rejection),
            standardOutput: output.finalize(redactor: redactor),
            standardError: error.finalize(redactor: redactor),
            elapsed: started.duration(to: .now)
        )
    }

    private static func commandTermination(
        _ termination: RelayManagedProcessTermination
    ) -> RelayCommandTermination {
        switch termination {
        case .exited(let code): return .exited(code: code)
        case .signaled(let signal): return .signaled(signal: signal)
        }
    }

    private static func isSafeWorkingDirectory(
        _ directory: URL,
        workspace: RelayWorkspaceIdentity
    ) -> Bool {
        let root = URL(fileURLWithPath: workspace.repositoryRootPath)
            .standardizedFileURL
        let candidate = directory.standardizedFileURL
        guard candidate.path == root.path
                || candidate.path.hasPrefix(root.path + "/")
        else {
            return false
        }

        var rootStatus = stat()
        guard lstat(root.path, &rootStatus) == 0,
              (rootStatus.st_mode & S_IFMT) == S_IFDIR,
              UInt64(rootStatus.st_dev)
                == workspace.repositoryFileIdentity.deviceID,
              UInt64(rootStatus.st_ino)
                == workspace.repositoryFileIdentity.fileID
        else {
            return false
        }

        let values = try? candidate.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func commandDigest(
        executable: RelayExecutableIdentity,
        arguments: [String],
        workingDirectory: URL,
        environment: RelayMinimalEnvironment
    ) -> String {
        var hasher = SHA256()
        for value in [
            executable.canonicalURL.path,
            String(executable.device),
            String(executable.inode),
            executable.sha256,
            workingDirectory.standardizedFileURL.path,
        ] + arguments + environment.values.sorted(by: { $0.key < $1.key })
            .flatMap({ [$0.key, $0.value] })
        {
            let bytes = Data(value.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { hasher.update(data: Data($0)) }
            hasher.update(data: bytes)
        }
        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
