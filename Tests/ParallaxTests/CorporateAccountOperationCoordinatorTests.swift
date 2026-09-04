import Foundation
import XCTest
@testable import Parallax

@MainActor
final class CorporateAccountOperationCoordinatorTests: XCTestCase {
    func testAppliedAccountStatusNotifiesStateObserver() async throws {
        let account = makeAccount(provider: .codex, isConnected: false)
        let store = makeStore(accounts: [account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let call = serviceCall(account: account, kind: .login)
        var notificationCount = 0
        coordinator.accountStateDidChange = {
            notificationCount += 1
        }

        XCTAssertNotNil(coordinator.startConnect(account))
        await waitUntil { service.callCount(call) == 1 }
        service.completeOldest(call, with: status(usagePercent: 9))
        await waitUntil { coordinator.runningOperationCount == 0 }

        XCTAssertEqual(notificationCount, 1)
        XCTAssertTrue(
            try XCTUnwrap(
                store.trackedAccounts.first(where: {
                    $0.id == account.id
                })
            ).isSignedIn
        )
    }

    func testRemoveDuringLoginCancelsOwnedTaskAndCannotRestoreAccount()
        async throws
    {
        let account = makeAccount(provider: .codex, isConnected: false)
        let store = makeStore(accounts: [account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let call = serviceCall(account: account, kind: .login)

        XCTAssertNotNil(coordinator.startConnect(account))
        await waitUntil { service.callCount(call) == 1 }

        coordinator.removeTrackedAccount(account)

        await waitUntil { service.cancellationCount(call) == 1 }
        XCTAssertTrue(store.trackedAccounts.isEmpty)
        service.completeOldest(call, with: status(usagePercent: 91))
        await drainTasks()

        XCTAssertTrue(store.trackedAccounts.isEmpty)
        XCTAssertEqual(coordinator.runningOperationCount, 0)
    }

    func testViewTeardownCancellationInterruptsEveryOwnedTask()
        async throws
    {
        let account = makeAccount(provider: .codex, isConnected: true)
        let store = makeStore(accounts: [account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let call = serviceCall(account: account, kind: .refresh)

        XCTAssertNotNil(coordinator.startRefresh(account))
        await waitUntil { service.callCount(call) == 1 }

        coordinator.cancelAll()

        await waitUntil { service.cancellationCount(call) == 1 }
        let interrupted = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.id == account.id })
        )
        XCTAssertEqual(interrupted.lastRefreshFailure, .interrupted)
        XCTAssertEqual(coordinator.runningOperationCount, 1)

        service.completeOldest(call, with: status(usagePercent: 88))
        await waitUntil { coordinator.runningOperationCount == 0 }
        XCTAssertEqual(
            store.trackedAccounts.first(where: { $0.id == account.id })?
                .usagePercent,
            account.usagePercent
        )
    }

    func testClaudeRowsUseIndependentAccountMutationScopes()
        async throws
    {
        let first = makeAccount(provider: .claude, isConnected: false)
        let second = makeAccount(provider: .claude, isConnected: false)
        let store = makeStore(accounts: [first, second])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let firstCall = serviceCall(account: first, kind: .login)
        let secondCall = serviceCall(account: second, kind: .login)

        XCTAssertNotNil(coordinator.startConnect(first))
        XCTAssertNotNil(coordinator.startConnect(second))
        await waitUntil {
            service.callCount(firstCall) == 1
                && service.callCount(secondCall) == 1
        }

        XCTAssertTrue(
            coordinator.isRunning(
                scope: .account(provider: .claude, accountID: first.id)
            )
        )
        XCTAssertTrue(
            coordinator.isRunning(
                scope: .account(provider: .claude, accountID: second.id)
            )
        )
        service.completeOldest(firstCall, with: claudeStatus())
        service.completeOldest(secondCall, with: claudeStatus())
        await waitUntil { coordinator.runningOperationCount == 0 }

        XCTAssertFalse(coordinator.isMutationScopeBusy(for: first))
        XCTAssertFalse(coordinator.isMutationScopeBusy(for: second))
        XCTAssertTrue(
            store.trackedAccounts.allSatisfy { $0.isConnected == true }
        )
    }

    func testCodexRowsKeepIndependentAccountMutationScopes() async throws {
        let first = makeAccount(provider: .codex, isConnected: false)
        let second = makeAccount(provider: .codex, isConnected: false)
        let store = makeStore(accounts: [first, second])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let firstCall = serviceCall(account: first, kind: .login)
        let secondCall = serviceCall(account: second, kind: .login)

        XCTAssertNotNil(coordinator.startConnect(first))
        XCTAssertNotNil(coordinator.startConnect(second))
        await waitUntil {
            service.callCount(firstCall) == 1
                && service.callCount(secondCall) == 1
        }

        XCTAssertTrue(
            coordinator.isRunning(
                scope: .account(provider: .codex, accountID: first.id)
            )
        )
        XCTAssertTrue(
            coordinator.isRunning(
                scope: .account(provider: .codex, accountID: second.id)
            )
        )
        service.completeOldest(firstCall, with: status(usagePercent: 10))
        service.completeOldest(secondCall, with: status(usagePercent: 20))
        await waitUntil { coordinator.runningOperationCount == 0 }
    }

    func testPresentationRefreshSkipsDisconnectedClaudeAccountHome()
        async throws
    {
        let account = makeAccount(provider: .claude, isConnected: false)
        let store = makeStore(accounts: [account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        await coordinator.refreshDueAccounts()
        XCTAssertEqual(
            service.callCount(serviceCall(account: account, kind: .refresh)),
            0
        )
    }

    func testConnectedOnlyRefreshSkipsDisconnectedClaudeAccount()
        async throws
    {
        let account = makeAccount(provider: .claude, isConnected: false)
        let store = makeStore(accounts: [account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        await coordinator.refreshDueAccounts()

        XCTAssertEqual(
            service.callCount(serviceCall(account: account, kind: .refresh)),
            0
        )
        XCTAssertEqual(store.trackedAccounts.count, 1)
        XCTAssertEqual(store.trackedAccounts.first?.isConnected, false)
    }

    func testClaudeLoginFailureDoesNotDisconnectAnotherAccount()
        async throws
    {
        let previous = makeAccount(provider: .claude, isConnected: true)
        let account = makeAccount(provider: .claude, isConnected: false)
        let store = makeStore(accounts: [previous, account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let login = serviceCall(account: account, kind: .login)

        XCTAssertNotNil(coordinator.startConnect(account))
        XCTAssertEqual(
            store.trackedAccounts.first(where: { $0.id == previous.id })?
                .isConnected,
            true
        )
        await waitUntil { service.callCount(login) == 1 }
        service.failOldest(
            login,
            with: AIAccountConnectionError.statusUnavailable
        )
        await waitUntil { coordinator.runningOperationCount == 0 }

        XCTAssertEqual(
            store.trackedAccounts.first(where: { $0.id == previous.id })?
                .isConnected,
            true
        )
        XCTAssertEqual(
            store.trackedAccounts.first(where: { $0.id == account.id })?
                .lastRefreshFailure,
            .signInFailed
        )
    }

    func testLoginAndRefreshCannotOverlapForOneAccount() async throws {
        let account = makeAccount(provider: .codex, isConnected: false)
        let store = makeStore(accounts: [account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let login = serviceCall(account: account, kind: .login)
        let refresh = serviceCall(account: account, kind: .refresh)

        XCTAssertNotNil(coordinator.startConnect(account))
        XCTAssertNil(coordinator.startRefresh(account))
        await waitUntil { service.callCount(login) == 1 }

        XCTAssertEqual(service.callCount(refresh), 0)
        XCTAssertEqual(
            store.trackedAccounts.first(where: { $0.id == account.id })?
                .lastAttemptKind,
            .signIn
        )

        service.completeOldest(login, with: status(usagePercent: 31))
        await waitUntil { coordinator.runningOperationCount == 0 }
    }

    func testCancellationHandoffAllowsNewOperationAndRejectsOldResult()
        async throws
    {
        let account = makeAccount(provider: .codex, isConnected: true)
        let store = makeStore(accounts: [account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let call = serviceCall(account: account, kind: .refresh)

        let first = try XCTUnwrap(coordinator.startRefresh(account))
        await waitUntil { service.callCount(call) == 1 }
        // Cancelling consumes the running generation; the next request for
        // the same scope must queue behind the cancellation and reject the
        // cancelled operation's late result.
        coordinator.cancelOperations(accountID: account.id)
        let current = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.id == account.id })
        )

        let second = try XCTUnwrap(coordinator.startRefresh(current))

        XCTAssertNotEqual(first, second)
        await waitUntil { service.cancellationCount(call) == 1 }
        XCTAssertEqual(service.callCount(call), 1)

        service.completeOldest(call, with: status(usagePercent: 99))
        await waitUntil { service.callCount(call) == 2 }
        XCTAssertNotEqual(
            store.trackedAccounts.first(where: { $0.id == account.id })?
                .usagePercent,
            99
        )

        service.completeOldest(call, with: status(usagePercent: 42))
        await waitUntil { coordinator.runningOperationCount == 0 }
        XCTAssertEqual(
            store.trackedAccounts.first(where: { $0.id == account.id })?
                .usagePercent,
            42
        )
    }

    func testStaleCompletionCannotMutateReaddedAccountWithSameID()
        async throws
    {
        let account = makeAccount(provider: .codex, isConnected: true)
        let store = makeStore(accounts: [account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let call = serviceCall(account: account, kind: .refresh)

        XCTAssertNotNil(coordinator.startRefresh(account))
        await waitUntil { service.callCount(call) == 1 }
        coordinator.removeTrackedAccount(account)
        var replacement = account
        replacement.label = "Replacement"
        replacement.usagePercent = 7
        replacement.lastCheckedAt = nil
        store.saveTrackedAccount(replacement)

        service.completeOldest(call, with: status(usagePercent: 99))
        await drainTasks()

        let retained = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.id == account.id })
        )
        XCTAssertEqual(retained.label, "Replacement")
        XCTAssertEqual(retained.usagePercent, 7)
        XCTAssertNil(retained.lastSuccessfulRefreshAt)
    }

    private func makeAccount(
        provider: AIProvider,
        isConnected: Bool
    ) -> TrackedAIAccount {
        TrackedAIAccount(
            id: UUID(),
            provider: provider,
            label: "Test \(provider.displayName)",
            email: "",
            planName: "Subscription",
            usagePercent: 5,
            resetsAt: Date(timeIntervalSince1970: 20_000),
            lastCheckedAt: nil,
            isConnected: isConnected,
            lifetimeTokens: nil
        )
    }

    private func makeStore(
        accounts: [TrackedAIAccount]
    ) -> CorporateUsageStore {
        CorporateUsageStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistenceKey: "workspace",
            initialAccounts: accounts,
            freshnessScheduler:
                CoordinatorTestCorporateFreshnessScheduler()
        )
    }

    private func serviceCall(
        account: TrackedAIAccount,
        kind: ControlledCorporateAccountOperationService.Call.Kind
    ) -> ControlledCorporateAccountOperationService.Call {
        .init(
            kind: kind,
            provider: account.provider,
            accountID: account.id
        )
    }

    private func status(
        usagePercent: Int
    ) -> ConnectedAIAccountStatus {
        ConnectedAIAccountStatus(
            email: "test@example.com",
            planName: "plus",
            usagePercent: usagePercent,
            resetsAt: Date(timeIntervalSince1970: 30_000),
            lifetimeTokens: 100
        )
    }

    private func claudeStatus() -> ConnectedAIAccountStatus {
        ConnectedAIAccountStatus(
            email: "claude@example.com",
            planName: "max",
            usagePercent: 12,
            resetsAt: nil,
            lifetimeTokens: nil,
            usageWindows: [
                AIUsageWindow(kind: .session, usagePercent: 12)
            ]
        )
    }

    private func drainTasks() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}

@MainActor
private final class CoordinatorTestCorporateFreshnessScheduler:
    CorporateFreshnessScheduling
{
    func schedule(_ invalidate: @escaping @MainActor () -> Void) {}
}
