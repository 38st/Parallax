import Foundation

struct CorporateAccountEditorContext: Identifiable {
    let id: UUID
    let account: TrackedAIAccount?

    init(account: TrackedAIAccount? = nil) {
        self.account = account
        id = account?.id ?? UUID()
    }
}

struct TrackedAccountEditorDraft: Equatable, Sendable {
    var provider: AIProvider
    var label: String
    var email: String
    var planName: String
    var usagePercent: Int
    var resetsAt: Date
    private let lifecycleSource: TrackedAIAccount?

    init(account: TrackedAIAccount?, now: Date = Date()) {
        lifecycleSource = account
        provider = account?.provider ?? .codex
        label = account?.label ?? ""
        email = account?.email ?? ""
        planName = account?.planName ?? "Subscription"
        usagePercent = account?.normalizedUsagePercent ?? 0
        resetsAt = account?.resetsAt
            ?? Calendar.current.date(byAdding: .month, value: 1, to: now)
            ?? now
    }

    func account(id: UUID) -> TrackedAIAccount {
        TrackedAIAccount(
            id: id,
            provider: provider,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            planName: planName.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
                ? "Subscription"
                : planName.trimmingCharacters(in: .whitespacesAndNewlines),
            usagePercent: usagePercent,
            resetsAt: resetsAt,
            lastCheckedAt: nil,
            isConnected: lifecycleSource?.isConnected ?? false,
            lifetimeTokens: lifecycleSource?.lifetimeTokens,
            lastSuccessfulRefreshAt:
                lifecycleSource?.lastSuccessfulRefreshAt,
            lastRefreshAttemptAt: lifecycleSource?.lastRefreshAttemptAt,
            lastRefreshCompletedAt:
                lifecycleSource?.lastRefreshCompletedAt,
            lastAttemptKind: lifecycleSource?.lastAttemptKind,
            lastRefreshFailure: lifecycleSource?.lastRefreshFailure,
            usageWindows: lifecycleSource?.usageWindows ?? [],
            providerResetsAt: lifecycleSource?.providerResetsAt
        )
    }

    /// Applies only fields changed in the editor to the latest live record.
    /// Untouched provider data and the entire freshness lifecycle survive a
    /// refresh that completes while the editor is open.
    func merging(into current: TrackedAIAccount) -> TrackedAIAccount {
        guard let baseline = lifecycleSource, baseline.id == current.id else {
            return account(id: current.id)
        }
        var merged = current
        if label != baseline.label {
            merged.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if email != baseline.email {
            merged.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if planName != baseline.planName {
            let normalized = planName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            merged.planName = normalized.isEmpty ? "Subscription" : normalized
        }
        if usagePercent != baseline.normalizedUsagePercent {
            merged.usagePercent = usagePercent
        }
        if resetsAt != baseline.resetsAt { merged.resetsAt = resetsAt }
        return merged
    }
}

enum AccountConnectionActivity: Equatable {
    case idle
    case refreshing
    case signingIn
    case failed(String)

    var isWorking: Bool {
        self == .refreshing || self == .signingIn
    }
}

struct AccountConnectionOperation: Equatable {
    let generation: UUID
    let activity: AccountConnectionActivity

    func visibleActivity(
        isGenerationCurrent: Bool
    ) -> AccountConnectionActivity {
        activity.isWorking && !isGenerationCurrent ? .idle : activity
    }

    func belongs(to generation: UUID) -> Bool {
        self.generation == generation
    }
}

struct CorporateAccountIsolationPresentation: Equatable, Sendable {
    let disconnectedDetail: String
    let capabilityDetail: String

    init(provider: AIProvider) {
        switch provider {
        case .codex:
            disconnectedDetail = String(
                localized:
                    "Parallax uses an account-specific Codex login home for this tracked account."
            )
            capabilityDetail = String(
                localized:
                    "Codex uses its official local app-server with an account-specific Parallax login home for ChatGPT sign-in and live limits."
            )
        case .claude:
            disconnectedDetail = String(
                localized:
                    "Parallax uses an account-specific Claude Code home for this tracked account."
            )
            capabilityDetail = String(
                localized:
                    "Claude Code uses an account-specific Parallax home for sign-in, configuration, saved sessions, and live usage limits."
            )
        }
    }
}

struct CorporateAccountMetadataPresentation: Equatable, Sendable {
    let planName: String?
    let resetsAt: Date?
    let hasCurrentUsage: Bool
    let retainedUsagePercent: Int?
    let freshness: CorporateAccountFreshnessState

    init(
        account: TrackedAIAccount,
        now: Date = Date(),
        ageThreshold: TimeInterval =
            CorporateAccountFreshnessPolicy.currentAgeThreshold,
        inFlightAttemptKind: TrackedAccountAttemptKind? = nil
    ) {
        freshness = CorporateAccountFreshnessPolicy.state(
            for: account,
            now: now,
            ageThreshold: ageThreshold,
            inFlightAttemptKind: inFlightAttemptKind
        )
        if account.lastSuccessfulRefreshAt != nil,
            (account.provider == .codex || !account.usageWindows.isEmpty),
            !freshness.isCurrent
        {
            retainedUsagePercent = account.normalizedUsagePercent
        } else {
            retainedUsagePercent = nil
        }

        guard account.isConnected == true, freshness.isCurrent else {
            planName = nil
            resetsAt = nil
            hasCurrentUsage = false
            return
        }

        let trimmedPlan = account.planName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        planName = trimmedPlan.isEmpty || trimmedPlan == "Subscription"
            ? nil
            : trimmedPlan

        if let primaryWindow = account.usageWindows.mostExhausted {
            resetsAt = primaryWindow.resetsAt
            hasCurrentUsage = true
        } else {
            // The legacy `resetsAt` field is user-editable and predates live
            // provider status. Only this optional field proves that Codex
            // supplied the timestamp for the currently displayed window.
            resetsAt = account.providerResetsAt
            hasCurrentUsage = account.provider == .codex
        }
    }
}

enum CorporateAccountStatusTone: Equatable, Sendable {
    case secondary
    case available
    case attention
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
            if failure == .authenticationRequired || account.needsSignIn {
                label = String(localized: "Sign-in required")
                activityTitle = String(
                    localized: "Sign-in required for \(account.label)"
                )
                accessibilityLabel = String(
                    localized: "Sign-in required for \(account.label)"
                )
            } else if account.lastAttemptKind == .signIn {
                label = String(localized: "Sign-in failed")
                activityTitle = String(
                    localized: "Sign-in failed for \(account.label)"
                )
                accessibilityLabel = String(
                    localized: "Sign-in failed for \(account.label)"
                )
            } else {
                label = failure == .incompleteProviderData
                    ? String(localized: "Usage unavailable")
                    : String(localized: "Refresh failed")
                activityTitle = String(
                    localized: "Refresh failed for \(account.label)"
                )
                accessibilityLabel = String(
                    localized: "Refresh failed for \(account.label)"
                )
            }
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

struct CorporateAccountUsageAggregation: Equatable, Sendable {
    let currentUsageAccounts: [TrackedAIAccount]

    /// - Parameter inFlightAttemptKinds: Operations currently running, keyed
    ///   by account id, so an account being refreshed keeps its still-current
    ///   values in the tiles instead of vanishing for the duration.
    init(
        accounts: [TrackedAIAccount],
        now: Date = Date(),
        inFlightAttemptKinds: [UUID: TrackedAccountAttemptKind] = [:]
    ) {
        currentUsageAccounts = accounts.filter {
            CorporateAccountMetadataPresentation(
                account: $0,
                now: now,
                inFlightAttemptKind: inFlightAttemptKinds[$0.id]
            )
            .hasCurrentUsage
        }
    }

    var availableAccounts: [TrackedAIAccount] {
        currentUsageAccounts.filter { !$0.needsAttention }
    }

    var nearLimitAccounts: [TrackedAIAccount] {
        currentUsageAccounts
            .filter(\.needsAttention)
            .sorted {
                $0.normalizedUsagePercent > $1.normalizedUsagePercent
            }
    }

    var averageUsagePercent: Int? {
        guard !currentUsageAccounts.isEmpty else { return nil }
        return currentUsageAccounts.reduce(0) {
            $0 + $1.normalizedUsagePercent
        } / currentUsageAccounts.count
    }
}

struct CorporateAccountRefreshApplication: Equatable, Sendable {
    let account: TrackedAIAccount
    let failure: TrackedAccountRefreshFailure?

    init(status: ConnectedAIAccountStatus, account: TrackedAIAccount) {
        var updated = account
        updated.isConnected = true
        updated.signInRequired = false
        if let email = status.email, !email.isEmpty {
            updated.email = email
        }

        switch account.provider {
        case .claude:
            guard
                let usageWindows = status.usageWindows,
                !usageWindows.isEmpty
            else {
                self.account = updated
                failure = .incompleteProviderData
                return
            }
            updated.usageWindows = usageWindows
            updated.usagePercent = status.usagePercent
                ?? usageWindows.mostExhausted?.normalizedUsagePercent
                ?? updated.usagePercent
            if let resetsAt = status.resetsAt {
                updated.resetsAt = resetsAt
            }
            updated.providerResetsAt = status.resetsAt
            if let planName = Self.normalizedClaudePlan(status.planName) {
                updated.planName = planName
            }
            updated.lifetimeTokens = nil
            self.account = updated
            failure = nil
        case .codex:
            guard let usagePercent = status.usagePercent else {
                self.account = updated
                failure = .incompleteProviderData
                return
            }
            updated.usagePercent = usagePercent
            if let planName = status.planName, !planName.isEmpty {
                updated.planName = planName.capitalized
            }
            if let resetsAt = status.resetsAt {
                updated.resetsAt = resetsAt
            }
            updated.providerResetsAt = status.resetsAt
            updated.lifetimeTokens = status.lifetimeTokens
            updated.usageWindows = status.usageWindows ?? []
            self.account = updated
            failure = nil
        }
    }

    private static func normalizedClaudePlan(_ value: String?) -> String? {
        guard let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else {
            return nil
        }
        switch normalized {
        case "free": return "Free"
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        default: return nil
        }
    }
}
