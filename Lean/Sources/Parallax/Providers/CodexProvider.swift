import Foundation

/// Reads Codex usage through `codex app-server`, which speaks newline-delimited JSON.
enum CodexProvider {
    static func signIn(codexHome: URL) async throws -> ProviderStatus {
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let session = try CodexSession(codexHome: codexHome)
        defer { session.close() }
        session.send(["method": "account/login/start", "id": 4,
                      "params": ["type": "chatgpt", "useHostedLoginSuccessPage": false]])
        let reply = try await session.response(id: 4, timeout: 15)
        guard let result = reply["result"] as? [String: Any],
              let loginID = result["loginId"] as? String,
              let authURL = result["authUrl"] as? String
        else { throw ProviderError.failed("Codex didn't start sign-in.") }
        let opened = await ProviderCLI.openSignInPage(authURL, allowedHosts: ["openai.com", "chatgpt.com"])
        guard opened else { throw ProviderError.failed("Codex returned an unexpected sign-in page.") }
        let completed: [String: Any]
        do {
            completed = try await session.loginCompletion(loginID: loginID, timeout: 300)
        } catch {
            session.send(["method": "account/login/cancel", "id": 5, "params": ["loginId": loginID]])
            throw error
        }
        guard (completed["success"] as? Bool) == true else { throw ProviderError.failed("Codex sign-in didn't finish.") }
        return try await readStatus(session)
    }

    static func status(codexHome: URL) async throws -> ProviderStatus {
        let session = try CodexSession(codexHome: codexHome)
        defer { session.close() }
        return try await readStatus(session)
    }

    private static func readStatus(_ session: CodexSession) async throws -> ProviderStatus {
        session.send(["method": "account/read", "id": 1, "params": ["refreshToken": false]])
        session.send(["method": "account/rateLimits/read", "id": 2])
        let accountReply = try await session.response(id: 1, timeout: 15)
        guard let result = accountReply["result"] as? [String: Any], result.keys.contains("account") else {
            throw ProviderError.failed("Codex's account couldn't be read.")
        }
        guard let account = result["account"] as? [String: Any] else { throw ProviderError.signedOut }
        var status = ProviderStatus(
            email: account["email"] as? String,
            plan: (account["planType"] as? String)?.capitalized,
            windows: []
        )
        if let limits = try? await session.response(id: 2, timeout: 10) {
            status.windows = windows(fromRateLimits: limits["result"] as? [String: Any] ?? [:])
        }
        if status.windows.isEmpty { status.usageError = "Codex didn't report usage limits." }
        return status
    }

    /// Maps `primary`/`secondary` rate-limit windows, shortest first.
    static func windows(fromRateLimits result: [String: Any]) -> [UsageWindow] {
        let byID = result["rateLimitsByLimitId"] as? [String: Any]
        guard let bucket = (byID?["codex"] as? [String: Any]) ?? (result["rateLimits"] as? [String: Any]) else { return [] }
        var entries: [(minutes: Int?, percent: Int, resetsAt: Date?)] = []
        for key in ["primary", "secondary"] {
            guard let window = bucket[key] as? [String: Any],
                  let used = (window["usedPercent"] as? NSNumber)?.doubleValue, used.isFinite, used >= 0
            else { continue }
            let minutes = (window["windowDurationMins"] as? NSNumber)?.intValue
            let reset = (window["resetsAt"] as? NSNumber)?.doubleValue
            let resetsAt = reset.flatMap { $0 > 0 && $0 < 32_503_680_000 ? Date(timeIntervalSince1970: $0) : nil }
            entries.append((minutes, Int(min(used, 100).rounded()), resetsAt))
        }
        if entries.count == 2, let first = entries[0].minutes, let second = entries[1].minutes, first > second {
            entries.swapAt(0, 1)
        }
        return entries.enumerated().map { index, entry in
            let isWeekly = entries.count == 2 ? index == 1 : (entry.minutes ?? 0) > 1_440
            return UsageWindow(title: isWeekly ? "Week" : "Session", percent: entry.percent, resetsAt: entry.resetsAt)
        }
    }
}

/// One `codex app-server` process. Messages are JSON objects, one per line, without a "jsonrpc" field.
final class CodexSession: @unchecked Sendable {
    private let box = ProcessBox()
    private let input = Pipe()
    private let output = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var logins: [String: [String: Any]] = [:]

    init(codexHome: URL) throws {
        guard let executable = ProviderCLI.locate("codex") else { throw ProviderError.toolMissing("codex") }
        let process = box.process
        process.executableURL = executable
        process.arguments = ["app-server"]
        process.environment = ProviderCLI.environment(adding: ["CODEX_HOME": codexHome.path])
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            if chunk.isEmpty { handle.readabilityHandler = nil } else { self?.receive(chunk) }
        }
        try process.run()
        send(["method": "initialize", "id": 0,
              "params": ["clientInfo": ["name": "parallax", "title": "Parallax", "version": "2.0.0"]]])
        send(["method": "initialized", "params": [String: Any]()])
    }

    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        try? input.fileHandleForWriting.write(contentsOf: data)
    }

    func response(id: Int, timeout: TimeInterval) async throws -> [String: Any] {
        try await poll(timeout: timeout, interval: 0.05) { self.responses[id] }
    }

    func loginCompletion(loginID: String, timeout: TimeInterval) async throws -> [String: Any] {
        try await poll(timeout: timeout, interval: 0.1) { self.logins[loginID] }
    }

    func close() {
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        box.stop()
    }

    private func poll(timeout: TimeInterval, interval: TimeInterval, _ read: @escaping () -> [String: Any]?) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            if let value = lock.withLock(read) {
                if let error = value["error"] as? [String: Any] {
                    throw ProviderError.failed((error["message"] as? String) ?? "Codex returned an error.")
                }
                return value
            }
            if !box.process.isRunning { throw ProviderError.failed("Codex stopped before answering. Try signing in again.") }
            try await Task.sleep(for: .seconds(interval))
        }
        throw ProviderError.timedOut
    }

    private func receive(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard line.count <= 4_000_000,
                  let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
            else { continue }
            if let method = message["method"] as? String {
                if method == "account/login/completed",
                   let params = message["params"] as? [String: Any],
                   let loginID = params["loginId"] as? String {
                    logins[loginID] = params
                }
            } else if let id = (message["id"] as? NSNumber)?.intValue {
                responses[id] = message
            }
        }
        if buffer.count > 8_000_000 { buffer.removeAll() }
    }
}
