import AppKit
import CoreFoundation
import Foundation
import os

/// Local-only diagnostics for provider tool failures. Provider text stays
/// private in the unified log and is never rendered in the UI, but it makes
/// an incident such as "every account flipped to sign-in required at 17:50"
/// explainable afterwards.
enum ProviderDiagnostics {
    static func log(provider: String, event: String, detail: String = "") {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppLog.provider.error(
                "\(provider, privacy: .public): \(event, privacy: .public)"
            )
        } else {
            let excerpt = String(trimmed.prefix(2_000))
            AppLog.provider.error(
                "\(provider, privacy: .public): \(event, privacy: .public) — \(excerpt, privacy: .private)"
            )
        }
    }
}

struct ConnectedAIAccountStatus: Sendable, Equatable {
    let email: String?
    let planName: String?
    let usagePercent: Int?
    let resetsAt: Date?
    let lifetimeTokens: Int?
    let usageWindows: [AIUsageWindow]?

    init(
        email: String?,
        planName: String?,
        usagePercent: Int?,
        resetsAt: Date?,
        lifetimeTokens: Int?,
        usageWindows: [AIUsageWindow]? = nil
    ) {
        self.email = email
        self.planName = planName
        self.usagePercent = usagePercent
        self.resetsAt = resetsAt
        self.lifetimeTokens = lifetimeTokens
        self.usageWindows = usageWindows
    }
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
        let number: Double?
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else {
                return nil
            }
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

struct ClaudeAuthenticationStatus: Equatable, Sendable {
    let isAuthenticated: Bool
    let email: String?
    let planName: String?
}

enum ClaudeAuthenticationStatusDecoder {
    static func decode(_ output: String) throws -> ClaudeAuthenticationStatus {
        guard
            let data = output.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any]
        else {
            throw AIAccountConnectionError.statusUnavailable
        }
        guard let isAuthenticated = strictBoolean(json["loggedIn"])
            ?? strictBoolean(json["isAuthenticated"])
        else {
            // Authentication state is security-sensitive. Unknown or changed
            // provider schemas must not be promoted to a signed-in state.
            throw AIAccountConnectionError.statusUnavailable
        }
        let email = json["email"] as? String
            ?? (json["account"] as? [String: Any])?["email"] as? String
        let plan = json["subscriptionType"] as? String
            ?? json["plan"] as? String
            ?? json["authMethod"] as? String
        return ClaudeAuthenticationStatus(
            isAuthenticated: isAuthenticated,
            email: email,
            planName: plan
        )
    }

    private static func strictBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.boolValue
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
                let configDirectory = try claudeConfig(accountID: accountID)
                try await runClaudeLogin(configDirectory: configDirectory)
                return try await readClaudeStatus(
                    configDirectory: configDirectory
                )
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
                try await readClaudeStatus(
                    configDirectory: claudeConfig(accountID: accountID)
                )
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
                    // Parallax owns this login session. A hosted,
                    // Codex-branded success page offers to open the Codex
                    // desktop app even though the account credentials were
                    // written to this session's isolated CODEX_HOME.
                    "useHostedLoginSuccessPage": false,
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

        let loginCompleted = try await session.waitForLoginCompletion(
            loginID: loginID,
            timeout: 300
        )
        guard
            loginCompleted,
            let notification = session.loginCompletion(loginID: loginID),
            notification["success"] as? Bool == true
        else {
            if !loginCompleted {
                // Tell the app-server to stop waiting on the browser so the
                // abandoned login cannot complete against a closed session.
                try? session.send([
                    "method": "account/login/cancel",
                    "id": 5,
                    "params": ["loginId": loginID],
                ])
            }
            ProviderDiagnostics.log(
                provider: "codex",
                event: loginCompleted
                    ? "login completed without success"
                    : "login timed out",
                detail: (session.loginCompletion(loginID: loginID)?["error"]
                    as? String ?? "")
                    + "\n" + session.standardErrorOutput
            )
            throw AIAccountConnectionError.loginFailed
        }
        return try await readCodexStatus(using: session)
    }

    private static func runClaudeLogin(configDirectory: URL) async throws {
        let executable = try trustedExecutable(named: "claude")
        let result: ProviderProcessResult
        do {
            result = try await ProviderProcessRunner.runDetached(
                executable: executable,
                arguments: ["auth", "login", "--claudeai"],
                environment: claudeTrackingEnvironment(
                    configDirectory: configDirectory
                ),
                timeout: 300
            )
        } catch ProviderProcessFailure.cancelled {
            throw CancellationError()
        } catch {
            throw AIAccountConnectionError.loginFailed
        }
        guard result.status == 0 else {
            ProviderDiagnostics.log(
                provider: "claude",
                event: "login exited with status \(result.status)",
                detail: result.errorOutput
            )
            throw AIAccountConnectionError.loginFailed
        }
    }

    private static func readClaudeStatus(
        configDirectory: URL
    ) async throws -> ConnectedAIAccountStatus {
        let executable = try trustedExecutable(named: "claude")
        let result: ProviderProcessResult
        do {
            result = try await ProviderProcessRunner.runDetached(
                executable: executable,
                arguments: ["auth", "status", "--json"],
                environment: claudeTrackingEnvironment(
                    configDirectory: configDirectory
                ),
                timeout: 15
            )
        } catch ProviderProcessFailure.cancelled {
            throw CancellationError()
        } catch {
            throw AIAccountConnectionError.statusUnavailable
        }
        // The CLI exits non-zero both when logged out and on any internal
        // failure, so the exit code carries no authentication meaning. Only
        // an explicit `loggedIn: false` in decodable output does.
        let authentication: ClaudeAuthenticationStatus
        do {
            authentication = try ClaudeAuthenticationStatusDecoder.decode(
                result.output
            )
        } catch {
            ProviderDiagnostics.log(
                provider: "claude",
                event: "auth status undecodable (exit \(result.status))",
                detail: result.errorOutput
            )
            throw AIAccountConnectionError.statusUnavailable
        }
        guard authentication.isAuthenticated else {
            throw AIAccountConnectionError.notAuthenticated
        }
        let usageWindows = try await readClaudeUsage(
            executable: executable,
            configDirectory: configDirectory
        )
        let primaryWindow = usageWindows.mostExhausted

        return ConnectedAIAccountStatus(
            email: authentication.email,
            planName: authentication.planName,
            usagePercent: primaryWindow?.normalizedUsagePercent,
            resetsAt: primaryWindow?.resetsAt,
            lifetimeTokens: nil,
            usageWindows: usageWindows
        )
    }

    private static func readClaudeUsage(
        executable: TrustedProviderExecutable,
        configDirectory: URL
    ) async throws -> [AIUsageWindow] {
        let result: ProviderProcessResult
        do {
            result = try await ProviderProcessRunner.runDetached(
                executable: executable,
                arguments: [
                    "-p",
                    "/usage",
                    "--output-format",
                    "json",
                    "--tools",
                    "",
                    "--safe-mode",
                    "--no-session-persistence",
                    "--max-budget-usd",
                    "0.000001",
                ],
                environment: claudeTrackingEnvironment(
                    configDirectory: configDirectory
                ),
                timeout: 30
            )
        } catch ProviderProcessFailure.cancelled {
            throw CancellationError()
        } catch {
            throw AIAccountConnectionError.statusUnavailable
        }
        guard result.status == 0 else {
            ProviderDiagnostics.log(
                provider: "claude",
                event: "usage read exited with status \(result.status)",
                detail: result.errorOutput
            )
            throw AIAccountConnectionError.statusUnavailable
        }
        do {
            return try ClaudeUsageOutputParser.parse(result.output)
        } catch {
            ProviderDiagnostics.log(
                provider: "claude",
                event: "usage output unparseable: \(error)",
                detail: result.errorOutput
            )
            throw AIAccountConnectionError.statusUnavailable
        }
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

        // The account read may include a token refresh on the provider side,
        // so it gets its own budget. The two usage reads are best effort.
        let accountOutcome = try await session.waitForResponses(
            ids: [1],
            timeout: 15
        )
        guard let accountResponse = session.response(id: 1) else {
            ProviderDiagnostics.log(
                provider: "codex",
                event: "account/read produced no response (\(accountOutcome))",
                detail: session.standardErrorOutput
            )
            throw AIAccountConnectionError.statusUnavailable
        }
        if let error = accountResponse["error"] {
            // An error reply (network, token refresh, protocol) is not a
            // logged-out answer. Only `account: null` is.
            ProviderDiagnostics.log(
                provider: "codex",
                event: "account/read returned an error",
                detail: String(describing: error)
                    + "\n" + session.standardErrorOutput
            )
            throw AIAccountConnectionError.statusUnavailable
        }
        guard
            let result = accountResponse["result"] as? [String: Any],
            let accountValue = result["account"]
        else {
            ProviderDiagnostics.log(
                provider: "codex",
                event: "account/read result lacks an account field"
            )
            throw AIAccountConnectionError.statusUnavailable
        }
        guard !(accountValue is NSNull) else {
            throw AIAccountConnectionError.notAuthenticated
        }
        guard let account = accountValue as? [String: Any] else {
            throw AIAccountConnectionError.statusUnavailable
        }

        let accountType = account["type"] as? String
        guard accountType == "chatgpt" || accountType == "chatgptAuthTokens" else {
            ProviderDiagnostics.log(
                provider: "codex",
                event: "unsupported account type \(accountType ?? "nil")"
            )
            throw AIAccountConnectionError.statusUnavailable
        }

        _ = try await session.waitForResponses(ids: [2, 3], timeout: 10)

        var usageWindows: [AIUsageWindow] = []
        if
            let rateResponse = session.response(id: 2),
            let rateResult = rateResponse["result"] as? [String: Any]
        {
            let multi = rateResult["rateLimitsByLimitId"] as? [String: Any]
            let codexBucket = multi?["codex"] as? [String: Any]
            let fallback = rateResult["rateLimits"] as? [String: Any]
            usageWindows = codexUsageWindows(bucket: codexBucket ?? fallback)
        } else if let rateResponse = session.response(id: 2) {
            ProviderDiagnostics.log(
                provider: "codex",
                event: "rateLimits/read returned no result",
                detail: String(describing: rateResponse["error"] ?? "")
            )
        }
        let primaryWindow = usageWindows.mostExhausted

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
            usagePercent: primaryWindow?.normalizedUsagePercent,
            resetsAt: primaryWindow?.resetsAt,
            lifetimeTokens: lifetimeTokens,
            usageWindows: usageWindows.isEmpty ? nil : usageWindows
        )
    }

    /// Codex reports a short (5-hour) `primary` window and, on most plans, a
    /// weekly `secondary` window. Reading only `primary` hides a weekly
    /// exhaustion behind a fresh short window.
    ///
    /// The window key is the stable identity; `windowDurationMins` is
    /// optional display metadata. With two windows the shorter one is the
    /// session and the longer one the weekly window, so neither is dropped
    /// even when the provider omits durations.
    static func codexUsageWindows(bucket: [String: Any]?) -> [AIUsageWindow] {
        struct RawWindow {
            let order: Int
            let minutes: Int?
            let percent: Int
            let resetsAt: Date?
        }
        var raw: [RawWindow] = []
        for (order, key) in ["primary", "secondary"].enumerated() {
            guard
                let window = bucket?[key] as? [String: Any],
                let percent = ProviderNumericDecoder.percentage(
                    window["usedPercent"]
                )
            else { continue }
            raw.append(
                RawWindow(
                    order: order,
                    minutes: ProviderNumericDecoder.tokenCount(
                        window["windowDurationMins"]
                    ),
                    percent: percent,
                    resetsAt: ProviderNumericDecoder.unixDate(
                        window["resetsAt"]
                    )
                )
            )
        }
        raw.sort { lhs, rhs in
            switch (lhs.minutes, rhs.minutes) {
            case let (l?, r?) where l != r: return l < r
            default: return lhs.order < rhs.order
            }
        }
        return raw.enumerated().map { index, window in
            let kind: AIUsageWindowKind
            if raw.count > 1 {
                kind = index == 0 ? .session : .weeklyAllModels
            } else {
                kind = (window.minutes ?? 0) > 24 * 60
                    ? .weeklyAllModels
                    : .session
            }
            return AIUsageWindow(
                kind: kind,
                usagePercent: window.percent,
                resetsAt: window.resetsAt
            )
        }
    }

    /// Every Control Center Claude account receives a distinct provider home.
    /// Claude Code stores authentication and configuration beneath this path,
    /// keeping sign-in and usage reads bound to the selected tracking record.
    static func claudeTrackingEnvironment(
        configDirectory: URL
    ) -> [String: String] {
        [
            "CLAUDE_CONFIG_DIR": configDirectory.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TZ": "UTC",
        ]
    }

    static func accountSessionDirectory(
        accountID: UUID,
        component: String,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let base: URL
        if let applicationSupportURL {
            base = applicationSupportURL
        } else {
            base = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        guard component == "ClaudeConfig" || component == "CodexHome" else {
            throw AIAccountConnectionError.statusUnavailable
        }
        let directory = base
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("AccountSessions", isDirectory: true)
            .appendingPathComponent(accountID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent(component, isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return directory
    }

    static func codexHome(accountID: UUID) throws -> URL {
        try accountSessionDirectory(
            accountID: accountID,
            component: "CodexHome"
        )
    }

    private static func claudeConfig(accountID: UUID) throws -> URL {
        try accountSessionDirectory(
            accountID: accountID,
            component: "ClaudeConfig"
        )
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
