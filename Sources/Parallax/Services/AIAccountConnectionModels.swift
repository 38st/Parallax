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
        case .executableMissing:
            TrackedAccountRefreshFailure.providerToolUnavailable.userMessage
        case .notAuthenticated:
            TrackedAccountRefreshFailure.authenticationRequired.userMessage
        case .loginFailed:
            TrackedAccountRefreshFailure.signInFailed.userMessage
        case .statusUnavailable:
            TrackedAccountRefreshFailure.statusUnavailable.userMessage
        }
    }
}
