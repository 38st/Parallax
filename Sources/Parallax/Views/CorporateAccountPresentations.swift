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
        planName = account?.planName ?? ""
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
            planName: planName.trimmingCharacters(in: .whitespacesAndNewlines),
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

    @MainActor
    @discardableResult
    func save(to store: CorporateUsageStore, id: UUID, onSaved: () -> Void) -> Bool {
        let updated: TrackedAIAccount
        if lifecycleSource != nil {
            guard let current = store.trackedAccounts.first(where: { $0.id == id }) else {
                return false
            }
            updated = merging(into: current)
        } else {
            updated = account(id: id)
        }
        guard store.saveTrackedAccount(updated) else { return false }
        onSaved()
        return true
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
            merged.planName = normalized
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
            || trimmedPlan == String(localized: "Subscription")
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
            if let planName = Self.normalizedClaudePlan(status.planName) {
                updated.planName = planName
            }
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
            updated.lifetimeTokens = nil
            self.account = updated
            failure = nil
        case .codex:
            if let planName = status.planName, !planName.isEmpty {
                updated.planName = planName.capitalized
            }
            guard let usagePercent = status.usagePercent else {
                if let lifetimeTokens = status.lifetimeTokens {
                    updated.lifetimeTokens = lifetimeTokens
                }
                self.account = updated
                failure = .incompleteProviderData
                return
            }
            updated.lifetimeTokens = status.lifetimeTokens
            updated.usagePercent = usagePercent
            if let resetsAt = status.resetsAt {
                updated.resetsAt = resetsAt
            }
            updated.providerResetsAt = status.resetsAt
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
