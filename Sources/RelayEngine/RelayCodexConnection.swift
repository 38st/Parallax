import Foundation

public enum RelayCodexConnectionError: Error, Equatable, Sendable {
    case unsafeCodexHome
    case processLaunch(String)
    case protocolFailure(String)
}

public enum RelayCodexConnectionFailure: Error, Equatable, Sendable {
    case protocolViolation
    case eventBufferOverflow
    case eventConsumerUnavailable
    case processStreamOverflow(RelayManagedProcessStream)
}

/// Owns one trusted Codex app-server process and one protocol session.
///
/// The host process wrapper is not itself a repository-code sandbox. Relay
/// launches only the previously admitted Codex executable through it; every
/// agent turn still carries the explicit app-server read-only/workspace-write
/// policy built by `RelayCodexMessages`.
public final class RelayCodexConnection: @unchecked Sendable {
    public let session: RelayCodexSession
    public let processIdentity: RelayProcessStartIdentity

    private let process: RelayManagedProcess
    private let diagnostics: RelayCodexDiagnosticBuffer
    private let failureState: RelayCodexConnectionFailureState
    private let pumpLock = NSLock()
    private var outputPump: Task<Void, Never>?
    private var errorPump: Task<Void, Never>?
    private var shutdownTask: Task<RelayManagedProcessControlOutcome, Never>?

    private init(
        process: RelayManagedProcess,
        session: RelayCodexSession,
        diagnostics: RelayCodexDiagnosticBuffer,
        failureState: RelayCodexConnectionFailureState
    ) {
        self.process = process
        self.session = session
        self.diagnostics = diagnostics
        self.failureState = failureState
        processIdentity = process.processIdentity
    }

    deinit {
        let tasks = pumpLock.withLock { () -> [Task<Void, Never>] in
            let values = [outputPump, errorPump].compactMap { $0 }
            outputPump = nil
            errorPump = nil
            return values
        }
        tasks.forEach { $0.cancel() }
        let ownedProcess = process
        Task.detached(priority: .utility) {
            _ = await ownedProcess.terminateAndReap()
        }
    }

    public static func launch(
        executable: RelayExecutableIdentity,
        codexHome: URL,
        context: RelayCodexControlContext,
        temporaryDirectory: URL? = nil
    ) throws -> RelayCodexConnection {
        let codexHome = codexHome.standardizedFileURL
        let values = try? codexHome.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard codexHome.isFileURL,
              values?.isDirectory == true,
              values?.isSymbolicLink != true
        else {
            throw RelayCodexConnectionError.unsafeCodexHome
        }
        var explicit = ["CODEX_HOME": codexHome.path]
        if let temporaryDirectory {
            explicit["TMPDIR"] = temporaryDirectory.standardizedFileURL.path
        }
        let environment = try RelayMinimalEnvironment(
            explicitValues: explicit,
            allowedNames: ["LANG", "LC_ALL", "TMPDIR", "CODEX_HOME"]
        )
        let diagnostics = RelayCodexDiagnosticBuffer(
            limit: 256 * 1_024,
            sensitiveLiterals: [codexHome.path]
        )
        let workingDirectory = URL(
            fileURLWithPath: try context.workspace.validatedPath(),
            isDirectory: true
        )
        let process: RelayManagedProcess
        do {
            process = try RelayManagedProcess.launch(
                executable: executable,
                arguments: ["app-server", "--listen", "stdio://"],
                workingDirectory: workingDirectory,
                environment: environment
            )
        } catch {
            throw RelayCodexConnectionError.processLaunch(
                String(describing: error)
            )
        }
        let session = RelayCodexSession(context: context) { [process] bytes in
            try process.writeStandardInput(bytes)
        }
        let failureState = RelayCodexConnectionFailureState()
        let connection = RelayCodexConnection(
            process: process,
            session: session,
            diagnostics: diagnostics,
            failureState: failureState
        )
        connection.startPumps()
        return connection
    }

    public func waitUntilExit() async -> RelayManagedProcessTermination {
        await process.waitUntilExit()
    }

    public func stop() async -> RelayManagedProcessControlOutcome {
        let task = pumpLock.withLock {
            if let shutdownTask { return shutdownTask }
            let output = outputPump
            let errors = errorPump
            outputPump = nil
            errorPump = nil
            let task = Task { [process, session] in
                if case .turnRunning = await session.state {
                    try? await session.interrupt()
                }
                let outcome = await process.terminateAndReap()
                output?.cancel()
                errors?.cancel()
                if let output { await output.value }
                if let errors { await errors.value }
                await session.cancelAndClose()
                return outcome
            }
            shutdownTask = task
            return task
        }
        return await task.value
    }

    public var terminalFailure: RelayCodexConnectionFailure? {
        if let stream = process.streamFailure {
            switch stream {
            case .bufferLimitExceeded(let stream):
                return .processStreamOverflow(stream)
            }
        }
        return failureState.failure
    }

    /// Bounded exact-process control result produced by an automatic shutdown
    /// after protocol failure. A non-reaped result remains visible rather than
    /// being mistaken for successful cancellation.
    public var failureControlOutcome: RelayManagedProcessControlOutcome? {
        failureState.controlOutcome
    }

    public func diagnosticSnapshot() -> RelayRedactedText {
        diagnostics.snapshot()
    }

    private func startPumps() {
        let output = process.standardOutput
        let errors = process.standardError
        let process = process
        let failureState = failureState
        let outputTask = Task { [session, process, failureState] in
            do {
                for await bytes in output {
                    try Task.checkCancellation()
                    try await session.receive(bytes)
                }
                if let streamFailure = process.streamFailure {
                    throw RelayCodexPumpError.stream(streamFailure)
                }
                try await session.close()
            } catch {
                guard !Task.isCancelled else { return }
                failureState.record(Self.connectionFailure(error))
                await session.failTransport()
                let outcome = await process.terminateAndReap()
                failureState.record(outcome)
            }
        }
        let errorTask = Task { [diagnostics] in
            for await bytes in errors {
                if Task.isCancelled { return }
                diagnostics.append(bytes)
            }
        }
        pumpLock.withLock {
            outputPump = outputTask
            errorPump = errorTask
        }
    }

    private static func connectionFailure(
        _ error: Error
    ) -> RelayCodexConnectionFailure {
        if let failure = error as? RelayCodexSessionError {
            switch failure {
            case .eventBufferOverflow:
                return .eventBufferOverflow
            case .eventConsumerUnavailable:
                return .eventConsumerUnavailable
            default:
                return .protocolViolation
            }
        }
        if case let RelayCodexPumpError.stream(failure) = error,
           case let .bufferLimitExceeded(stream) = failure
        {
            return .processStreamOverflow(stream)
        }
        return .protocolViolation
    }
}

private enum RelayCodexPumpError: Error {
    case stream(RelayManagedProcessStreamFailure)
}

private final class RelayCodexConnectionFailureState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFailure: RelayCodexConnectionFailure?
    private var storedControlOutcome: RelayManagedProcessControlOutcome?

    var failure: RelayCodexConnectionFailure? {
        lock.withLock { storedFailure }
    }

    var controlOutcome: RelayManagedProcessControlOutcome? {
        lock.withLock { storedControlOutcome }
    }

    func record(_ failure: RelayCodexConnectionFailure) {
        lock.withLock {
            guard storedFailure == nil else { return }
            storedFailure = failure
        }
    }


    func record(_ outcome: RelayManagedProcessControlOutcome) {
        lock.withLock {
            guard storedControlOutcome == nil else { return }
            storedControlOutcome = outcome
        }
    }
}

private final class RelayCodexDiagnosticBuffer: @unchecked Sendable {
    private let limit: Int
    private let redactor: RelayEvidenceRedactor
    private let lock = NSLock()
    private var data = Data()

    init(limit: Int, sensitiveLiterals: Set<String>) {
        self.limit = limit
        redactor = RelayEvidenceRedactor(
            sensitiveLiterals: sensitiveLiterals
        )
    }

    func append(_ bytes: Data) {
        lock.withLock {
            let remaining = max(0, limit - data.count)
            if remaining > 0 { data.append(bytes.prefix(remaining)) }
        }
    }

    func snapshot() -> RelayRedactedText {
        lock.withLock {
            redactor.redact(data)
        }
    }
}
