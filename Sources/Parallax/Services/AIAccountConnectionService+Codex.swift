import AppKit
import CoreFoundation
import Foundation
import os

extension AIAccountConnectionService {
    static func runCodexLogin(
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

    static func readCodexStatus(
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

    static func codexHome(accountID: UUID) throws -> URL {
        try accountSessionDirectory(
            accountID: accountID,
            component: "CodexHome"
        )
    }
}
