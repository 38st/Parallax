import AppKit
import Foundation

struct ConnectedAIAccountStatus: Sendable, Equatable {
    let email: String?
    let planName: String?
    let usagePercent: Int?
    let resetsAt: Date?
    let lifetimeTokens: Int?
}

enum AIAccountConnectionError: LocalizedError {
    case executableMissing(String)
    case notAuthenticated
    case loginFailed(String)
    case statusUnavailable(String)

    var errorDescription: String? {
        switch self {
        case let .executableMissing(name):
            "\(name) is not installed on this Mac."
        case .notAuthenticated:
            "This account is not signed in yet."
        case let .loginFailed(message):
            message.isEmpty ? "Sign-in did not complete." : message
        case let .statusUnavailable(message):
            message.isEmpty ? "Account status is unavailable." : message
        }
    }
}

enum AIAccountConnectionService {
    static func login(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await Task.detached(priority: .userInitiated) {
            switch provider {
            case .codex:
                try runCodexLogin(accountID: accountID)
                return try readCodexStatus(accountID: accountID)
            case .claude:
                try runClaudeLogin()
                return try readClaudeStatus()
            }
        }.value
    }

    static func refresh(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await Task.detached(priority: .utility) {
            switch provider {
            case .codex:
                try readCodexStatus(accountID: accountID)
            case .claude:
                try readClaudeStatus()
            }
        }.value
    }

    private static func runCodexLogin(accountID: UUID) throws {
        let executable = try executableURL(named: "codex")
        let home = try codexHome(accountID: accountID)
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let collector = JSONLineResponseCollector()

        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = mergedEnvironment(["CODEX_HOME": home.path])
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }

        try process.run()
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
        }

        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "parallax",
                        "title": "Parallax",
                        "version": "0.1.0"
                    ]
                ]
            ],
            ["method": "initialized", "params": [:]],
            [
                "method": "account/login/start",
                "id": 4,
                "params": [
                    "type": "chatgpt",
                    "useHostedLoginSuccessPage": true,
                    "appBrand": "codex"
                ]
            ]
        ]
        for message in messages {
            let data = try JSONSerialization.data(withJSONObject: message)
            input.fileHandleForWriting.write(data)
            input.fileHandleForWriting.write(Data([0x0A]))
        }

        let startDeadline = Date().addingTimeInterval(15)
        while Date() < startDeadline && collector.response(id: 4) == nil {
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard let startResponse = collector.response(id: 4) else {
            throw AIAccountConnectionError.loginFailed(
                "Codex did not start the browser login. Try again."
            )
        }
        if let error = startResponse["error"] as? [String: Any] {
            throw AIAccountConnectionError.loginFailed(
                error["message"] as? String ?? "Codex rejected the login request."
            )
        }
        guard
            let result = startResponse["result"] as? [String: Any],
            let loginID = result["loginId"] as? String,
            let authURL = result["authUrl"] as? String,
            URL(string: authURL) != nil
        else {
            throw AIAccountConnectionError.loginFailed(
                "Codex returned an invalid browser login."
            )
        }

        let openResult = try runProcess(
            executable: URL(fileURLWithPath: "/usr/bin/open"),
            arguments: [authURL],
            environment: [:],
            timeout: 10
        )
        guard openResult.status == 0 else {
            throw AIAccountConnectionError.loginFailed(
                "Parallax could not open the Codex sign-in page."
            )
        }

        let completionDeadline = Date().addingTimeInterval(300)
        while Date() < completionDeadline {
            if let notification = collector.loginCompletion(loginID: loginID) {
                if notification["success"] as? Bool == true { return }
                throw AIAccountConnectionError.loginFailed(
                    notification["error"] as? String
                        ?? "Codex sign-in was cancelled."
                )
            }
            if !process.isRunning {
                throw AIAccountConnectionError.loginFailed(
                    "Codex closed before sign-in completed."
                )
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw AIAccountConnectionError.loginFailed(
            "Sign-in timed out. Start it again and finish in the browser."
        )
    }

    private static func runClaudeLogin() throws {
        let executable = try executableURL(named: "claude")
        let result = try runProcess(
            executable: executable,
            arguments: ["auth", "login", "--claudeai"],
            environment: [:],
            timeout: nil
        )
        guard result.status == 0 else {
            throw AIAccountConnectionError.loginFailed(result.output)
        }
    }

    private static func readClaudeStatus() throws -> ConnectedAIAccountStatus {
        let executable = try executableURL(named: "claude")
        let result = try runProcess(
            executable: executable,
            arguments: ["auth", "status", "--json"],
            environment: [:],
            timeout: 15
        )
        guard result.status == 0 else {
            throw AIAccountConnectionError.notAuthenticated
        }
        guard
            let data = result.output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            throw AIAccountConnectionError.statusUnavailable(
                "Claude returned an unreadable account status."
            )
        }

        let loggedIn = json["loggedIn"] as? Bool
            ?? json["isAuthenticated"] as? Bool
            ?? true
        guard loggedIn else {
            throw AIAccountConnectionError.notAuthenticated
        }
        let email = json["email"] as? String
            ?? (json["account"] as? [String: Any])?["email"] as? String
        let plan = json["subscriptionType"] as? String
            ?? json["plan"] as? String
            ?? json["authMethod"] as? String

        return ConnectedAIAccountStatus(
            email: email,
            planName: plan,
            usagePercent: nil,
            resetsAt: nil,
            lifetimeTokens: nil
        )
    }

    private static func readCodexStatus(
        accountID: UUID
    ) throws -> ConnectedAIAccountStatus {
        let executable = try executableURL(named: "codex")
        let home = try codexHome(accountID: accountID)
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        let collector = JSONLineResponseCollector()

        process.executableURL = executable
        process.arguments = ["app-server"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        process.environment = mergedEnvironment([
            "CODEX_HOME": home.path
        ])
        output.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }

        do {
            try process.run()
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            throw AIAccountConnectionError.statusUnavailable(
                error.localizedDescription
            )
        }

        let messages: [[String: Any]] = [
            [
                "method": "initialize",
                "id": 0,
                "params": [
                    "clientInfo": [
                        "name": "parallax",
                        "title": "Parallax",
                        "version": "0.1.0"
                    ]
                ]
            ],
            ["method": "initialized", "params": [:]],
            [
                "method": "account/read",
                "id": 1,
                "params": ["refreshToken": false]
            ],
            ["method": "account/rateLimits/read", "id": 2],
            ["method": "account/usage/read", "id": 3]
        ]

        do {
            for message in messages {
                let data = try JSONSerialization.data(withJSONObject: message)
                input.fileHandleForWriting.write(data)
                input.fileHandleForWriting.write(Data([0x0A]))
            }
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            process.terminate()
            throw AIAccountConnectionError.statusUnavailable(
                error.localizedDescription
            )
        }

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if collector.response(id: 1) != nil,
               collector.response(id: 2) != nil,
               collector.response(id: 3) != nil
            {
                break
            }
            Thread.sleep(forTimeInterval: 0.05)
        }

        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }

        guard
            let accountResponse = collector.response(id: 1),
            let result = accountResponse["result"] as? [String: Any],
            let account = result["account"] as? [String: Any]
        else {
            throw AIAccountConnectionError.notAuthenticated
        }

        let accountType = account["type"] as? String
        guard accountType == "chatgpt" || accountType == "chatgptAuthTokens" else {
            throw AIAccountConnectionError.statusUnavailable(
                "This Codex account is not using a ChatGPT subscription login."
            )
        }

        var usedPercent: Int?
        var resetsAt: Date?
        if
            let rateResponse = collector.response(id: 2),
            let rateResult = rateResponse["result"] as? [String: Any]
        {
            let multi = rateResult["rateLimitsByLimitId"] as? [String: Any]
            let codexBucket = multi?["codex"] as? [String: Any]
            let fallback = rateResult["rateLimits"] as? [String: Any]
            let bucket = codexBucket ?? fallback
            let primary = bucket?["primary"] as? [String: Any]
            usedPercent = number(primary?["usedPercent"]).map { Int($0.rounded()) }
            if let seconds = number(primary?["resetsAt"]) {
                resetsAt = Date(timeIntervalSince1970: seconds)
            }
        }

        var lifetimeTokens: Int?
        if
            let usageResponse = collector.response(id: 3),
            let usageResult = usageResponse["result"] as? [String: Any],
            let summary = usageResult["summary"] as? [String: Any],
            let tokens = number(summary["lifetimeTokens"])
        {
            lifetimeTokens = Int(tokens)
        }

        return ConnectedAIAccountStatus(
            email: account["email"] as? String,
            planName: account["planType"] as? String,
            usagePercent: usedPercent,
            resetsAt: resetsAt,
            lifetimeTokens: lifetimeTokens
        )
    }

    private static func codexHome(accountID: UUID) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("AccountSessions", isDirectory: true)
            .appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("CodexHome", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private static func executableURL(named name: String) throws -> URL {
        let fileManager = FileManager.default
        let environmentPaths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        let fixedPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/bin").path
        ]
        for directory in environmentPaths + fixedPaths {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        if name == "claude" {
            let versions = fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".nvm/versions/node", isDirectory: true)
            let candidates = (try? fileManager.contentsOfDirectory(
                at: versions,
                includingPropertiesForKeys: nil
            ))?
                .sorted { $0.lastPathComponent > $1.lastPathComponent }
                .map { $0.appendingPathComponent("bin/claude") } ?? []
            if let candidate = candidates.first(where: {
                fileManager.isExecutableFile(atPath: $0.path)
            }) {
                return candidate
            }
        }

        throw AIAccountConnectionError.executableMissing(name.capitalized)
    }

    private static func runProcess(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = mergedEnvironment(environment)
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()

        if let timeout {
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                process.terminate()
                throw AIAccountConnectionError.statusUnavailable(
                    "The provider did not respond in time."
                )
            }
        } else {
            process.waitUntilExit()
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data.suffix(8_192), encoding: .utf8) ?? ""
        return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func mergedEnvironment(
        _ additions: [String: String]
    ) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        additions.forEach { environment[$0.key] = $0.value }
        return environment
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

private final class JSONLineResponseCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var loginCompletions: [String: [String: Any]] = [:]

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.prefix(upTo: newline)
            buffer.removeSubrange(...newline)
            guard
                !line.isEmpty,
                let object = try? JSONSerialization.jsonObject(with: line),
                let message = object as? [String: Any]
            else { continue }
            if let id = message["id"] as? NSNumber {
                responses[id.intValue] = message
            } else if
                message["method"] as? String == "account/login/completed",
                let params = message["params"] as? [String: Any],
                let loginID = params["loginId"] as? String
            {
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
}
