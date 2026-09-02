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

    /// The kind of operation currently running for an account, if any. The
    /// store is the single source of truth for "an operation is alive": a
    /// generation exists from `recordRefreshAttempt` until the result or a
    /// cancellation consumes it.
    func inFlightAttemptKind(
        for accountID: UUID
    ) -> TrackedAccountAttemptKind? {
        guard accountOperationGenerations[accountID] != nil else { return nil }
        return trackedAccounts.first(where: { $0.id == accountID })?
            .lastAttemptKind ?? .refresh
    }

    var inFlightAttemptKinds: [UUID: TrackedAccountAttemptKind] {
        var kinds: [UUID: TrackedAccountAttemptKind] = [:]
        for accountID in accountOperationGenerations.keys {
            kinds[accountID] = inFlightAttemptKind(for: accountID)
        }
        return kinds
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
        } else if let data = userDefaults.data(forKey: persistenceKey) {
            if let decoded = try? JSONDecoder().decode(
                LegacyCorporateWorkspaceEnvelope.self,
                from: data
            ) {
                persistenceEnvelope = decoded
            } else {
                // Never silently discard tracked accounts. Keep the bytes a
                // newer build wrote so they can be recovered, then start from
                // defaults.
                userDefaults.set(
                    data,
                    forKey: Self.undecodableBackupKey(for: persistenceKey)
                )
                persistenceEnvelope = .fresh(
                    trackedAccounts: Self.defaultTrackedAccounts
                )
            }
        } else {
            persistenceEnvelope = .fresh(
                trackedAccounts: Self.defaultTrackedAccounts
            )
        }

        if migrateTrackedAccountInventory() {
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
        // An edit saved while a refresh is in flight keeps that operation
        // current: completion re-reads the latest record and merges the
        // provider result onto the edit, so neither is lost.
        upsertTrackedAccount(account)
        return true
    }

    static func undecodableBackupKey(for persistenceKey: String) -> String {
        "\(persistenceKey).undecodable"
    }

    private func upsertTrackedAccount(_ account: TrackedAIAccount) {
        var accounts = trackedAccounts
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        persistenceEnvelope.trackedAccounts = sortedAccounts(accounts)
        persist()
    }

    private func sortedAccounts(
        _ accounts: [TrackedAIAccount]
    ) -> [TrackedAIAccount] {
        accounts.sorted {
            if $0.provider != $1.provider {
                return $0.provider.rawValue > $1.provider.rawValue
            }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
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
        updated.signInRequired = false
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

    /// Records a failed attempt. A failure never disconnects an account; a
    /// provider-reported missing login is remembered in `signInRequired`
    /// until a later success clears it.
    @discardableResult
    func recordRefreshFailure(
        accountID: UUID,
        operationGeneration: UUID,
        failure: TrackedAccountRefreshFailure
    ) -> Bool {
        guard let current = trackedAccounts.first(where: { $0.id == accountID })
        else { return false }
        return recordRefreshFailure(
            current,
            operationGeneration: operationGeneration,
            failure: failure
        )
    }

    @discardableResult
    func recordRefreshFailure(
        _ account: TrackedAIAccount,
        operationGeneration: UUID,
        failure: TrackedAccountRefreshFailure
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
        if failure == .authenticationRequired {
            updated.signInRequired = true
        }
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

    /// Schema 2 collapsed Claude rows into one shared identity. Schema 3
    /// restores the account-specific Claude homes already used by older
    /// builds. Preserve every surviving record and normalize only the label
    /// introduced by the singleton migration.
    ///
    /// Schema 4 stops treating a refresh-time "sign-in required" as a
    /// disconnect. Accounts that earlier builds disconnected that way had
    /// signed in successfully before, and their credentials were usually
    /// still valid; reconnecting them lets the automatic pass verify instead
    /// of leaving the row stuck until a manual browser sign-in.
    private func migrateTrackedAccountInventory() -> Bool {
        let priorVersion = persistenceEnvelope.trackedAccountSchemaVersion ?? 1
        var accounts = persistenceEnvelope.trackedAccounts
            ?? Self.defaultTrackedAccounts
        let originalAccounts = accounts

        if priorVersion == 2 {
            for index in accounts.indices where
                accounts[index].provider == .claude
                    && accounts[index].label == "Claude Code"
            {
                accounts[index].label = "Claude Account 1"
            }
        }

        if priorVersion < 4 {
            for index in accounts.indices where
                accounts[index].lastRefreshFailure == .authenticationRequired
            {
                accounts[index].signInRequired = true
                if accounts[index].isConnected == false
                    && accounts[index].lastAttemptKind == .refresh
                    && accounts[index].lastSuccessfulRefreshAt != nil
                {
                    accounts[index].isConnected = true
                }
            }
        }

        accounts = sortedAccounts(accounts)
        persistenceEnvelope.trackedAccounts = accounts
        persistenceEnvelope.trackedAccountSchemaVersion =
            LegacyCorporateWorkspaceEnvelope.currentTrackedAccountSchemaVersion
        return accounts != originalAccounts
            || priorVersion
                != LegacyCorporateWorkspaceEnvelope
                    .currentTrackedAccountSchemaVersion
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
                label: "Claude Account 1",
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
