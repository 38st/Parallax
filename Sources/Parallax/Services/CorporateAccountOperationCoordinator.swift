import AppKit
import Foundation
import Observation

/// Holds notification registrations and releases them when the owner goes
/// away, without requiring an isolated deinit on the owner.
private final class LifecycleObserverBag: @unchecked Sendable {
    private var tokens: [(NotificationCenter, NSObjectProtocol)] = []
    private let lock = NSLock()

    func add(_ token: NSObjectProtocol, center: NotificationCenter) {
        lock.withLock { tokens.append((center, token)) }
    }

    deinit {
        lock.withLock {
            for (center, token) in tokens {
                center.removeObserver(token)
            }
            tokens.removeAll()
        }
    }
}

@MainActor
@Observable
final class CorporateAccountOperationCoordinator {
    struct RunningOperation {
        let token: CorporateAccountOperationToken
        let accountID: UUID
        let generation: UUID
        let provider: AIProvider
        let attemptKind: TrackedAccountAttemptKind
        let task: Task<Void, Never>
    }

    private struct PendingOperation {
        let token: CorporateAccountOperationToken
        let account: TrackedAIAccount
        let attemptKind: TrackedAccountAttemptKind
    }

    var admissionMessage: String?

    private(set) var connectionActivity:
        [UUID: AccountConnectionOperation] = [:]

    @ObservationIgnored
    let store: CorporateUsageStore
    @ObservationIgnored
    private let service: any CorporateAccountOperationServicing
    var runningOperations:
        [CorporateAccountMutationScope: RunningOperation] = [:]
    @ObservationIgnored
    var cancellingOperations:
        Set<CorporateAccountOperationToken> = []
    private var pendingOperations:
        [CorporateAccountMutationScope: PendingOperation] = [:]
    @ObservationIgnored
    private var sweepTask: Task<Void, Never>?
    @ObservationIgnored
    private var automaticRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private let lifecycleObservers = LifecycleObserverBag()
    @ObservationIgnored
    private var isObservingLifecycleEvents = false
    /// Consecutive failed attempts per account since the last success, in
    /// memory only: a restart starts the backoff over.
    @ObservationIgnored
    var consecutiveFailures: [UUID: Int] = [:]
    @ObservationIgnored
    var accountStateDidChange: (() -> Void)?

    /// Connected accounts are checked about every five minutes, independently
    /// of the longer interval for displaying still-current provider values.
    static let automaticRefreshInterval: TimeInterval = 5 * 60
    /// Minimum spacing between automatic attempts on one healthy account, so
    /// overlapping wake and presentation passes do not double-probe. A small
    /// tolerance accommodates wall-clock slew between continuous-clock ticks.
    static let minimumAutomaticRetryInterval = automaticRefreshInterval - 2
    /// Failing accounts back off geometrically from one pass interval up to
    /// this ceiling, so a logged-out or broken provider is not probed every
    /// five minutes forever.
    static let maximumAutomaticRetryInterval: TimeInterval = 60 * 60

    init(
        store: CorporateUsageStore,
        service: any CorporateAccountOperationServicing =
            LiveCorporateAccountOperationService()
    ) {
        self.store = store
        self.service = service
    }

    /// Starts the periodic pass, a delayed pass after wake from sleep, and
    /// cancellation of in-flight provider tools when the app terminates.
    func startAutomaticRefresh(
        interval: TimeInterval = automaticRefreshInterval,
        initialDelay: TimeInterval = 5
    ) {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(initialDelay))
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshDueAccounts()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        observeLifecycleEvents()
    }

    func stopAutomaticRefresh() {
        automaticRefreshTask?.cancel()
        automaticRefreshTask = nil
    }

    private func observeLifecycleEvents() {
        guard !isObservingLifecycleEvents else { return }
        isObservingLifecycleEvents = true
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        let wakeToken = workspaceCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                // Network interfaces need a moment after wake; probing at
                // once would only record a failure.
                try? await Task.sleep(for: .seconds(10))
                await self?.refreshDueAccounts()
            }
        }
        lifecycleObservers.add(wakeToken, center: workspaceCenter)

        let terminationToken = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.prepareForTermination()
            }
        }
        lifecycleObservers.add(terminationToken, center: .default)
    }

    func prepareForTermination() {
        stopAutomaticRefresh()
        cancelAll()
        service.terminateProviderProcesses()
    }

    /// Refreshes every connected account whose automatic check is due,
    /// including accounts whose last refresh reported sign-in required: the
    /// probe is local, opens no browser, and self-heals the row once the
    /// provider answers normally again.
    func refreshDueAccounts() async {
        let now = store.currentDate
        let due = store.trackedAccounts.filter { isDue($0, now: now) }
        await refresh(due)
    }

    func isDue(_ account: TrackedAIAccount, now: Date) -> Bool {
        guard account.isConnected == true else { return false }
        if let attempt = account.lastRefreshAttemptAt,
            attempt <= now,
            now.timeIntervalSince(attempt)
                < automaticRetryInterval(for: account)
        {
            return false
        }
        if let success = account.lastSuccessfulRefreshAt,
            success <= now,
            now.timeIntervalSince(success) < automaticRetryInterval(for: account)
        {
            return false
        }
        return true
    }

    /// Spacing before an account is automatically probed again. Healthy
    /// accounts use the minimum; each consecutive failure doubles the wait,
    /// starting at one pass interval.
    func automaticRetryInterval(for account: TrackedAIAccount) -> TimeInterval {
        let failures = consecutiveFailures[account.id, default: 0]
        guard failures > 0 else { return Self.minimumAutomaticRetryInterval }
        let scaled = Self.automaticRefreshInterval
            * pow(2, Double(min(failures, 10) - 1))
        return min(scaled, Self.maximumAutomaticRetryInterval)
    }

    var runningOperationCount: Int {
        runningOperations.count
    }

    func isRunning(scope: CorporateAccountMutationScope) -> Bool {
        runningOperations[scope] != nil
    }

    func activity(
        for account: TrackedAIAccount
    ) -> AccountConnectionActivity {
        guard let operation = connectionActivity[account.id] else {
            return .idle
        }
        return operation.visibleActivity(
            isGenerationCurrent: store.isCurrentOperation(
                accountID: account.id,
                generation: operation.generation
            )
        )
    }

    func addAndConnect(_ provider: AIProvider) {
        if provider == .codex, hasCodexSignIn {
            admissionMessage = String(localized: "Finish the current Codex sign-in before adding another account.")
            return
        }
        admissionMessage = nil
        guard let account = store.addTrackedAccount(provider: provider) else { return }
        startConnect(account)
    }

    @discardableResult
    func startConnect(
        _ account: TrackedAIAccount
    ) -> CorporateAccountOperationToken? {
        start(account, attemptKind: .signIn)
    }

    @discardableResult
    func startRefresh(
        _ account: TrackedAIAccount
    ) -> CorporateAccountOperationToken? {
        start(account, attemptKind: .refresh)
    }

    /// Runs one sequential pass. A pass requested while another is in
    /// progress waits for it rather than starting a second, overlapping one,
    /// so the intended one-account-at-a-time pacing holds; whatever the
    /// finished pass did not cover and is still due then runs.
    private func refresh(_ accounts: [TrackedAIAccount]) async {
        var accounts = accounts
        while let running = sweepTask {
            await running.value
            // The pass owner clears the handle after its own await resumes;
            // a waiter that resumes first must not spin on the finished task.
            if sweepTask == running { sweepTask = nil }
            let now = store.currentDate
            accounts = accounts.compactMap { requested in
                store.trackedAccounts.first { $0.id == requested.id }
            }
            .filter { isDue($0, now: now) }
            if accounts.isEmpty { return }
        }
        let pass = Task { @MainActor [weak self] in
            for account in accounts {
                guard let self, !Task.isCancelled else { return }
                guard
                    let current = self.store.trackedAccounts.first(where: {
                        $0.id == account.id && $0.isConnected == true
                    }),
                    self.isDue(current, now: self.store.currentDate),
                    let token = self.startRefresh(current)
                else {
                    continue
                }
                await self.waitForCompletion(token)
            }
        }
        sweepTask = pass
        await pass.value
        if sweepTask == pass { sweepTask = nil }
    }

    func removeTrackedAccount(_ account: TrackedAIAccount) {
        cancelOperations(accountID: account.id)
        consecutiveFailures.removeValue(forKey: account.id)
        store.removeTrackedAccount(id: account.id)
    }

    func cancelOperations(accountID: UUID) {
        pendingOperations = pendingOperations.filter {
            $0.value.account.id != accountID
        }
        let scopes = runningOperations.compactMap { scope, operation in
            operation.accountID == accountID ? scope : nil
        }
        for scope in scopes {
            cancel(scope: scope)
        }
    }

    /// Stops the current pass and every running operation. The pass is
    /// cancelled first so it cannot start the next account after the
    /// running one is interrupted.
    func cancelAll() {
        sweepTask?.cancel()
        sweepTask = nil
        pendingOperations = [:]
        for scope in Array(runningOperations.keys) {
            cancel(scope: scope)
        }
    }

    func isMutationScopeBusy(for account: TrackedAIAccount) -> Bool {
        let scope = CorporateAccountMutationScope(account: account)
        return runningOperations[scope] != nil
            || pendingOperations[scope] != nil
            || (account.provider == .codex && !account.isSignedIn
                && hasCodexSignIn)
    }

    private var hasCodexSignIn: Bool {
        runningOperations.values.contains {
            $0.provider == .codex && $0.attemptKind == .signIn
        } || pendingOperations.values.contains {
            $0.account.provider == .codex && $0.attemptKind == .signIn
        }
    }

    private func start(
        _ account: TrackedAIAccount,
        attemptKind: TrackedAccountAttemptKind
    ) -> CorporateAccountOperationToken? {
        let scope = CorporateAccountMutationScope(account: account)
        // The provider's browser callback port is shared by Codex logins.
        // Keep refreshes account-scoped, but admit only one browser sign-in.
        if attemptKind == .signIn, account.provider == .codex,
            hasCodexSignIn,
            runningOperations[scope]?.attemptKind != .signIn
        {
            return nil
        }
        if let running = runningOperations[scope] {
            guard
                !store.isCurrentOperation(
                    accountID: running.accountID,
                    generation: running.generation
                )
            else {
                return nil
            }
            guard pendingOperations[scope] == nil else { return nil }
            let token = CorporateAccountOperationToken(
                scope: scope,
                operationID: UUID()
            )
            pendingOperations[scope] = PendingOperation(
                token: token,
                account: account,
                attemptKind: attemptKind
            )
            cancel(scope: scope)
            return token
        }
        return launch(
            account,
            attemptKind: attemptKind,
            token: CorporateAccountOperationToken(
                scope: scope,
                operationID: UUID()
            )
        )
    }

    private func launch(
        _ account: TrackedAIAccount,
        attemptKind: TrackedAccountAttemptKind,
        token: CorporateAccountOperationToken
    ) -> CorporateAccountOperationToken? {
        guard
            store.trackedAccounts.contains(where: {
                $0.id == account.id && $0.provider == account.provider
            }),
            let generation = store.recordRefreshAttempt(
                accountID: account.id,
                kind: attemptKind
            )
        else {
            return nil
        }

        setActivity(
            attemptKind == .signIn ? .signingIn : .refreshing,
            accountID: account.id,
            generation: generation
        )
        let provider = account.provider
        let accountID = account.id
        let service = service
        let task = Task { @MainActor [weak self] in
            do {
                let status: ConnectedAIAccountStatus
                switch attemptKind {
                case .signIn:
                    status = try await service.login(
                        provider: provider,
                        accountID: accountID
                    )
                case .refresh:
                    status = try await service.refresh(
                        provider: provider,
                        accountID: accountID
                    )
                }
                try Task.checkCancellation()
                self?.complete(
                    token: token,
                    accountID: accountID,
                    generation: generation,
                    status: status
                )
            } catch {
                self?.complete(
                    token: token,
                    accountID: accountID,
                    generation: generation,
                    attemptKind: attemptKind,
                    error: Task.isCancelled ? CancellationError() : error
                )
            }
        }
        runningOperations[token.scope] = RunningOperation(
            token: token,
            accountID: account.id,
            generation: generation,
            provider: provider,
            attemptKind: attemptKind,
            task: task
        )
        return token
    }

    private func complete(
        token: CorporateAccountOperationToken,
        accountID: UUID,
        generation: UUID,
        attemptKind: TrackedAccountAttemptKind,
        error: Error
    ) {
        guard consume(token: token) != nil else { return }
        defer { startPendingOperation(scope: token.scope) }
        // A failure never disconnects an account. A provider-reported
        // missing login is remembered by the store as sign-in required; the
        // row stays in the automatic pass, the card offers "Sign in", and a
        // later success clears it. Only the user removes an account.
        let failure = refreshFailure(for: error, attemptKind: attemptKind)
        let applied = store.recordRefreshFailure(
            accountID: accountID,
            operationGeneration: generation,
            failure: failure
        )
        if applied, failure != .interrupted {
            consecutiveFailures[accountID, default: 0] += 1
        }
        // The card already explains sign-in required; the red line is for
        // failures the fixed copy does not cover.
        if applied, failure != .authenticationRequired {
            finishActivity(
                accountID: accountID,
                generation: generation,
                failureMessage: error.localizedDescription
            )
        } else {
            finishActivity(
                accountID: accountID,
                generation: generation
            )
        }
    }

    func startPendingOperation(
        scope: CorporateAccountMutationScope
    ) {
        guard let pending = pendingOperations.removeValue(forKey: scope)
        else {
            return
        }
        _ = launch(
            pending.account,
            attemptKind: pending.attemptKind,
            token: pending.token
        )
    }

    private func setActivity(
        _ activity: AccountConnectionActivity,
        accountID: UUID,
        generation: UUID
    ) {
        connectionActivity[accountID] = AccountConnectionOperation(
            generation: generation,
            activity: activity
        )
    }

    func finishActivity(
        accountID: UUID,
        generation: UUID,
        failureMessage: String? = nil
    ) {
        guard
            connectionActivity[accountID]?.belongs(to: generation) == true
        else {
            return
        }
        if let failureMessage {
            setActivity(
                .failed(failureMessage),
                accountID: accountID,
                generation: generation
            )
        } else {
            connectionActivity.removeValue(forKey: accountID)
        }
    }
}
