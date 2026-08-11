import Foundation
import Observation

enum CorporateAccountMutationScope: Hashable, Sendable {
    case codex(UUID)
    case claudeAmbient

    init(account: TrackedAIAccount) {
        switch account.provider {
        case .codex:
            self = .codex(account.id)
        case .claude:
            self = .claudeAmbient
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

    init(
        store: CorporateUsageStore,
        service: any CorporateAccountOperationServicing =
            LiveCorporateAccountOperationService()
    ) {
        self.store = store
        self.service = service
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

    func refreshConnectedAccounts() async {
        let accounts = store.trackedAccounts.filter {
            $0.isConnected == true || $0.provider == .claude
        }
        for account in accounts {
            guard !Task.isCancelled else { return }
            guard let token = startRefresh(account) else { continue }
            await waitForCompletion(token)
        }
    }

    func removeTrackedAccount(_ account: TrackedAIAccount) {
        cancelOperations(accountID: account.id)
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

    func cancelAll() {
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
            _ = store.recordRefreshFailure(
                application.account,
                operationGeneration: generation,
                failure: failure
            )
        } else {
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
        if attemptKind == .refresh,
           case .notAuthenticated? = error as? AIAccountConnectionError
        {
            _ = store.recordRefreshFailure(
                accountID: accountID,
                operationGeneration: generation,
                failure: .authenticationRequired,
                disconnect: true
            )
            finishActivity(accountID: accountID, generation: generation)
            return
        }

        let applied = store.recordRefreshFailure(
            accountID: accountID,
            operationGeneration: generation,
            failure: refreshFailure(
                for: error,
                attemptKind: attemptKind
            )
        )
        if applied {
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

extension CorporateAccountTrackerContent {
    func activity(
        for account: TrackedAIAccount
    ) -> AccountConnectionActivity {
        operationCoordinator.activity(for: account)
    }

    func accounts(for provider: AIProvider) -> [TrackedAIAccount] {
        store.trackedAccounts.filter { $0.provider == provider }
    }

    func providerCount(_ provider: AIProvider) -> Int {
        accounts(for: provider).count
    }

    var currentNearLimitCount: Int {
        CorporateAccountUsageAggregation(
            accounts: store.trackedAccounts,
            now: store.currentDate
        )
            .nearLimitAccounts.count
    }

    var claudeSignInWarning: CorporateSharedIdentityWarning {
        CorporateAccountIsolationPresentation(provider: .claude)
            .sharedIdentityWarning!
    }

    @MainActor
    func requestAddAndConnect(_ provider: AIProvider) {
        if provider == .claude {
            pendingClaudeSignIn = .newAccount
        } else {
            addAndConnect(provider)
        }
    }

    @MainActor
    func continueClaudeSignIn() {
        let target = pendingClaudeSignIn
        pendingClaudeSignIn = nil
        switch target {
        case .newAccount:
            addAndConnect(.claude)
        case let .existing(account):
            operationCoordinator.startConnect(account)
        case nil:
            break
        }
    }

    @MainActor
    func addAndConnect(_ provider: AIProvider) {
        if provider == .claude,
           operationCoordinator.isRunning(scope: .claudeAmbient)
        {
            return
        }
        let account = store.addTrackedAccount(provider: provider)
        operationCoordinator.startConnect(account)
    }
}
