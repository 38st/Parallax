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
            usageWindows: lifecycleSource?.usageWindows ?? []
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
        if provider != baseline.provider { merged.provider = provider }
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
    let sharedIdentityWarning: CorporateSharedIdentityWarning?

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
            sharedIdentityWarning = nil
        case .claude:
            disconnectedDetail = String(
                localized:
                    "Parallax uses this Mac’s current Claude Code sign-in; this record does not create a separate Claude identity."
            )
            capabilityDetail = String(
                localized:
                    "Claude uses this Mac’s current Claude Code sign-in and its local /usage command for live session and weekly limits. Multiple Claude records still share one identity and the same limits."
            )
            sharedIdentityWarning = CorporateSharedIdentityWarning(
                title: String(
                    localized: "Change this Mac’s Claude Code sign-in?"
                ),
                message: String(
                    localized:
                        "Continuing changes this Mac’s ambient Claude Code identity, which Claude Code and every Claude record in Parallax share. It does not create a separate account session."
                ),
                continueTitle: String(
                    localized: "Continue to Claude Sign-In"
                )
            )
        }
    }
}

struct CorporateSharedIdentityWarning: Equatable, Sendable {
    let title: String
    let message: String
    let continueTitle: String
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
            CorporateAccountFreshnessPolicy.currentAgeThreshold
    ) {
        freshness = CorporateAccountFreshnessPolicy.state(
            for: account,
            now: now,
            ageThreshold: ageThreshold
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

        // TrackedAIAccount predates live provider connections and always stores
        // a reset date. Without provenance, that value may still be its locally
        // invented fallback even after a refresh that returned no reset.
        if account.provider == .claude,
            let primaryWindow = account.usageWindows.max(by: {
                $0.normalizedUsagePercent < $1.normalizedUsagePercent
            })
        {
            resetsAt = primaryWindow.resetsAt
            hasCurrentUsage = true
        } else {
            resetsAt = nil
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

    init(account: TrackedAIAccount, now: Date = Date()) {
        let metadata = CorporateAccountMetadataPresentation(
            account: account,
            now: now
        )

        switch metadata.freshness {
        case let .failed(_, _, failure):
            if failure == .authenticationRequired {
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

    init(accounts: [TrackedAIAccount], now: Date = Date()) {
        currentUsageAccounts = accounts.filter {
            CorporateAccountMetadataPresentation(account: $0, now: now)
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
                ?? usageWindows.map(\.normalizedUsagePercent).max()
                ?? updated.usagePercent
            if let resetsAt = status.resetsAt {
                updated.resetsAt = resetsAt
            }
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
            updated.lifetimeTokens = status.lifetimeTokens
            updated.usageWindows = []
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
