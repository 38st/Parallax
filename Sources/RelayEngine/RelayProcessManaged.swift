import Darwin
import Foundation

public enum RelayManagedProcessError: Error, Sendable, Equatable {
    case executableChanged
    case invalidWorkingDirectory
    case launchFailed(String)
    case processIdentityUnavailable
    case invalidStreamBufferLimit
    case standardInputClosed
    case standardInputWriteFailed(String)
}

public enum RelayManagedProcessTermination: Sendable, Equatable {
    case exited(code: Int32)
    case signaled(signal: Int32)
}

public enum RelayManagedProcessControlOutcome: Sendable, Equatable {
    case reaped(RelayManagedProcessTermination)
    case identityChanged
    case identityUnavailable
    case signalRejected(code: Int32)
    case didNotExit
}

public enum RelayManagedProcessStream: Sendable, Equatable {
    case standardOutput
    case standardError
}

public enum RelayManagedProcessStreamFailure: Sendable, Equatable {
    case bufferLimitExceeded(RelayManagedProcessStream)
}

/// A narrow, truthful wrapper around a host `Process`.
///
/// This type establishes exact PID/start ownership and provides bounded
/// termination/reaping, but its `sandboxCapabilities` intentionally reports
/// that Foundation Process does not contain filesystem, network, or detached
/// descendants. Repository-controlled commands must not use this API unless a
/// higher-level sandbox backend has independently established those boundaries.
public final class RelayManagedProcess: @unchecked Sendable {
    public let processIdentity: RelayProcessStartIdentity
    public let sandboxCapabilities = RelaySandboxCapabilityReport.unsafeHostProcess
    public let standardOutput: AsyncStream<Data>
    public let standardError: AsyncStream<Data>

    private let process: Process
    private let standardInputHandle: FileHandle
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let errorContinuation: AsyncStream<Data>.Continuation
    private let outputPipe: Pipe
    private let errorPipe: Pipe
    private let inspector: any RelayProcessIdentityInspecting
    private let onStandardOutput: @Sendable (Data) -> Void
    private let onStandardError: @Sendable (Data) -> Void
    private let publishesOutputStreams: Bool
    private let condition = NSCondition()
    private let readerGroup = DispatchGroup()
    private let inputLock = NSLock()
    private var inputClosed = false
    private var reapedTermination: RelayManagedProcessTermination?
    private var termination: RelayManagedProcessTermination?
    private var internalStreamFailure: RelayManagedProcessStreamFailure?
    private var overflowTerminationStarted = false
    private var terminationControlTask:
        Task<RelayManagedProcessControlOutcome, Never>?

    private init(
        process: Process,
        standardInputHandle: FileHandle,
        outputPipe: Pipe,
        errorPipe: Pipe,
        processIdentity: RelayProcessStartIdentity,
        inspector: any RelayProcessIdentityInspecting,
        onStandardOutput: @escaping @Sendable (Data) -> Void,
        onStandardError: @escaping @Sendable (Data) -> Void,
        publishesOutputStreams: Bool,
        maximumBufferedStreamChunks: Int
    ) {
        self.process = process
        self.standardInputHandle = standardInputHandle
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        self.processIdentity = processIdentity
        self.inspector = inspector
        self.onStandardOutput = onStandardOutput
        self.onStandardError = onStandardError
        self.publishesOutputStreams = publishesOutputStreams

        let outputPair = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(maximumBufferedStreamChunks)
        )
        standardOutput = outputPair.stream
        outputContinuation = outputPair.continuation

        let errorPair = AsyncStream<Data>.makeStream(
            bufferingPolicy: .bufferingOldest(maximumBufferedStreamChunks)
        )
        standardError = errorPair.stream
        errorContinuation = errorPair.continuation
    }

    public static func launch(
        executable: RelayExecutableIdentity,
        arguments: [String],
        workingDirectory: URL,
        environment: RelayMinimalEnvironment,
        inspector: any RelayProcessIdentityInspecting =
            SystemRelayProcessIdentityInspector(),
        onStandardOutput: @escaping @Sendable (Data) -> Void = { _ in },
        onStandardError: @escaping @Sendable (Data) -> Void = { _ in },
        publishesOutputStreams: Bool = true,
        maximumBufferedStreamChunks: Int = 64
    ) throws -> RelayManagedProcess {
        guard maximumBufferedStreamChunks > 0 else {
            throw RelayManagedProcessError.invalidStreamBufferLimit
        }
        guard executable.matchesCurrentFile() else {
            throw RelayManagedProcessError.executableChanged
        }
        let workingDirectory = workingDirectory.standardizedFileURL
        let values = try? workingDirectory.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard workingDirectory.isFileURL,
              values?.isDirectory == true,
              values?.isSymbolicLink != true
        else {
            throw RelayManagedProcessError.invalidWorkingDirectory
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable.canonicalURL
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = environment.values
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            try? inputPipe.fileHandleForReading.close()
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForWriting.close()
            throw RelayManagedProcessError.launchFailed(
                String(describing: error)
            )
        }

        // The child owns duplicated copies of these endpoints after launch.
        // Keeping the parent's unused copies open prevents readers from
        // observing EOF after the exact child exits and can defeat bounded
        // termination/reaping under scheduler or instrumentation pressure.
        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
        try? errorPipe.fileHandleForWriting.close()

        let identity: RelayProcessStartIdentity
        switch inspector.inspect(processIdentifier: process.processIdentifier) {
        case .live(let inspected)
            where inspected.processIdentifier == process.processIdentifier:
            identity = inspected
        case .live, .dead, .ambiguous:
            process.terminate()
            process.waitUntilExit()
            throw RelayManagedProcessError.processIdentityUnavailable
        }

        let managed = RelayManagedProcess(
            process: process,
            standardInputHandle: inputPipe.fileHandleForWriting,
            outputPipe: outputPipe,
            errorPipe: errorPipe,
            processIdentity: identity,
            inspector: inspector,
            onStandardOutput: onStandardOutput,
            onStandardError: onStandardError,
            publishesOutputStreams: publishesOutputStreams,
            maximumBufferedStreamChunks: maximumBufferedStreamChunks
        )
        managed.beginReadingAndReaping()
        return managed
    }

    public func writeStandardInput(_ data: Data) throws {
        try inputLock.withLock {
            guard !inputClosed else {
                throw RelayManagedProcessError.standardInputClosed
            }
            do {
                try standardInputHandle.write(contentsOf: data)
            } catch {
                throw RelayManagedProcessError.standardInputWriteFailed(
                    String(describing: error)
                )
            }
        }
    }

    public func closeStandardInput() {
        inputLock.withLock {
            guard !inputClosed else { return }
            inputClosed = true
            try? standardInputHandle.close()
        }
    }

    public var streamFailure: RelayManagedProcessStreamFailure? {
        condition.lock()
        defer { condition.unlock() }
        return internalStreamFailure
    }

    public func waitUntilExit() async -> RelayManagedProcessTermination {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                condition.lock()
                while termination == nil { condition.wait() }
                let result = termination!
                condition.unlock()
                continuation.resume(returning: result)
            }
        }
    }

    public func waitUntilExit(
        upTo duration: Duration
    ) async -> RelayManagedProcessTermination? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                continuation.resume(
                    returning: waitForTermination(upTo: duration)
                )
            }
        }
    }

    /// Requests interrupt, then terminate, then kill, revalidating exact
    /// PID/start identity before every signal. A successful return means the
    /// process has been waited and both output streams have reached EOF.
    public func terminateAndReap(
        interruptGrace: Duration = .seconds(1),
        terminateGrace: Duration = .seconds(1),
        killGrace: Duration = .seconds(5)
    ) async -> RelayManagedProcessControlOutcome {
        let reservation = reserveTerminationControl(
            interruptGrace: interruptGrace,
            terminateGrace: terminateGrace,
            killGrace: killGrace
        )
        if let completed = reservation.completed {
            return .reaped(completed)
        }
        guard let task = reservation.task else {
            return .didNotExit
        }
        let outcome = await task.value
        if reservation.createdTask {
            clearTerminationControlTask()
        }
        return outcome
    }

    private func reserveTerminationControl(
        interruptGrace: Duration,
        terminateGrace: Duration,
        killGrace: Duration
    ) -> (
        task: Task<RelayManagedProcessControlOutcome, Never>?,
        completed: RelayManagedProcessTermination?,
        createdTask: Bool
    ) {
        condition.lock()
        defer { condition.unlock() }
        if let completed = reapedTermination {
            return (nil, completed, false)
        }
        if let existing = terminationControlTask {
            return (existing, nil, false)
        }
        let task = Task.detached(priority: .utility) { [self] in
            performTerminationAndReap(
                interruptGrace: interruptGrace,
                terminateGrace: terminateGrace,
                killGrace: killGrace
            )
        }
        terminationControlTask = task
        return (task, nil, true)
    }

    private func clearTerminationControlTask() {
        condition.lock()
        terminationControlTask = nil
        condition.broadcast()
        condition.unlock()
    }

    private func performTerminationAndReap(
        interruptGrace: Duration,
        terminateGrace: Duration,
        killGrace: Duration
    ) -> RelayManagedProcessControlOutcome {
        for step in [
            (SIGINT, interruptGrace),
            (SIGTERM, terminateGrace),
            (SIGKILL, killGrace),
        ] {
            switch sendExactSignal(step.0) {
            case .delivered, .alreadyExited:
                if let completed = waitForReaping(upTo: step.1) {
                    return .reaped(completed)
                }
            case .identityChanged:
                return .identityChanged
            case .identityUnavailable:
                return .identityUnavailable
            case .rejected(let code):
                return .signalRejected(code: code)
            }
        }
        return .didNotExit
    }

    private func beginReadingAndReaping() {
        beginReader(
            handle: outputPipe.fileHandleForReading,
            continuation: outputContinuation,
            observer: onStandardOutput,
            stream: .standardOutput
        )
        beginReader(
            handle: errorPipe.fileHandleForReading,
            continuation: errorContinuation,
            observer: onStandardError,
            stream: .standardError
        )

        let reaper = Thread { [self] in reapAndDrain() }
        reaper.name = "Relay process reaper \(processIdentity.processIdentifier)"
        reaper.qualityOfService = .userInitiated
        reaper.start()
    }

    private func reapAndDrain() {
        process.waitUntilExit()
        let result: RelayManagedProcessTermination
        switch process.terminationReason {
        case .exit:
            result = .exited(code: process.terminationStatus)
        case .uncaughtSignal:
            result = .signaled(signal: process.terminationStatus)
        @unknown default:
            result = .signaled(signal: process.terminationStatus)
        }

        condition.lock()
        reapedTermination = result
        condition.broadcast()
        condition.unlock()

        closeStandardInput()
        readerGroup.wait()

        condition.lock()
        termination = result
        condition.broadcast()
        condition.unlock()
    }

    private func beginReader(
        handle: FileHandle,
        continuation: AsyncStream<Data>.Continuation,
        observer: @escaping @Sendable (Data) -> Void,
        stream: RelayManagedProcessStream
    ) {
        readerGroup.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer {
                try? handle.close()
                continuation.finish()
                readerGroup.leave()
            }
            while true {
                let data = handle.availableData
                guard !data.isEmpty else { return }
                observer(data)
                guard publishesOutputStreams else { continue }
                switch continuation.yield(data) {
                case .enqueued:
                    continue
                case .dropped:
                    recordStreamOverflow(stream)
                    return
                case .terminated:
                    return
                @unknown default:
                    recordStreamOverflow(stream)
                    return
                }
            }
        }
    }

    private func recordStreamOverflow(_ stream: RelayManagedProcessStream) {
        condition.lock()
        let shouldStartTermination = !overflowTerminationStarted
        if internalStreamFailure == nil {
            internalStreamFailure = .bufferLimitExceeded(stream)
        }
        overflowTerminationStarted = true
        condition.unlock()

        guard shouldStartTermination else { return }
        closeStandardInput()
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            _ = await terminateAndReap(
                interruptGrace: .seconds(1),
                terminateGrace: .seconds(1),
                killGrace: .seconds(5)
            )
        }
    }

    private func currentTermination() -> RelayManagedProcessTermination? {
        condition.lock()
        defer { condition.unlock() }
        return termination
    }

    private func waitForTermination(
        upTo duration: Duration
    ) -> RelayManagedProcessTermination? {
        let deadline = Date().addingTimeInterval(duration.timeInterval)
        condition.lock()
        defer { condition.unlock() }
        while termination == nil {
            guard condition.wait(until: deadline) else { break }
        }
        return termination
    }

    private func waitForReaping(
        upTo duration: Duration
    ) -> RelayManagedProcessTermination? {
        let deadline = Date().addingTimeInterval(duration.timeInterval)
        condition.lock()
        defer { condition.unlock() }
        while reapedTermination == nil {
            guard condition.wait(until: deadline) else { break }
        }
        return reapedTermination
    }

    private func sendExactSignal(
        _ signal: Int32
    ) -> RelayExactProcessSignalResult {
        switch inspector.inspect(
            processIdentifier: processIdentity.processIdentifier
        ) {
        case .dead:
            return .alreadyExited
        case .ambiguous:
            return .identityUnavailable
        case .live(let current):
            guard current == processIdentity else { return .identityChanged }
        }
        guard Darwin.kill(processIdentity.processIdentifier, signal) == 0 else {
            let code = errno
            if code == ESRCH { return .alreadyExited }
            return .rejected(code: code)
        }
        return .delivered
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds)
            + TimeInterval(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
