import Foundation
import XCTest
@testable import Parallax

/// Covers the refresh policy introduced after the "Sign-in required" incident:
/// a refresh failure never disconnects an account, a provider-reported
/// missing login is remembered until a success clears it, presentation
/// refreshes only what is due with backoff for failing accounts, an
/// in-flight operation is presented as such on every surface, and passes
/// never overlap.
@MainActor
final class CorporateAccountRefreshPolicyTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 1_800_000_000)

    func testRefreshAuthenticationFailureKeepsAccountConnectedWithBackoff()
        async throws
    {
        let account = makeAccount(
            provider: .codex,
            isConnected: true,
            lastSuccessfulRefreshAt: now.addingTimeInterval(-3_600)
        )
        let store = makeStore(accounts: [account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let refresh = call(account, .refresh)

        XCTAssertNotNil(coordinator.startRefresh(account))
        await eventually { service.callCount(refresh) == 1 }
        service.failOldest(
            refresh,
            with: AIAccountConnectionError.notAuthenticated
        )
        await eventually { coordinator.runningOperationCount == 0 }

        let updated = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.id == account.id })
        )
        XCTAssertEqual(updated.isConnected, true)
        XCTAssertEqual(updated.lastRefreshFailure, .authenticationRequired)
        XCTAssertEqual(updated.signInRequired, true)
        XCTAssertTrue(updated.needsSignIn)
        XCTAssertFalse(updated.isSignedIn)
        XCTAssertEqual(
            coordinator.automaticRetryInterval(for: updated),
            CorporateAccountOperationCoordinator.automaticRefreshInterval
        )
        XCTAssertFalse(
            coordinator.isDue(updated, now: now.addingTimeInterval(61)),
            "One failure waits a full pass interval before the next probe"
        )
        XCTAssertTrue(
            coordinator.isDue(
                updated,
                now: now.addingTimeInterval(
                    CorporateAccountOperationCoordinator
                        .automaticRefreshInterval + 1
                )
            )
        )
    }

    func testSignInRequiredSurvivesTransientFailuresUntilASuccess()
        async throws
    {
        let account = makeAccount(provider: .claude, isConnected: true)
        let store = makeStore(accounts: [account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let refresh = call(account, .refresh)
        let login = call(account, .login)

        // The provider explicitly reports no login.
        XCTAssertNotNil(coordinator.startRefresh(account))
        await eventually { service.callCount(refresh) == 1 }
        service.failOldest(
            refresh,
            with: AIAccountConnectionError.notAuthenticated
        )
        await eventually { coordinator.runningOperationCount == 0 }

        // A later transient failure must not turn the card back into
        // "Refresh", which could never succeed.
        XCTAssertNotNil(coordinator.startRefresh(current(store, account)))
        await eventually { service.callCount(refresh) == 2 }
        service.failOldest(
            refresh,
            with: AIAccountConnectionError.statusUnavailable
        )
        await eventually { coordinator.runningOperationCount == 0 }
        var record = current(store, account)
        XCTAssertEqual(record.lastRefreshFailure, .statusUnavailable)
        XCTAssertTrue(record.needsSignIn)
        XCTAssertFalse(record.isSignedIn)
        XCTAssertEqual(
            CorporateAccountStatusPresentation(account: record, now: now).label,
            "Sign-in required"
        )

        // A browser sign-in the user abandons does not clear it either.
        XCTAssertNotNil(coordinator.startConnect(record))
        await eventually { service.callCount(login) == 1 }
        service.failOldest(login, with: AIAccountConnectionError.loginFailed)
        await eventually { coordinator.runningOperationCount == 0 }
        record = current(store, account)
        XCTAssertEqual(record.lastRefreshFailure, .signInFailed)
        XCTAssertTrue(record.needsSignIn)

        // Only a success does.
        XCTAssertNotNil(coordinator.startConnect(record))
        await eventually { service.callCount(login) == 2 }
        service.completeOldest(login, with: claudeStatus(usagePercent: 4))
        await eventually { coordinator.runningOperationCount == 0 }
        record = current(store, account)
        XCTAssertNil(record.lastRefreshFailure)
        XCTAssertEqual(record.signInRequired, false)
        XCTAssertFalse(record.needsSignIn)
        XCTAssertTrue(record.isSignedIn)
    }

    func testEditDuringRefreshKeepsOperationAndAppliesResultOntoEdit()
        async throws
    {
        let account = makeAccount(provider: .codex, isConnected: true)
        let store = makeStore(accounts: [account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let refresh = call(account, .refresh)

        XCTAssertNotNil(coordinator.startRefresh(account))
        await eventually { service.callCount(refresh) == 1 }

        var edited = current(store, account)
        edited.label = "Renamed mid-refresh"
        XCTAssertTrue(store.saveTrackedAccount(edited))
        XCTAssertEqual(coordinator.activity(for: edited), .refreshing)
        XCTAssertEqual(store.inFlightAttemptKind(for: account.id), .refresh)

        service.completeOldest(refresh, with: status(usagePercent: 33))
        await eventually { coordinator.runningOperationCount == 0 }

        let completed = current(store, account)
        XCTAssertEqual(completed.label, "Renamed mid-refresh")
        XCTAssertEqual(completed.usagePercent, 33)
        XCTAssertNil(completed.lastRefreshFailure)
        XCTAssertNotNil(completed.lastRefreshCompletedAt)
        XCTAssertNil(store.inFlightAttemptKind(for: account.id))
    }

    func testDuePassSkipsCurrentAccountsAndProbesSignInRequired()
        async throws
    {
        let fresh = makeAccount(
            provider: .codex,
            isConnected: true,
            lastSuccessfulRefreshAt: now.addingTimeInterval(-30)
        )
        var signInRequired = makeAccount(
            provider: .claude,
            isConnected: true,
            lastSuccessfulRefreshAt: now.addingTimeInterval(-7_200),
            lastAttemptAt: now.addingTimeInterval(-3_600),
            failure: .authenticationRequired
        )
        signInRequired.signInRequired = true
        let disconnected = makeAccount(provider: .codex, isConnected: false)
        let store = makeStore(accounts: [fresh, signInRequired, disconnected])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let probe = call(signInRequired, .refresh)

        let pass = Task { await coordinator.refreshDueAccounts() }
        await eventually { service.callCount(probe) == 1 }
        service.completeOldest(probe, with: claudeStatus(usagePercent: 12))
        await pass.value

        XCTAssertEqual(service.callCount(call(fresh, .refresh)), 0)
        XCTAssertEqual(service.callCount(probe), 1)
        XCTAssertEqual(service.callCount(call(disconnected, .refresh)), 0)

        let healed = current(store, signInRequired)
        XCTAssertNil(healed.lastRefreshFailure)
        XCTAssertEqual(healed.signInRequired, false)
        XCTAssertTrue(healed.isSignedIn)
    }

    func testPassRequestedDuringAnotherWaitsThenRefreshesWhatBecameDue()
        async throws
    {
        let first = makeAccount(provider: .codex, isConnected: true)
        let second = makeAccount(provider: .codex, isConnected: true)
        let later = makeAccount(
            provider: .claude,
            isConnected: true,
            lastSuccessfulRefreshAt: now.addingTimeInterval(-30)
        )
        let store = makeStore(accounts: [first, second, later])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let dueIDs = store.trackedAccounts
            .filter { $0.id != later.id }
            .map(\.id)
        let leading = call(dueIDs[0], .codex, .refresh)
        let trailing = call(dueIDs[1], .codex, .refresh)
        let laterRefresh = call(later, .refresh)

        let passOne = Task { await coordinator.refreshDueAccounts() }
        await eventually { service.callCount(leading) == 1 }

        // The third account becomes stale while the first pass is running.
        now = now.addingTimeInterval(16 * 60)
        let passTwo = Task { await coordinator.refreshDueAccounts() }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(
            service.callCount(trailing),
            0,
            "The second pass waits instead of starting the next account"
        )
        XCTAssertEqual(coordinator.runningOperationCount, 1)

        service.completeOldest(leading, with: status(usagePercent: 10))
        await eventually { service.callCount(trailing) == 1 }
        service.completeOldest(trailing, with: status(usagePercent: 20))
        await passOne.value

        // The waiting pass now covers what the first one did not.
        await eventually { service.callCount(laterRefresh) == 1 }
        XCTAssertEqual(coordinator.runningOperationCount, 1)
        service.completeOldest(laterRefresh, with: claudeStatus(usagePercent: 3))
        await passTwo.value

        XCTAssertEqual(service.callCount(leading), 1)
        XCTAssertEqual(service.callCount(trailing), 1)
        XCTAssertEqual(service.callCount(laterRefresh), 1)
        XCTAssertEqual(coordinator.runningOperationCount, 0)
    }

    func testCancelAllStopsThePassBeforeTheNextAccount() async throws {
        let first = makeAccount(provider: .codex, isConnected: true)
        let second = makeAccount(provider: .codex, isConnected: true)
        let store = makeStore(accounts: [first, second])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let orderedIDs = store.trackedAccounts.map(\.id)
        let leading = call(orderedIDs[0], .codex, .refresh)
        let trailing = call(orderedIDs[1], .codex, .refresh)

        let pass = Task { await coordinator.refreshDueAccounts() }
        await eventually { service.callCount(leading) == 1 }

        coordinator.cancelAll()
        await eventually { service.cancellationCount(leading) == 1 }
        service.failOldest(leading, with: CancellationError())
        await pass.value
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(service.callCount(trailing), 0)
        XCTAssertEqual(coordinator.runningOperationCount, 0)
        XCTAssertEqual(
            store.trackedAccounts.first(where: { $0.id == orderedIDs[1] })?
                .lastRefreshAttemptAt,
            nil,
            "No attempt is persisted for an account the cancelled pass never reached"
        )
    }

    func testConsecutiveFailuresBackOffAndASuccessResets() async throws {
        let account = makeAccount(provider: .codex, isConnected: true)
        let store = makeStore(accounts: [account])
        let service = ControlledCorporateAccountOperationService()
        let coordinator = CorporateAccountOperationCoordinator(
            store: store,
            service: service
        )
        let refresh = call(account, .refresh)

        for attempt in 1...3 {
            XCTAssertNotNil(coordinator.startRefresh(current(store, account)))
            await eventually { service.callCount(refresh) == attempt }
            service.failOldest(
                refresh,
                with: AIAccountConnectionError.statusUnavailable
            )
            await eventually { coordinator.runningOperationCount == 0 }
        }
        XCTAssertEqual(
            coordinator.automaticRetryInterval(for: current(store, account)),
            4 * CorporateAccountOperationCoordinator.automaticRefreshInterval
        )

        XCTAssertNotNil(coordinator.startRefresh(current(store, account)))
        await eventually { service.callCount(refresh) == 4 }
        service.completeOldest(refresh, with: status(usagePercent: 1))
        await eventually { coordinator.runningOperationCount == 0 }
        XCTAssertEqual(
            coordinator.automaticRetryInterval(for: current(store, account)),
            CorporateAccountOperationCoordinator.minimumAutomaticRetryInterval
        )
    }

    func testInFlightOperationIsPresentedAsWorkingOnEverySurface() throws {
        let stale = makeAccount(
            provider: .codex,
            isConnected: true,
            lastSuccessfulRefreshAt: now.addingTimeInterval(-3_600)
        )
        var fresh = makeAccount(
            provider: .codex,
            isConnected: true,
            lastSuccessfulRefreshAt: now.addingTimeInterval(-30)
        )
        fresh.usagePercent = 40
        let store = makeStore(accounts: [stale, fresh])
        let staleGeneration = try XCTUnwrap(
            store.recordRefreshAttempt(accountID: stale.id, kind: .refresh)
        )
        _ = try XCTUnwrap(
            store.recordRefreshAttempt(accountID: fresh.id, kind: .signIn)
        )

        XCTAssertEqual(store.inFlightAttemptKind(for: stale.id), .refresh)
        XCTAssertEqual(store.inFlightAttemptKind(for: fresh.id), .signIn)

        // Stale data plus a running refresh reads as refreshing, not failed.
        let staleRecord = current(store, stale)
        let staleStatus = CorporateAccountStatusPresentation(
            account: staleRecord,
            now: now,
            inFlightAttemptKind: store.inFlightAttemptKind(for: stale.id)
        )
        XCTAssertEqual(staleStatus.label, "Refreshing")
        XCTAssertEqual(staleStatus.tone, .secondary)
        XCTAssertEqual(
            CorporateAccountStatusPresentation(
                account: current(store, fresh),
                now: now,
                inFlightAttemptKind: store.inFlightAttemptKind(for: fresh.id)
            ).label,
            "Available",
            "Values refreshed seconds ago stay current while a sign-in runs"
        )

        // Tiles keep the still-current account for the duration.
        let aggregation = CorporateAccountUsageAggregation(
            accounts: store.trackedAccounts,
            now: now,
            inFlightAttemptKinds: store.inFlightAttemptKinds
        )
        XCTAssertEqual(aggregation.currentUsageAccounts.map(\.id), [fresh.id])

        // Without a live operation the persisted interruption is shown.
        XCTAssertTrue(
            store.recordRefreshFailure(
                accountID: stale.id,
                operationGeneration: staleGeneration,
                failure: .interrupted
            )
        )
        XCTAssertNil(store.inFlightAttemptKind(for: stale.id))
        XCTAssertEqual(
            CorporateAccountStatusPresentation(
                account: current(store, stale),
                now: now,
                inFlightAttemptKind: store.inFlightAttemptKind(for: stale.id)
            ).label,
            "Refresh failed"
        )
    }

    func testSchema4RemembersSignInRequiredAndReconnectsAutoDisconnected()
        throws
    {
        let suiteName = "RefreshPolicySchema4.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let wronglyDisconnected = makeAccount(
            provider: .codex,
            isConnected: false,
            lastSuccessfulRefreshAt: now.addingTimeInterval(-86_400),
            lastAttemptAt: now.addingTimeInterval(-3_600),
            failure: .authenticationRequired
        )
        let neverSignedIn = makeAccount(
            provider: .codex,
            isConnected: false,
            lastAttemptAt: now.addingTimeInterval(-3_600),
            failure: .signInFailed,
            attemptKind: .signIn
        )
        let disconnectedBySignIn = makeAccount(
            provider: .claude,
            isConnected: false,
            lastSuccessfulRefreshAt: now.addingTimeInterval(-86_400),
            lastAttemptAt: now.addingTimeInterval(-3_600),
            failure: .authenticationRequired,
            attemptKind: .signIn
        )
        var envelope = LegacyCorporateWorkspaceEnvelope.fresh(
            trackedAccounts: [
                wronglyDisconnected, neverSignedIn, disconnectedBySignIn,
            ]
        )
        envelope.trackedAccountSchemaVersion = 3
        defaults.set(try JSONEncoder().encode(envelope), forKey: "workspace")

        let store = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: "workspace",
            clock: { self.now },
            freshnessScheduler: RefreshPolicyTestScheduler()
        )

        let reconnected = current(store, wronglyDisconnected)
        XCTAssertEqual(reconnected.isConnected, true)
        XCTAssertEqual(reconnected.signInRequired, true)
        XCTAssertEqual(
            reconnected.lastRefreshFailure,
            .authenticationRequired,
            "The failure stays visible until the automatic pass verifies"
        )
        XCTAssertEqual(current(store, neverSignedIn).isConnected, false)
        XCTAssertNil(current(store, neverSignedIn).signInRequired)
        XCTAssertEqual(current(store, disconnectedBySignIn).isConnected, false)
        XCTAssertEqual(
            current(store, disconnectedBySignIn).signInRequired,
            true
        )

        let reloaded = try JSONDecoder().decode(
            LegacyCorporateWorkspaceEnvelope.self,
            from: try XCTUnwrap(defaults.data(forKey: "workspace"))
        )
        XCTAssertEqual(
            reloaded.trackedAccountSchemaVersion,
            LegacyCorporateWorkspaceEnvelope.currentTrackedAccountSchemaVersion
        )
    }

    func testUndecodablePersistenceIsPreservedBeforeFallingBackToDefaults()
        throws
    {
        let suiteName = "RefreshPolicyUndecodable.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let garbage = Data(#"{"trackedAccounts":"written by a newer build"}"#.utf8)
        defaults.set(garbage, forKey: "workspace")

        let store = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: "workspace",
            freshnessScheduler: RefreshPolicyTestScheduler()
        )

        XCTAssertEqual(
            store.trackedAccounts.map(\.id),
            CorporateUsageStore.defaultTrackedAccounts.map(\.id)
        )
        XCTAssertEqual(
            defaults.data(
                forKey: CorporateUsageStore.undecodableBackupKey(
                    for: "workspace"
                )
            ),
            garbage
        )
    }

    func testUnknownEnumValuesFromANewerBuildDecodeLeniently() throws {
        let json = """
        {
          "id": "6F2C1B3E-0000-4000-8000-000000000001",
          "provider": "claude",
          "label": "Future",
          "email": "",
          "planName": "Max",
          "usagePercent": 5,
          "resetsAt": 0,
          "lastSuccessfulRefreshAt": 1000,
          "lastRefreshAttemptAt": 2000,
          "lastRefreshCompletedAt": 2001,
          "lastAttemptKind": "automatic",
          "lastRefreshFailure": "quantumTunnelCollapsed",
          "isConnected": true,
          "signInRequired": false,
          "usageWindows": [
            {"kind": "hourlyByRegion", "usagePercent": 99},
            {"kind": "session", "usagePercent": 7}
          ]
        }
        """
        let account = try JSONDecoder().decode(
            TrackedAIAccount.self,
            from: Data(json.utf8)
        )

        XCTAssertNil(account.lastAttemptKind)
        XCTAssertNil(account.lastRefreshFailure)
        XCTAssertEqual(account.usageWindows.map(\.kind), [.session])
        XCTAssertEqual(account.normalizedUsagePercent, 7)
        XCTAssertEqual(account.signInRequired, false)
        XCTAssertEqual(account.label, "Future")
    }

    func testCodexWindowsDriveHeadlineUsage() {
        let account = makeAccount(provider: .codex, isConnected: true)
        let status = ConnectedAIAccountStatus(
            email: "codex@example.com",
            planName: "plus",
            usagePercent: 90,
            resetsAt: now,
            lifetimeTokens: 10,
            usageWindows: [
                AIUsageWindow(kind: .session, usagePercent: 10),
                AIUsageWindow(kind: .weeklyAllModels, usagePercent: 90),
            ]
        )

        let applied = CorporateAccountRefreshApplication(
            status: status,
            account: account
        )

        XCTAssertNil(applied.failure)
        XCTAssertEqual(applied.account.usageWindows.count, 2)
        XCTAssertEqual(applied.account.normalizedUsagePercent, 90)
        XCTAssertTrue(applied.account.needsAttention)
        XCTAssertEqual(applied.account.signInRequired, false)
    }

    // MARK: - Support

    private func makeAccount(
        provider: AIProvider,
        isConnected: Bool,
        lastSuccessfulRefreshAt: Date? = nil,
        lastAttemptAt: Date? = nil,
        failure: TrackedAccountRefreshFailure? = nil,
        attemptKind: TrackedAccountAttemptKind = .refresh
    ) -> TrackedAIAccount {
        let attempt = lastAttemptAt ?? lastSuccessfulRefreshAt
        return TrackedAIAccount(
            id: UUID(),
            provider: provider,
            label: "Policy \(provider.displayName) \(UUID().uuidString)",
            email: "",
            planName: "Subscription",
            usagePercent: 5,
            resetsAt: Date(timeIntervalSince1970: 20_000),
            lastCheckedAt: nil,
            isConnected: isConnected,
            lifetimeTokens: nil,
            lastSuccessfulRefreshAt: lastSuccessfulRefreshAt,
            lastRefreshAttemptAt: attempt,
            lastRefreshCompletedAt: attempt,
            lastAttemptKind: attempt == nil ? nil : attemptKind,
            lastRefreshFailure: failure
        )
    }

    private func makeStore(
        accounts: [TrackedAIAccount]
    ) -> CorporateUsageStore {
        CorporateUsageStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistenceKey: "workspace",
            initialAccounts: accounts,
            clock: { self.now },
            freshnessScheduler: RefreshPolicyTestScheduler()
        )
    }

    private func current(
        _ store: CorporateUsageStore,
        _ account: TrackedAIAccount
    ) -> TrackedAIAccount {
        store.trackedAccounts.first(where: { $0.id == account.id }) ?? account
    }

    private func call(
        _ account: TrackedAIAccount,
        _ kind: ControlledCorporateAccountOperationService.Call.Kind
    ) -> ControlledCorporateAccountOperationService.Call {
        call(account.id, account.provider, kind)
    }

    private func call(
        _ accountID: UUID,
        _ provider: AIProvider,
        _ kind: ControlledCorporateAccountOperationService.Call.Kind
    ) -> ControlledCorporateAccountOperationService.Call {
        .init(kind: kind, provider: provider, accountID: accountID)
    }

    private func status(usagePercent: Int) -> ConnectedAIAccountStatus {
        ConnectedAIAccountStatus(
            email: "test@example.com",
            planName: "plus",
            usagePercent: usagePercent,
            resetsAt: now.addingTimeInterval(3_600),
            lifetimeTokens: 100
        )
    }

    private func claudeStatus(usagePercent: Int) -> ConnectedAIAccountStatus {
        ConnectedAIAccountStatus(
            email: "claude@example.com",
            planName: "max",
            usagePercent: usagePercent,
            resetsAt: nil,
            lifetimeTokens: nil,
            usageWindows: [
                AIUsageWindow(kind: .session, usagePercent: usagePercent)
            ]
        )
    }

    private func eventually(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ProviderDeadline(after: timeout)
        while !condition() {
            if deadline.hasExpired {
                XCTFail("Condition not met within \(timeout)s")
                return
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

@MainActor
private final class RefreshPolicyTestScheduler: CorporateFreshnessScheduling {
    func schedule(_ invalidate: @escaping @MainActor () -> Void) {}
}
