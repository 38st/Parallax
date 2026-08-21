import Foundation
import Observation

@MainActor
@Observable
final class CorporateUsageStore {
    private var persistenceEnvelope: LegacyCorporateWorkspaceEnvelope
    private let userDefaults: UserDefaults
    private let persistenceKey: String
    private let clock: () -> Date
    private let freshnessScheduler: any CorporateFreshnessScheduling
    private var accountOperationGenerations: [UUID: UUID] = [:]
    private(set) var freshnessRevision = 0

    var trackedAccounts: [TrackedAIAccount] {
        persistenceEnvelope.trackedAccounts ?? Self.defaultTrackedAccounts
    }
    var currentDate: Date {
        _ = freshnessRevision
        return clock()
    }

    init(
        userDefaults: UserDefaults = .standard,
        persistenceKey: String = "corporate.workspace.v1",
        initialAccounts: [TrackedAIAccount]? = nil,
        clock: @escaping () -> Date = Date.init,
        freshnessScheduler: any CorporateFreshnessScheduling =
            CorporateTimerFreshnessScheduler()
    ) {
        self.userDefaults = userDefaults
        self.persistenceKey = persistenceKey
        self.clock = clock
        self.freshnessScheduler = freshnessScheduler

        if let initialAccounts {
            persistenceEnvelope = .fresh(trackedAccounts: initialAccounts)
        } else if
            let data = userDefaults.data(forKey: persistenceKey),
            let decoded = try? JSONDecoder().decode(
                LegacyCorporateWorkspaceEnvelope.self,
                from: data
            )
        {
            persistenceEnvelope = decoded
        } else {
            persistenceEnvelope = .fresh(
                trackedAccounts: Self.defaultTrackedAccounts
            )
        }

        if normalizeSharedCredentialConnections() {
            persist()
        }

        freshnessScheduler.schedule { [weak self] in
            self?.freshnessRevision &+= 1
        }
    }

    @discardableResult
    func saveTrackedAccount(_ account: TrackedAIAccount) -> Bool {
        if let existing = trackedAccounts.first(where: { $0.id == account.id }) {
            guard existing.provider == account.provider else { return false }
        } else {
            guard canAddTrackedAccount(provider: account.provider) else {
                return false
            }
        }
        accountOperationGenerations.removeValue(forKey: account.id)
        upsertTrackedAccount(account)
        return true
    }

    private func upsertTrackedAccount(_ account: TrackedAIAccount) {
        var accounts = trackedAccounts
        if account.isConnected == true,
           account.provider.accountCapabilities.credentialScope
            == .macOSUserShared
        {
            for index in accounts.indices where
                accounts[index].provider == account.provider
                    && accounts[index].id != account.id
            {
                accounts[index].isConnected = false
            }
        }
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        persistenceEnvelope.trackedAccounts = accounts.sorted {
            if $0.provider != $1.provider {
                return $0.provider.rawValue > $1.provider.rawValue
            }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        persist()
    }

    @discardableResult
    func recordRefreshSuccess(
        _ account: TrackedAIAccount,
        operationGeneration: UUID
    ) -> Bool {
        guard let current = consumeOperation(
            accountID: account.id,
            generation: operationGeneration
        ) else { return false }
        var updated = account
        let refreshedAt = currentDate
        updated.lastRefreshAttemptAt = current.lastRefreshAttemptAt
        updated.lastAttemptKind = current.lastAttemptKind
        updated.lastSuccessfulRefreshAt = refreshedAt
        updated.lastRefreshCompletedAt = refreshedAt
        updated.lastRefreshFailure = nil
        upsertTrackedAccount(updated)
        return true
    }

    @discardableResult
    func recordRefreshAttempt(
        accountID: UUID,
        kind: TrackedAccountAttemptKind
    ) -> UUID? {
        guard var account = trackedAccounts.first(where: { $0.id == accountID })
        else { return nil }
        if kind == .signIn,
           account.provider.accountCapabilities.credentialScope
            == .macOSUserShared
        {
            var accounts = trackedAccounts
            for index in accounts.indices where
                accounts[index].provider == account.provider
            {
                accounts[index].isConnected = false
            }
            persistenceEnvelope.trackedAccounts = accounts
            guard let invalidated = accounts.first(where: {
                $0.id == accountID
            }) else { return nil }
            account = invalidated
        }
        let generation = UUID()
        account.lastRefreshAttemptAt = currentDate
        account.lastRefreshCompletedAt = nil
        account.lastAttemptKind = kind
        account.lastRefreshFailure = nil
        // Persist the interrupted-attempt evidence before the caller invokes
        // the provider. A crash or cancellation after this return therefore
        // cannot look like a completed refresh after restart.
        upsertTrackedAccount(account)
        accountOperationGenerations[accountID] = generation
        return generation
    }

    func isCurrentOperation(
        accountID: UUID,
        generation: UUID
    ) -> Bool {
        accountOperationGenerations[accountID] == generation
            && trackedAccounts.contains(where: { $0.id == accountID })
    }

    @discardableResult
    func recordRefreshFailure(
        accountID: UUID,
        operationGeneration: UUID,
        failure: TrackedAccountRefreshFailure,
        disconnect: Bool = false
    ) -> Bool {
        guard let current = consumeOperation(
            accountID: accountID,
            generation: operationGeneration
        ) else { return false }
        var account = current
        let completedAt = currentDate
        account.lastRefreshAttemptAt = account.lastRefreshAttemptAt
            ?? completedAt
        account.lastRefreshCompletedAt = completedAt
        account.lastRefreshFailure = failure
        if disconnect { account.isConnected = false }
        upsertTrackedAccount(account)
        return true
    }

    @discardableResult
    func recordRefreshFailure(
        _ account: TrackedAIAccount,
        operationGeneration: UUID,
        failure: TrackedAccountRefreshFailure,
        disconnect: Bool = false
    ) -> Bool {
        guard let current = consumeOperation(
            accountID: account.id,
            generation: operationGeneration
        ) else { return false }
        var updated = account
        let completedAt = currentDate
        updated.lastRefreshAttemptAt = current.lastRefreshAttemptAt
            ?? completedAt
        updated.lastAttemptKind = current.lastAttemptKind
        updated.lastRefreshCompletedAt = completedAt
        updated.lastRefreshFailure = failure
        if disconnect { updated.isConnected = false }
        upsertTrackedAccount(updated)
        return true
    }

    private func consumeOperation(
        accountID: UUID,
        generation: UUID
    ) -> TrackedAIAccount? {
        guard
            let account = trackedAccounts.first(where: { $0.id == accountID }),
            accountOperationGenerations[accountID] == generation
        else { return nil }
        accountOperationGenerations.removeValue(forKey: accountID)
        return account
    }

    func canAddTrackedAccount(provider: AIProvider) -> Bool {
        let count = trackedAccounts.lazy.filter { $0.provider == provider }.count
        return provider.accountCapabilities.canAddAccount(to: count)
    }

    @discardableResult
    func addTrackedAccount(provider: AIProvider) -> TrackedAIAccount? {
        guard canAddTrackedAccount(provider: provider) else { return nil }
        let existingLabels = Set(
            trackedAccounts
                .filter { $0.provider == provider }
                .map(\.label)
        )
        var accountNumber = 1
        while existingLabels.contains(
            "\(provider.displayName) Account \(accountNumber)"
        ) {
            accountNumber += 1
        }

        let account = TrackedAIAccount(
            id: UUID(),
            provider: provider,
            label: "\(provider.displayName) Account \(accountNumber)",
            email: "",
            planName: "Subscription",
            usagePercent: 0,
            resetsAt: Calendar.current.date(
                byAdding: .month,
                value: 1,
                to: Date()
            ) ?? Date(),
            lastCheckedAt: nil,
            isConnected: false,
            lifetimeTokens: nil
        )
        guard saveTrackedAccount(account) else { return nil }
        return account
    }

    func removeTrackedAccount(id: UUID) {
        accountOperationGenerations.removeValue(forKey: id)
        persistenceEnvelope.trackedAccounts = trackedAccounts.filter {
            $0.id != id
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(persistenceEnvelope) else {
            return
        }
        userDefaults.set(data, forKey: persistenceKey)
    }

    /// Legacy builds could persist multiple active rows for providers whose
    /// credential is shared by the macOS user. No row has enough evidence to
    /// win that conflict after restart, so discard every active marker.
    private func normalizeSharedCredentialConnections() -> Bool {
        guard var accounts = persistenceEnvelope.trackedAccounts else {
            return false
        }
        var changed = false
        for provider in AIProvider.allCases where
            provider.accountCapabilities.credentialScope == .macOSUserShared
        {
            let connectedIndices = accounts.indices.filter {
                accounts[$0].provider == provider
                    && accounts[$0].isConnected == true
            }
            guard connectedIndices.count > 1 else { continue }
            for index in connectedIndices {
                accounts[index].isConnected = false
            }
            changed = true
        }
        guard changed else { return false }
        persistenceEnvelope.trackedAccounts = accounts
        return true
    }

    static let defaultTrackedAccounts: [TrackedAIAccount] = {
        let resetDate = Calendar.current.date(
            byAdding: .month,
            value: 1,
            to: Date()
        ) ?? Date()

        return [
            TrackedAIAccount(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                provider: .codex,
                label: "Codex Account 1",
                email: "",
                planName: "Subscription",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            ),
            TrackedAIAccount(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                provider: .codex,
                label: "Codex Account 2",
                email: "",
                planName: "Subscription",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            ),
            TrackedAIAccount(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                provider: .codex,
                label: "Codex Account 3",
                email: "",
                planName: "Subscription",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            ),
            TrackedAIAccount(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
                provider: .codex,
                label: "Codex Account 4",
                email: "",
                planName: "Subscription",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            ),
            TrackedAIAccount(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                provider: .claude,
                label: "Claude Account",
                email: "",
                planName: "Subscription",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            )
        ]
    }()
}
