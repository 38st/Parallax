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
    private(set) var persistenceErrorMessage: String?
    private var failedUserSaveAccountIDs: Set<UUID> = []

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
        let saved = upsertTrackedAccount(account, userInitiated: true)
        if saved {
            failedUserSaveAccountIDs.remove(account.id)
            if failedUserSaveAccountIDs.isEmpty { persistenceErrorMessage = nil }
        } else {
            failedUserSaveAccountIDs.insert(account.id)
        }
        return saved
    }

    func discardFailedUserSave(accountID: UUID) {
        guard failedUserSaveAccountIDs.remove(accountID) != nil else { return }
        if failedUserSaveAccountIDs.isEmpty { persistenceErrorMessage = nil }
    }

    static func undecodableBackupKey(for persistenceKey: String) -> String {
        "\(persistenceKey).undecodable"
    }

    @discardableResult
    private func upsertTrackedAccount(
        _ account: TrackedAIAccount,
        userInitiated: Bool = false
    ) -> Bool {
        var accounts = trackedAccounts
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        var candidate = persistenceEnvelope
        candidate.trackedAccounts = sortedAccounts(accounts)
        return persist(candidate, userInitiated: userInitiated)
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
        guard let current = currentOperation(
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
        return completeRefresh(updated, previous: current)
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
        guard upsertTrackedAccount(account) else { return nil }
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
        guard let current = currentOperation(
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
        return completeRefresh(updated, previous: current)
    }

    private func currentOperation(
        accountID: UUID,
        generation: UUID
    ) -> TrackedAIAccount? {
        guard
            let account = trackedAccounts.first(where: { $0.id == accountID }),
            accountOperationGenerations[accountID] == generation
        else { return nil }
        return account
    }

    private func completeRefresh(
        _ updated: TrackedAIAccount,
        previous: TrackedAIAccount
    ) -> Bool {
        defer { accountOperationGenerations.removeValue(forKey: updated.id) }
        guard upsertTrackedAccount(updated) else {
            let message = persistenceErrorMessage
            var failed = previous
            failed.lastRefreshCompletedAt = currentDate
            failed.lastRefreshFailure = .persistenceUnavailable
            // The rejected provider payload is not kept. Save completion using
            // the previous valid values; if storage still fails, show the same
            // truthful completion in memory until a later save can persist it.
            if !upsertTrackedAccount(failed) {
                persistenceEnvelope.trackedAccounts = trackedAccounts.map {
                    $0.id == failed.id ? failed : $0
                }
            }
            persistenceErrorMessage = message
            return false
        }
        return true
    }

    func canAddTrackedAccount(provider: AIProvider) -> Bool {
        let count = trackedAccounts.lazy.filter { $0.provider == provider }.count
        return provider.accountCapabilities.canAddAccount(to: count)
    }

    @discardableResult
    func addTrackedAccount(
        provider: AIProvider,
        localizationBundle: Bundle = .main
    ) -> TrackedAIAccount? {
        guard canAddTrackedAccount(provider: provider) else { return nil }
        let existingLabels = Set(
            trackedAccounts
                .filter { $0.provider == provider }
                .map(\.label)
        )
        var accountNumber = 1
        while existingLabels.contains(
            Self.defaultAccountLabel(provider: provider, number: accountNumber, bundle: localizationBundle)
        ) {
            accountNumber += 1
        }

        let account = TrackedAIAccount(
            id: UUID(),
            provider: provider,
            label: Self.defaultAccountLabel(provider: provider, number: accountNumber, bundle: localizationBundle),
            email: "",
            planName: "",
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
        var candidate = persistenceEnvelope
        candidate.trackedAccounts = trackedAccounts.filter { $0.id != id }
        if persist(candidate, userInitiated: true) {
            failedUserSaveAccountIDs.remove(id)
            if failedUserSaveAccountIDs.isEmpty { persistenceErrorMessage = nil }
        } else {
            failedUserSaveAccountIDs.insert(id)
        }
    }

    private static func defaultAccountLabel(
        provider: AIProvider,
        number accountNumber: Int,
        bundle: Bundle = .main
    ) -> String {
        switch provider {
        case .codex: String(localized: "Codex Account \(accountNumber)", bundle: bundle)
        case .claude: String(localized: "Claude Account \(accountNumber)", bundle: bundle)
        }
    }

    @discardableResult
    private func persist(
        _ envelope: LegacyCorporateWorkspaceEnvelope? = nil,
        userInitiated: Bool = false
    ) -> Bool {
        var candidate = envelope ?? persistenceEnvelope
        let isNewerSchema = (candidate.trackedAccountSchemaVersion ?? 1)
            > LegacyCorporateWorkspaceEnvelope.currentTrackedAccountSchemaVersion
        if isNewerSchema, !userInitiated {
            // Passive checks may update this build's view, but cannot discard
            // fields owned by a newer build in the stored envelope.
            persistenceEnvelope = candidate
            return true
        }
        if isNewerSchema {
            candidate.trackedAccountSchemaVersion =
                LegacyCorporateWorkspaceEnvelope.currentTrackedAccountSchemaVersion
        }
        do {
            let data = try JSONEncoder().encode(candidate)
            if isNewerSchema, let original = userDefaults.data(forKey: persistenceKey) {
                userDefaults.set(original, forKey: "\(persistenceKey).newer-schema")
            }
            userDefaults.set(data, forKey: persistenceKey)
            persistenceEnvelope = candidate
            if failedUserSaveAccountIDs.isEmpty { persistenceErrorMessage = nil }
            return true
        } catch {
            persistenceErrorMessage = String(
                localized: "Account changes could not be saved. The previous saved data is unchanged."
            )
            ProviderDiagnostics.log(provider: "accounts", event: "account persistence failed", detail: error.localizedDescription)
            return false
        }
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
        guard priorVersion <= LegacyCorporateWorkspaceEnvelope.currentTrackedAccountSchemaVersion else {
            return false
        }
        var accounts = persistenceEnvelope.trackedAccounts
            ?? Self.defaultTrackedAccounts
        let originalAccounts = accounts

        if priorVersion == 2 {
            for index in accounts.indices where
                accounts[index].provider == .claude
                    && accounts[index].label == "Claude Code"
            {
                accounts[index].label = Self.defaultAccountLabel(provider: .claude, number: 1)
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
                label: defaultAccountLabel(provider: .codex, number: 1),
                email: "",
                planName: "",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            ),
            TrackedAIAccount(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                provider: .codex,
                label: defaultAccountLabel(provider: .codex, number: 2),
                email: "",
                planName: "",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            ),
            TrackedAIAccount(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                provider: .codex,
                label: defaultAccountLabel(provider: .codex, number: 3),
                email: "",
                planName: "",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            ),
            TrackedAIAccount(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000004")!,
                provider: .codex,
                label: defaultAccountLabel(provider: .codex, number: 4),
                email: "",
                planName: "",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            ),
            TrackedAIAccount(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!,
                provider: .claude,
                label: defaultAccountLabel(provider: .claude, number: 1),
                email: "",
                planName: "",
                usagePercent: 0,
                resetsAt: resetDate,
                lastCheckedAt: nil,
                isConnected: false,
                lifetimeTokens: nil
            )
        ]
    }()
}
