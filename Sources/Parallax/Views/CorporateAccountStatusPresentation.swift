import Foundation

enum CorporateAccountStatusTone: Equatable, Sendable {
    case secondary
    case available
    case attention
}

struct CorporateAccountFailurePresentation: Equatable, Sendable {
    let statusLabel: String
    let noticeTitle: String
    let activityTitle: String
    let accessibilityLabel: String

    init(
        account: TrackedAIAccount,
        failure: TrackedAccountRefreshFailure
    ) {
        if failure == .authenticationRequired || account.needsSignIn {
            statusLabel = String(localized: "Sign-in required")
            noticeTitle = statusLabel
            activityTitle = String(
                localized: "Sign-in required for \(account.label)"
            )
            accessibilityLabel = activityTitle
        } else if failure == .incompleteProviderData && account.isSignedIn {
            statusLabel = String(localized: "Usage unavailable")
            noticeTitle = String(localized: "Signed in — usage unavailable")
            activityTitle = String(
                localized:
                    "Signed in, but usage is unavailable for \(account.label)"
            )
            accessibilityLabel = activityTitle
        } else if account.lastAttemptKind == .signIn,
            failure != .statusUnavailable, failure != .persistenceUnavailable
        {
            statusLabel = String(localized: "Sign-in failed")
            noticeTitle = statusLabel
            activityTitle = String(
                localized: "Sign-in failed for \(account.label)"
            )
            accessibilityLabel = activityTitle
        } else {
            statusLabel = failure == .incompleteProviderData
                ? String(localized: "Usage unavailable")
                : String(localized: "Refresh failed")
            noticeTitle = failure == .incompleteProviderData
                ? String(localized: "Current usage is unavailable")
                : String(localized: "Refresh failed")
            activityTitle = String(
                localized: "Refresh failed for \(account.label)"
            )
            accessibilityLabel = activityTitle
        }
    }
}

struct CorporateAccountStatusPresentation: Equatable, Sendable {
    let label: String
    let tone: CorporateAccountStatusTone
    let activityTitle: String
    let accessibilityLabel: String

    init(
        account: TrackedAIAccount,
        now: Date = Date(),
        inFlightAttemptKind: TrackedAccountAttemptKind? = nil
    ) {
        let metadata = CorporateAccountMetadataPresentation(
            account: account,
            now: now,
            inFlightAttemptKind: inFlightAttemptKind
        )

        switch metadata.freshness {
        case let .refreshing(kind, _):
            tone = .secondary
            if kind == .signIn {
                label = String(localized: "Signing in")
                activityTitle = String(
                    localized: "Waiting for browser sign-in for \(account.label)"
                )
                accessibilityLabel = activityTitle
            } else {
                label = String(localized: "Refreshing")
                activityTitle = String(
                    localized: "Refreshing usage for \(account.label)"
                )
                accessibilityLabel = activityTitle
            }
            return
        case let .failed(_, _, failure):
            let presentation = CorporateAccountFailurePresentation(
                account: account,
                failure: failure
            )
            label = presentation.statusLabel
            activityTitle = presentation.activityTitle
            accessibilityLabel = presentation.accessibilityLabel
            tone = .attention
            return
        case .stale:
            label = String(localized: "Stale")
            tone = .secondary
            activityTitle = String(
                localized: "Provider data is stale for \(account.label)"
            )
            accessibilityLabel = String(
                localized: "Provider data is stale for \(account.label)"
            )
            return
        case .neverRefreshed:
            if account.isConnected == true {
                label = String(localized: "Never refreshed")
                tone = .secondary
                activityTitle = String(
                    localized: "Provider status has not refreshed for \(account.label)"
                )
                accessibilityLabel = String(
                    localized: "Provider status has never refreshed for \(account.label)"
                )
                return
            }
        case .current:
            break
        }

        guard account.isConnected == true else {
            label = String(localized: "Not connected")
            tone = .secondary
            activityTitle = String(
                localized: "Provider status checked for \(account.label)"
            )
            accessibilityLabel = String(
                localized: "Not connected: \(account.label)"
            )
            return
        }

        if !metadata.hasCurrentUsage {
            label = String(localized: "Refresh needed")
            tone = .secondary
            activityTitle = String(
                localized: "Provider status refreshed for \(account.label)"
            )
            accessibilityLabel = String(
                localized: "Refresh needed for \(account.label)"
            )
        } else if account.normalizedUsagePercent >= 100 {
            label = String(localized: "Limit reached")
            tone = .attention
            activityTitle = String(
                localized: "Usage synced for \(account.label)"
            )
            accessibilityLabel = String(
                localized: "Limit reached for \(account.label)"
            )
        } else if account.needsAttention {
            label = String(localized: "Running low")
            tone = .attention
            activityTitle = String(
                localized: "Usage synced for \(account.label)"
            )
            accessibilityLabel = String(
                localized: "Running low: \(account.label)"
            )
        } else {
            label = String(localized: "Available")
            tone = .available
            activityTitle = String(
                localized: "Usage synced for \(account.label)"
            )
            accessibilityLabel = String(
                localized: "Available: \(account.label)"
            )
        }
    }
}
