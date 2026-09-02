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
        for (center, token) in tokens {
            center.removeObserver(token)
        }
    }
}

enum CorporateAccountMutationScope: Hashable, Sendable {
    case account(provider: AIProvider, accountID: UUID)
    case provider(AIProvider)

    init(account: TrackedAIAccount) {
        switch account.provider.accountCapabilities.operationScope {
        case .account:
            self = .account(
                provider: account.provider,
                accountID: account.id
            )
        case .provider:
            self = .provider(account.provider)
        }
    }
}

protocol CorporateAccountOperationServicing: Sendable {
    func login(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus

    func refresh(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus
}

struct LiveCorporateAccountOperationService:
    CorporateAccountOperationServicing
{
    func login(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await AIAccountConnectionService.login(
            provider: provider,
            accountID: accountID
        )
    }

    func refresh(
        provider: AIProvider,
        accountID: UUID
    ) async throws -> ConnectedAIAccountStatus {
        try await AIAccountConnectionService.refresh(
            provider: provider,
            accountID: accountID
        )
    }
}

struct CorporateAccountOperationToken: Hashable, Sendable {
    let scope: CorporateAccountMutationScope
    let operationID: UUID
}

@MainActor
@Observable
final class CorporateAccountOperationCoordinator {
    private struct RunningOperation {
        let token: CorporateAccountOperationToken
        let accountID: UUID
        let generation: UUID
        let task: Task<Void, Never>
    }

    private struct PendingOperation {
        let token: CorporateAccountOperationToken
        let account: TrackedAIAccount
        let attemptKind: TrackedAccountAttemptKind
    }

    private(set) var connectionActivity:
        [UUID: AccountConnectionOperation] = [:]

    @ObservationIgnored
    private let store: CorporateUsageStore
    @ObservationIgnored
    private let service: any CorporateAccountOperationServicing
    @ObservationIgnored
    private var runningOperations:
        [CorporateAccountMutationScope: RunningOperation] = [:]
    @ObservationIgnored
    private var cancellingOperations:
        Set<CorporateAccountOperationToken> = []
    @ObservationIgnored
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
    private var consecutiveFailures: [UUID: Int] = [:]

    /// Provider values stay current for 15 minutes; a pass every five keeps a
    /// connected account from sitting stale for long without spawning tools
    /// on every view presentation.
    static let automaticRefreshInterval: TimeInterval = 5 * 60
    /// Minimum spacing between automatic attempts on one healthy account, so
    /// overlapping wake and presentation passes do not double-probe.
    static let minimumAutomaticRetryInterval: TimeInterval = 60
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
                self?.stopAutomaticRefresh()
                self?.cancelAll()
            }
        }
        lifecycleObservers.add(terminationToken, center: .default)
    }

    /// Refreshes every connected account whose data is no longer current,
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
        return !CorporateAccountFreshnessPolicy.state(
            for: account,
            now: now
        ).isCurrent
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
    }

    private func start(
        _ account: TrackedAIAccount,
        attemptKind: TrackedAccountAttemptKind
    ) -> CorporateAccountOperationToken? {
        let scope = CorporateAccountMutationScope(account: account)
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
                    error: error
                )
            }
        }
        runningOperations[token.scope] = RunningOperation(
            token: token,
            accountID: account.id,
            generation: generation,
            task: task
        )
        return token
    }

    private func waitForCompletion(
        _ token: CorporateAccountOperationToken
    ) async {
        guard
            let operation = runningOperations[token.scope],
            operation.token == token
        else {
            return
        }
        await operation.task.value
    }

    private func cancel(scope: CorporateAccountMutationScope) {
        guard
            let operation = runningOperations[scope],
            cancellingOperations.insert(operation.token).inserted
        else {
            return
        }
        operation.task.cancel()
        _ = store.recordRefreshFailure(
            accountID: operation.accountID,
            operationGeneration: operation.generation,
            failure: .interrupted
        )
        finishActivity(
            accountID: operation.accountID,
            generation: operation.generation
        )
    }

    private func complete(
        token: CorporateAccountOperationToken,
        accountID: UUID,
        generation: UUID,
        status: ConnectedAIAccountStatus
    ) {
        guard consume(token: token) != nil else { return }
        defer { startPendingOperation(scope: token.scope) }
        guard
            let current = store.trackedAccounts.first(where: {
                $0.id == accountID
            })
        else {
            finishActivity(accountID: accountID, generation: generation)
            return
        }
        let application = CorporateAccountRefreshApplication(
            status: status,
            account: current
        )
        if let failure = application.failure {
            consecutiveFailures[accountID, default: 0] += 1
            _ = store.recordRefreshFailure(
                application.account,
                operationGeneration: generation,
                failure: failure
            )
        } else {
            consecutiveFailures.removeValue(forKey: accountID)
            _ = store.recordRefreshSuccess(
                application.account,
                operationGeneration: generation
            )
        }
        finishActivity(accountID: accountID, generation: generation)
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
        if failure != .interrupted {
            consecutiveFailures[accountID, default: 0] += 1
        }
        let applied = store.recordRefreshFailure(
            accountID: accountID,
            operationGeneration: generation,
            failure: failure
        )
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

    private func consume(
        token: CorporateAccountOperationToken
    ) -> RunningOperation? {
        guard
            let operation = runningOperations[token.scope],
            operation.token == token
        else {
            return nil
        }
        runningOperations.removeValue(forKey: token.scope)
        cancellingOperations.remove(token)
        return operation
    }

    private func startPendingOperation(
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

    private func finishActivity(
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

    private func refreshFailure(
        for error: Error,
        attemptKind: TrackedAccountAttemptKind
    ) -> TrackedAccountRefreshFailure {
        if error is CancellationError { return .interrupted }
        switch error as? AIAccountConnectionError {
        case .notAuthenticated:
            return .authenticationRequired
        case .executableMissing:
            return .providerToolUnavailable
        case .loginFailed:
            return .signInFailed
        case .statusUnavailable, nil:
            return attemptKind == .signIn
                ? .signInFailed
                : .statusUnavailable
        }
    }
}
