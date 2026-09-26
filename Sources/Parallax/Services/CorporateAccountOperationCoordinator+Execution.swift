import AppKit
import Foundation
import Observation

extension CorporateAccountOperationCoordinator {
    func waitForCompletion(
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

    func cancel(scope: CorporateAccountMutationScope) {
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

    func complete(
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
        let applied: Bool
        if let failure = application.failure {
            consecutiveFailures[accountID, default: 0] += 1
            applied = store.recordRefreshFailure(
                application.account,
                operationGeneration: generation,
                failure: failure
            )
        } else {
            consecutiveFailures.removeValue(forKey: accountID)
            applied = store.recordRefreshSuccess(
                application.account,
                operationGeneration: generation
            )
        }
        finishActivity(accountID: accountID, generation: generation)
        if applied {
            accountStateDidChange?()
        }
    }

    func consume(
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
}
