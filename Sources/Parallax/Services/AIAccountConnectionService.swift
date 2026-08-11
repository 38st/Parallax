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
    case loginFailed
    case statusUnavailable

    var errorDescription: String? {
        switch self {
        case let .executableMissing(name):
            "A trusted \(name) executable was not found in an approved system location."
        case .notAuthenticated:
            "This account is not signed in yet."
        case .loginFailed:
            "Sign-in did not complete. Try again."
        case .statusUnavailable:
            "Account status is unavailable. Try again."
        }
    }
}

struct ProviderAuthURLPolicy {
    private static let allowedRegistrableDomains = [
        "openai.com",
        "chatgpt.com",
    ]

    static func validatedCodexURL(_ value: String) -> URL? {
        guard
            value.count <= 8_192,
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "https",
            components.user == nil,
            components.password == nil,
            let host = components.host?.lowercased(),
            allowedRegistrableDomains.contains(where: {
                host == $0 || host.hasSuffix(".\($0)")
            }),
            let url = components.url
        else {
            return nil
        }
        return url
    }
}

struct ProviderAuthURLOpener: Sendable {
    private let operation: @MainActor @Sendable (URL) -> Bool

    init(operation: @escaping @MainActor @Sendable (URL) -> Bool) {
        self.operation = operation
    }

    @MainActor
    func open(_ url: URL) -> Bool {
        operation(url)
    }

    static let workspace = ProviderAuthURLOpener { url in
        NSWorkspace.shared.open(url)
    }
}

enum ProviderNumericDecoder {
    static let maximumExactInteger = 9_007_199_254_740_991.0
    static let maximumUnixTimestamp = 32_503_680_000.0

    static func percentage(_ value: Any?) -> Int? {
        guard
            let number = finiteDouble(value),
            (0...100).contains(number)
        else {
            return nil
        }
        return Int(number.rounded())
    }

    static func tokenCount(_ value: Any?) -> Int? {
        guard
            let number = finiteDouble(value),
            number >= 0,
            number <= maximumExactInteger,
            number.rounded(.towardZero) == number
        else {
            return nil
        }
        return Int(number)
    }

    static func unixDate(_ value: Any?) -> Date? {
        guard
            let number = finiteDouble(value),
            (0...maximumUnixTimestamp).contains(number)
        else {
            return nil
        }
        return Date(timeIntervalSince1970: number)
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        let number: Double?
        if let value = value as? NSNumber {
            number = value.doubleValue
        } else if let value = value as? String {
            number = Double(value)
        } else {
            number = nil
        }
        guard let number, number.isFinite else { return nil }
        return number
    }
}

enum AIAccountConnectionService {
    static func login(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await runCancellableWorker(priority: .userInitiated) {
            switch provider {
            case .codex:
                return try await runCodexLogin(accountID: accountID)
            case .claude:
                try runClaudeLogin()
                return try readClaudeStatus()
            }
        }
    }

    static func refresh(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await runCancellableWorker(priority: .utility) {
            switch provider {
            case .codex:
                try await readCodexStatus(accountID: accountID)
            case .claude:
                try readClaudeStatus()
            }
        }
    }

    private static func runCodexLogin(
        accountID: UUID,
        urlOpener: ProviderAuthURLOpener = .workspace
    ) async throws -> ConnectedAIAccountStatus {
        try Task.checkCancellation()
        let executable = try trustedExecutable(named: "codex")
        let home = try codexHome(accountID: accountID)
        return try await connectCodex(
            executable: executable,
            codexHome: home,
            urlOpener: urlOpener
        )
    }

    /// Runs one account-scoped login transaction on one initialized app-server.
    /// The official protocol permits account reads after login completion, so a
    /// second process is not started. If a future protocol version invalidates
    /// that contract, a characterized compatibility fallback belongs here.
    static func connectCodex(
        executable: TrustedProviderExecutable,
        codexHome: URL,
        urlOpener: ProviderAuthURLOpener
    ) async throws -> ConnectedAIAccountStatus {
        try Task.checkCancellation()
        let session = CodexAppServerSession(
            executable: executable,
            codexHome: codexHome
        )
        defer { session.close() }
        do {
            try session.start()
        } catch CodexAppServerSessionFailure.unsafeExecutable {
            throw AIAccountConnectionError.executableMissing("Codex")
        } catch {
            throw AIAccountConnectionError.loginFailed
        }
        do {
            try session.sendInitialization()
            try session.send([
                "method": "account/login/start",
                "id": 4,
                "params": [
                    "type": "chatgpt",
                    "useHostedLoginSuccessPage": true,
                    "appBrand": "codex",
                ],
            ])
        } catch {
            throw AIAccountConnectionError.loginFailed
        }

        guard
            try await session.waitForResponse(id: 4, timeout: 15),
            let startResponse = session.response(id: 4)
        else {
            throw AIAccountConnectionError.loginFailed
        }
        if startResponse["error"] != nil {
            throw AIAccountConnectionError.loginFailed
        }
        guard
            let result = startResponse["result"] as? [String: Any],
            let loginID = result["loginId"] as? String,
            let authURL = result["authUrl"] as? String,
            let validatedAuthURL = ProviderAuthURLPolicy
                .validatedCodexURL(authURL)
        else {
            throw AIAccountConnectionError.loginFailed
        }

        guard await urlOpener.open(validatedAuthURL) else {
            throw AIAccountConnectionError.loginFailed
        }

        guard
            try await session.waitForLoginCompletion(
                loginID: loginID,
                timeout: 300
            ),
            let notification = session.loginCompletion(loginID: loginID),
            notification["success"] as? Bool == true
        else {
            throw AIAccountConnectionError.loginFailed
        }
        return try await readCodexStatus(using: session)
    }

    private static func runClaudeLogin() throws {
        let executable = try trustedExecutable(named: "claude")
        let result: ProviderProcessResult
        do {
            result = try ProviderProcessRunner.run(
                executable: executable,
                arguments: ["auth", "login", "--claudeai"],
                environment: [:],
                timeout: 300,
                cancellationCheck: { Task.isCancelled }
            )
        } catch ProviderProcessFailure.cancelled {
            throw CancellationError()
        } catch {
            throw AIAccountConnectionError.loginFailed
        }
        guard result.status == 0 else {
            throw AIAccountConnectionError.loginFailed
        }
    }

    private static func readClaudeStatus() throws -> ConnectedAIAccountStatus {
        let executable = try trustedExecutable(named: "claude")
        let result: ProviderProcessResult
        do {
            result = try ProviderProcessRunner.run(
                executable: executable,
                arguments: ["auth", "status", "--json"],
                environment: [:],
                timeout: 15,
                cancellationCheck: { Task.isCancelled }
            )
        } catch ProviderProcessFailure.cancelled {
            throw CancellationError()
        } catch {
            throw AIAccountConnectionError.statusUnavailable
        }
        guard result.status == 0 else {
            throw AIAccountConnectionError.notAuthenticated
        }
        guard
            let data = result.output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            throw AIAccountConnectionError.statusUnavailable
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
    ) async throws -> ConnectedAIAccountStatus {
        try Task.checkCancellation()
        let executable = try trustedExecutable(named: "codex")
        let home = try codexHome(accountID: accountID)
        let session = CodexAppServerSession(
            executable: executable,
            codexHome: home
        )
        defer { session.close() }
        do {
            try session.start()
        } catch CodexAppServerSessionFailure.unsafeExecutable {
            throw AIAccountConnectionError.executableMissing("Codex")
        } catch {
            throw AIAccountConnectionError.statusUnavailable
        }
        do {
            try session.sendInitialization()
        } catch {
            throw AIAccountConnectionError.statusUnavailable
        }
        return try await readCodexStatus(using: session)
    }

    private static func readCodexStatus(
        using session: CodexAppServerSession
    ) async throws -> ConnectedAIAccountStatus {
        do {
            try session.send([
                "method": "account/read",
                "id": 1,
                "params": ["refreshToken": false],
            ])
            try session.send([
                "method": "account/rateLimits/read",
                "id": 2,
            ])
            try session.send([
                "method": "account/usage/read",
                "id": 3,
            ])
        } catch {
            throw AIAccountConnectionError.statusUnavailable
        }
        try await session.waitForResponses(ids: [1, 2, 3], timeout: 15)

        guard
            let accountResponse = session.response(id: 1),
            let result = accountResponse["result"] as? [String: Any],
            let account = result["account"] as? [String: Any]
        else {
            throw AIAccountConnectionError.notAuthenticated
        }

        let accountType = account["type"] as? String
        guard accountType == "chatgpt" || accountType == "chatgptAuthTokens" else {
            throw AIAccountConnectionError.statusUnavailable
        }

        var usedPercent: Int?
        var resetsAt: Date?
        if
            let rateResponse = session.response(id: 2),
            let rateResult = rateResponse["result"] as? [String: Any]
        {
            let multi = rateResult["rateLimitsByLimitId"] as? [String: Any]
            let codexBucket = multi?["codex"] as? [String: Any]
            let fallback = rateResult["rateLimits"] as? [String: Any]
            let bucket = codexBucket ?? fallback
            let primary = bucket?["primary"] as? [String: Any]
            usedPercent = ProviderNumericDecoder.percentage(
                primary?["usedPercent"]
            )
            resetsAt = ProviderNumericDecoder.unixDate(primary?["resetsAt"])
        }

        var lifetimeTokens: Int?
        if
            let usageResponse = session.response(id: 3),
            let usageResult = usageResponse["result"] as? [String: Any],
            let summary = usageResult["summary"] as? [String: Any]
        {
            lifetimeTokens = ProviderNumericDecoder.tokenCount(
                summary["lifetimeTokens"]
            )
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

    private static func trustedExecutable(
        named name: String
    ) throws -> TrustedProviderExecutable {
        do {
            return try ProviderExecutableLocator().locate(named: name)
        } catch {
            throw AIAccountConnectionError.executableMissing(name.capitalized)
        }
    }

    private static func runCancellableWorker<T: Sendable>(
        priority: TaskPriority,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let worker = Task.detached(priority: priority, operation: operation)
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }
}
