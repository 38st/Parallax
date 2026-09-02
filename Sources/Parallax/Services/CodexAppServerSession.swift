import Darwin
import Foundation

enum CodexAppServerSessionFailure: Error, Equatable {
    case unsafeExecutable
    case launchFailed
    case notRunning
    case invalidMessage
}

enum CodexAppServerWaitOutcome: Equatable, Sendable {
    case completed
    case timedOut
    case processExited
}

/// Owns one scoped Codex app-server process and its JSON-lines transport.
/// Callers retain operation-specific error mapping and decide when to close the
/// session; every successfully started session must be closed and reaped.
final class CodexAppServerSession: @unchecked Sendable {
    private let executable: TrustedProviderExecutable
    private let codexHome: URL
    private let process: Process
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let collector = JSONLineResponseCollector()
    private let errorCollector = ProviderProcessOutputCollector()
    private let terminationWaiter = ProviderProcessTerminationWaiter()
    private let stateLock = NSLock()
    private let startedHandler: (@Sendable (pid_t) -> Void)?
    private var started = false
    private var closed = false

    init(
        executable: TrustedProviderExecutable,
        codexHome: URL,
        startedHandler: (@Sendable (pid_t) -> Void)? = nil
    ) {
        self.executable = executable
        self.codexHome = codexHome
        self.startedHandler = startedHandler
        process = Process()
    }

    var isRunning: Bool {
        process.isRunning
    }

    func start() throws {
        let canStart = stateLock.withLock {
            guard !started, !closed else { return false }
            started = true
            return true
        }
        guard canStart else {
            throw CodexAppServerSessionFailure.notRunning
        }

        do {
            process.executableURL = try executable.revalidatedURL()
        } catch {
            throw CodexAppServerSessionFailure.unsafeExecutable
        }
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = ProviderSubprocessEnvironment.make(
            additions: ["CODEX_HOME": codexHome.path]
        )
        terminationWaiter.install(on: process)
        // An app-server that exits between a liveness check and a write must
        // surface as EPIPE on that write, never as SIGPIPE ending Parallax.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [collector] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            collector.append(data)
        }
        errors.fileHandleForReading.readabilityHandler = {
            [errorCollector] handle in
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
            removeReadabilityHandlers()
            try? input.fileHandleForWriting.close()
            throw CodexAppServerSessionFailure.launchFailed
        }
    }

    func sendInitialization() throws {
        try send([
            "method": "initialize",
            "id": 0,
            "params": [
                "clientInfo": [
                    "name": "parallax",
                    "title": "Parallax",
                    "version": "0.1.0",
                ]
            ],
        ])
        try send(["method": "initialized", "params": [:]])
    }

    func send(_ message: [String: Any]) throws {
        guard isRunning else {
            throw CodexAppServerSessionFailure.notRunning
        }
        guard JSONSerialization.isValidJSONObject(message) else {
            throw CodexAppServerSessionFailure.invalidMessage
        }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: message)
        } catch {
            throw CodexAppServerSessionFailure.invalidMessage
        }
        do {
            try input.fileHandleForWriting.write(contentsOf: data)
            try input.fileHandleForWriting.write(contentsOf: Data([0x0A]))
        } catch {
            throw CodexAppServerSessionFailure.notRunning
        }
    }

    func response(id: Int) -> [String: Any]? {
        collector.response(id: id)
    }

    /// Diagnostics the app-server wrote to stderr. Retained for local logging
    /// only; provider text is never rendered in the UI.
    var standardErrorOutput: String {
        errorCollector.string()
    }

    func loginCompletion(loginID: String) -> [String: Any]? {
        collector.loginCompletion(loginID: loginID)
    }

    @discardableResult
    func waitForResponse(
        id: Int,
        timeout: TimeInterval,
        pollInterval: Duration = .milliseconds(50)
    ) async throws -> Bool {
        let deadline = ProviderDeadline(after: timeout)
        while !deadline.hasExpired, response(id: id) == nil {
            try Task.checkCancellation()
            guard isRunning else { return false }
            try await Task.sleep(for: pollInterval)
        }
        return response(id: id) != nil
    }

    /// Waits until every requested response has arrived, the app-server exits,
    /// or the deadline passes. The outcome lets callers distinguish a genuine
    /// provider answer from transport trouble; only the former may carry
    /// authentication meaning.
    @discardableResult
    func waitForResponses(
        ids: Set<Int>,
        timeout: TimeInterval,
        pollInterval: Duration = .milliseconds(50)
    ) async throws -> CodexAppServerWaitOutcome {
        let deadline = ProviderDeadline(after: timeout)
        while true {
            try Task.checkCancellation()
            if ids.allSatisfy({ response(id: $0) != nil }) { return .completed }
            guard isRunning else {
                // Output written immediately before exit may still be
                // arriving through the readability handler.
                try await Task.sleep(for: pollInterval)
                return ids.allSatisfy({ response(id: $0) != nil })
                    ? .completed
                    : .processExited
            }
            guard !deadline.hasExpired else { return .timedOut }
            try await Task.sleep(for: pollInterval)
        }
    }

    @discardableResult
    func waitForLoginCompletion(
        loginID: String,
        timeout: TimeInterval,
        pollInterval: Duration = .milliseconds(100)
    ) async throws -> Bool {
        let deadline = ProviderDeadline(after: timeout)
        while !deadline.hasExpired,
              loginCompletion(loginID: loginID) == nil
        {
            try Task.checkCancellation()
            guard isRunning else { return false }
            try await Task.sleep(for: pollInterval)
        }
        return loginCompletion(loginID: loginID) != nil
    }

    func close() {
        let shouldClose = stateLock.withLock {
            guard !closed else { return false }
            closed = true
            return started
        }
        guard shouldClose else { return }
        try? input.fileHandleForWriting.close()
        if process.isRunning || process.processIdentifier > 0 {
            ProviderProcessLifecycle.terminateAndReap(
                process,
                terminationWaiter: terminationWaiter
            )
        }
        removeReadabilityHandlers()
    }

    private func removeReadabilityHandlers() {
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
    }
}

final class JSONLineResponseCollector: @unchecked Sendable {
    /// `account/usage/read` returns the complete daily history, which grows
    /// without bound. The caps only guard against a runaway producer.
    private static let maximumBufferedBytes = 4 * 1_024 * 1_024
    private static let maximumLineBytes = 2 * 1_024 * 1_024
    private static let maximumStoredMessages = 16
    private let lock = NSLock()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var loginCompletions: [String: [String: Any]] = [:]

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        // Only the new bytes can contain a newline the previous pass missed,
        // so the scan starts where the buffer ended; each byte is scanned
        // once and the buffer is shifted once per append, not per line.
        let scanStart = buffer.count
        buffer.append(data)
        var lineStart = buffer.startIndex
        var searchStart = buffer.startIndex + scanStart
        while let newline = buffer[searchStart...].firstIndex(of: 0x0A) {
            store(line: buffer[lineStart..<newline])
            lineStart = newline + 1
            searchStart = lineStart
        }
        if lineStart > buffer.startIndex {
            buffer.removeSubrange(buffer.startIndex..<lineStart)
        }
        // Every complete line was consumed above, so only an unterminated
        // fragment can remain. Dropping it never discards a finished message.
        if buffer.count > Self.maximumBufferedBytes {
            buffer.removeAll(keepingCapacity: true)
        }
    }

    private func store(line: Data) {
        guard
            !line.isEmpty,
            line.count <= Self.maximumLineBytes,
            let object = try? JSONSerialization.jsonObject(with: line),
            let message = object as? [String: Any]
        else { return }
        if message["method"] == nil, let id = exactIntegerID(message["id"]) {
            // Server-initiated requests also carry an `id` (with a `method`)
            // and use the server's own counter, so they must never shadow a
            // client response.
            guard responses[id] != nil
                || responses.count < Self.maximumStoredMessages
            else { return }
            responses[id] = message
        } else if
            message["method"] as? String == "account/login/completed",
            let params = message["params"] as? [String: Any],
            let loginID = params["loginId"] as? String
        {
            guard loginCompletions[loginID] != nil
                || loginCompletions.count < Self.maximumStoredMessages
            else { return }
            loginCompletions[loginID] = params
        }
    }

    func response(id: Int) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return responses[id]
    }

    func loginCompletion(loginID: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        return loginCompletions[loginID]
    }

    private func exactIntegerID(_ value: Any?) -> Int? {
        guard
            let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let double = number.doubleValue
        let maximumExactInteger = 9_007_199_254_740_991.0
        guard
            double.isFinite,
            double.rounded(.towardZero) == double,
            abs(double) <= maximumExactInteger
        else {
            return nil
        }
        return Int(double)
    }
}
