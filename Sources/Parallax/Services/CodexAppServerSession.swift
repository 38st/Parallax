import Foundation

enum CodexAppServerSessionFailure: Error, Equatable {
    case unsafeExecutable
    case launchFailed
    case notRunning
    case invalidMessage
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
        input.fileHandleForWriting.write(data)
        input.fileHandleForWriting.write(Data([0x0A]))
    }

    func response(id: Int) -> [String: Any]? {
        collector.response(id: id)
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

    func waitForResponses(
        ids: Set<Int>,
        timeout: TimeInterval,
        pollInterval: Duration = .milliseconds(50)
    ) async throws {
        let deadline = ProviderDeadline(after: timeout)
        while !deadline.hasExpired {
            try Task.checkCancellation()
            if ids.allSatisfy({ response(id: $0) != nil }) { return }
            guard isRunning else { return }
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
    private static let maximumBufferedBytes = 256 * 1_024
    private static let maximumLineBytes = 64 * 1_024
    private static let maximumStoredMessages = 16
    private let lock = NSLock()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var loginCompletions: [String: [String: Any]] = [:]

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        guard buffer.count <= Self.maximumBufferedBytes else {
            buffer.removeAll(keepingCapacity: true)
            return
        }
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard
                !line.isEmpty,
                line.count <= Self.maximumLineBytes,
                let object = try? JSONSerialization.jsonObject(with: line),
                let message = object as? [String: Any]
            else { continue }
            if let id = exactIntegerID(message["id"]) {
                guard responses[id] != nil
                    || responses.count < Self.maximumStoredMessages
                else { continue }
                responses[id] = message
            } else if
                message["method"] as? String == "account/login/completed",
                let params = message["params"] as? [String: Any],
                let loginID = params["loginId"] as? String
            {
                guard loginCompletions[loginID] != nil
                    || loginCompletions.count < Self.maximumStoredMessages
                else { continue }
                loginCompletions[loginID] = params
            }
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
