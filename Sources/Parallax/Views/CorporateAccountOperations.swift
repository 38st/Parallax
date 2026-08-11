import Foundation

extension CorporateAccountTrackerContent {

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

    func setActivity(
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

    @MainActor
    func connect(_ account: TrackedAIAccount) async {
        guard let generation = store.recordRefreshAttempt(
            accountID: account.id,
            kind: .signIn
        ) else { return }
        setActivity(.signingIn, accountID: account.id, generation: generation)
        do {
            let status = try await AIAccountConnectionService.login(
                provider: account.provider,
                accountID: account.id
            )
            _ = apply(status, to: account, generation: generation)
            finishActivity(accountID: account.id, generation: generation)
        } catch {
            let applied = store.recordRefreshFailure(
                accountID: account.id,
                operationGeneration: generation,
                failure: refreshFailure(for: error, attemptKind: .signIn)
            )
            if applied {
                finishActivity(
                    accountID: account.id,
                    generation: generation,
                    failureMessage: error.localizedDescription
                )
            } else {
                finishActivity(accountID: account.id, generation: generation)
            }
        }
    }

    @MainActor
    func refresh(_ account: TrackedAIAccount) async {
        guard let generation = store.recordRefreshAttempt(
            accountID: account.id,
            kind: .refresh
        ) else { return }
        setActivity(.refreshing, accountID: account.id, generation: generation)
        do {
            let status = try await AIAccountConnectionService.refresh(
                provider: account.provider,
                accountID: account.id
            )
            _ = apply(status, to: account, generation: generation)
            finishActivity(accountID: account.id, generation: generation)
        } catch AIAccountConnectionError.notAuthenticated {
            let applied = store.recordRefreshFailure(
                accountID: account.id,
                operationGeneration: generation,
                failure: .authenticationRequired,
                disconnect: true
            )
            _ = applied
            finishActivity(accountID: account.id, generation: generation)
        } catch {
            let applied = store.recordRefreshFailure(
                accountID: account.id,
                operationGeneration: generation,
                failure: refreshFailure(for: error, attemptKind: .refresh)
            )
            if applied {
                finishActivity(
                    accountID: account.id,
                    generation: generation,
                    failureMessage: error.localizedDescription
                )
            } else {
                finishActivity(accountID: account.id, generation: generation)
            }
        }
    }

    @MainActor
    func refreshConnectedAccounts() async {
        for account in store.trackedAccounts
        where account.isConnected == true || account.provider == .claude
        {
            await refresh(account)
        }
    }

    @MainActor
    func apply(
        _ status: ConnectedAIAccountStatus,
        to account: TrackedAIAccount,
        generation: UUID
    ) -> Bool {
        guard let current = store.trackedAccounts.first(where: {
            $0.id == account.id
        }) else { return false }
        let application = CorporateAccountRefreshApplication(
            status: status,
            account: current
        )
        if let failure = application.failure {
            return store.recordRefreshFailure(
                application.account,
                operationGeneration: generation,
                failure: failure
            )
        } else {
            return store.recordRefreshSuccess(
                application.account,
                operationGeneration: generation
            )
        }
    }

    func refreshFailure(
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
            Task { await connect(account) }
        case nil:
            break
        }
    }

    @MainActor
    func addAndConnect(_ provider: AIProvider) {
        let account = store.addTrackedAccount(provider: provider)
        Task { await connect(account) }
    }
}
