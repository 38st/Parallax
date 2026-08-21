import Foundation
import XCTest
@testable import Parallax

@MainActor
final class CorporateUsageStoreTests: XCTestCase {
    func testDefaultAccountInventoryContainsFourCodexAndOneClaude() {
        let store = makeStore()

        XCTAssertEqual(store.trackedAccounts.count, 5)
        XCTAssertEqual(
            store.trackedAccounts.filter { $0.provider == .codex }.count,
            4
        )
        XCTAssertEqual(
            store.trackedAccounts.filter { $0.provider == .claude }.count,
            1
        )
    }

    func testLegacyWorkspaceEnvelopeSurvivesAccountMutation() throws {
        let suiteName = "CorporateCompatibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "workspace"
        var account = try XCTUnwrap(
            CorporateUsageStore.defaultTrackedAccounts.first
        )
        let fixture = LegacyCorporateWorkspaceFixture.full(
            trackedAccounts: [account]
        )
        defaults.set(try JSONEncoder().encode(fixture), forKey: key)

        let store = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key
        )
        account.label = "Edited account"
        store.saveTrackedAccount(account)

        let persistedData = try XCTUnwrap(defaults.data(forKey: key))
        let persisted = try JSONDecoder().decode(
            LegacyCorporateWorkspaceFixture.self,
            from: persistedData
        )
        XCTAssertEqual(persisted.organizationName, fixture.organizationName)
        XCTAssertEqual(persisted.cycleEndsAt, fixture.cycleEndsAt)
        XCTAssertEqual(
            persisted.autoRebalanceEnabled,
            fixture.autoRebalanceEnabled
        )
        XCTAssertEqual(persisted.providerPools, fixture.providerPools)
        XCTAssertEqual(persisted.members, fixture.members)
        XCTAssertEqual(persisted.transfers, fixture.transfers)
        XCTAssertEqual(persisted.trackedAccounts?.first?.label, "Edited account")
    }

    func testLegacyEnvelopeWithoutAccountsUsesDefaultsAndPreservesFields()
        throws
    {
        let suiteName = "CorporateCompatibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "workspace"
        let fixture = LegacyCorporateWorkspaceFixture.full(
            trackedAccounts: nil
        )
        defaults.set(try JSONEncoder().encode(fixture), forKey: key)

        let store = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key
        )
        XCTAssertEqual(store.trackedAccounts.count, 5)
        var first = try XCTUnwrap(store.trackedAccounts.first)
        first.label = "Materialized default"
        store.saveTrackedAccount(first)

        let persistedData = try XCTUnwrap(defaults.data(forKey: key))
        let persisted = try JSONDecoder().decode(
            LegacyCorporateWorkspaceFixture.self,
            from: persistedData
        )
        XCTAssertEqual(persisted.providerPools, fixture.providerPools)
        XCTAssertEqual(persisted.members, fixture.members)
        XCTAssertEqual(persisted.transfers, fixture.transfers)
        XCTAssertEqual(persisted.trackedAccounts?.count, 5)
        XCTAssertEqual(
            persisted.trackedAccounts?.first(where: { $0.id == first.id })?
                .label,
            "Materialized default"
        )
    }

    func testFreshPersistenceContainsNoFictionalEnterpriseInventory() throws {
        let suiteName = "CorporateFreshEnvelopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "workspace"
        let store = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key
        )

        store.saveTrackedAccount(try XCTUnwrap(store.trackedAccounts.first))

        let persistedData = try XCTUnwrap(defaults.data(forKey: key))
        let persisted = try JSONDecoder().decode(
            LegacyCorporateWorkspaceFixture.self,
            from: persistedData
        )
        XCTAssertEqual(persisted.organizationName, "")
        XCTAssertFalse(persisted.autoRebalanceEnabled)
        XCTAssertTrue(persisted.providerPools.isEmpty)
        XCTAssertTrue(persisted.members.isEmpty)
        XCTAssertTrue(persisted.transfers.isEmpty)
        XCTAssertEqual(persisted.trackedAccounts?.count, 5)
    }

    func testAccountUsageAndIdentityPersist() throws {
        let suiteName = "CorporateAccountTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "workspace"
        let store = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key,
            initialAccounts: CorporateUsageStore.defaultTrackedAccounts
        )
        var account = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.provider == .codex })
        )
        account.email = "owner@example.com"
        account.usagePercent = 85
        account.usageWindows = [
            AIUsageWindow(
                kind: .weeklyAllModels,
                usagePercent: 85,
                resetsAt: Date(timeIntervalSince1970: 500)
            )
        ]
        account.lastCheckedAt = Date(timeIntervalSince1970: 200)

        store.saveTrackedAccount(account)

        let reloaded = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key
        )
        let persisted = try XCTUnwrap(
            reloaded.trackedAccounts.first(where: { $0.id == account.id })
        )
        XCTAssertEqual(persisted.email, "owner@example.com")
        XCTAssertEqual(persisted.usagePercent, 85)
        XCTAssertEqual(persisted.usageWindows, account.usageWindows)
        XCTAssertTrue(persisted.needsAttention)
    }

    func testAddingAccountCreatesNextAvailableProviderSlot() throws {
        let store = makeStore()

        let account = try XCTUnwrap(
            store.addTrackedAccount(provider: .codex)
        )

        XCTAssertEqual(account.label, "Codex Account 5")
        XCTAssertEqual(account.provider, .codex)
        XCTAssertEqual(account.isConnected, false)
        XCTAssertEqual(store.trackedAccounts.count, 6)
    }

    func testProviderCapabilitiesDescribeCredentialAndOperationScopes() {
        XCTAssertEqual(
            AIProvider.codex.accountCapabilities.credentialScope,
            .accountDirectory
        )
        XCTAssertEqual(
            AIProvider.codex.accountCapabilities.operationScope,
            .account
        )
        XCTAssertNil(
            AIProvider.codex.accountCapabilities.maximumTrackedAccounts
        )
        XCTAssertEqual(
            AIProvider.claude.accountCapabilities.credentialScope,
            .macOSUserShared
        )
        XCTAssertEqual(
            AIProvider.claude.accountCapabilities.configurationScope,
            .accountDirectory
        )
        XCTAssertEqual(
            AIProvider.claude.accountCapabilities.operationScope,
            .provider
        )
        XCTAssertEqual(
            AIProvider.claude.accountCapabilities.maximumTrackedAccounts,
            1
        )
    }

    func testClaudeMaximumBlocksNewRowsWithoutDeletingLegacyRows() {
        let store = makeStore()
        let originalIDs = store.trackedAccounts.map(\.id)

        XCTAssertFalse(store.canAddTrackedAccount(provider: .claude))
        XCTAssertNil(store.addTrackedAccount(provider: .claude))
        XCTAssertEqual(store.trackedAccounts.map(\.id), originalIDs)
        XCTAssertTrue(store.canAddTrackedAccount(provider: .codex))
    }

    func testSaveRejectsProviderMutationAndDirectProviderCapBypass() throws {
        let store = makeStore()
        let originalIDs = store.trackedAccounts.map(\.id)
        var codex = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.provider == .codex })
        )
        codex.provider = .claude
        codex.isConnected = true

        XCTAssertFalse(store.saveTrackedAccount(codex))
        XCTAssertEqual(
            store.trackedAccounts.first(where: { $0.id == codex.id })?
                .provider,
            .codex
        )

        let extraClaude = makeAccount(
            provider: .claude,
            isConnected: false
        )
        XCTAssertFalse(store.saveTrackedAccount(extraClaude))
        XCTAssertEqual(store.trackedAccounts.map(\.id), originalIDs)
    }

    func testSharedCredentialSignInInvalidatesPreviousConnectionBeforeProviderWork()
        throws
    {
        let first = makeAccount(provider: .claude, isConnected: true)
        let second = makeAccount(provider: .claude, isConnected: false)
        let store = CorporateUsageStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistenceKey: "workspace",
            initialAccounts: [first, second],
            freshnessScheduler: TestCorporateFreshnessScheduler()
        )

        XCTAssertNotNil(
            store.recordRefreshAttempt(
                accountID: second.id,
                kind: .signIn
            )
        )
        XCTAssertTrue(
            store.trackedAccounts
                .filter { $0.provider == .claude }
                .allSatisfy { $0.isConnected != true }
        )
    }

    func testMultipleLegacySharedCredentialConnectionsNormalizeFailClosed()
        throws
    {
        let suiteName = "CorporateSharedCredentialTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "workspace"
        let first = makeAccount(provider: .claude, isConnected: true)
        let second = makeAccount(provider: .claude, isConnected: true)
        let store = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key,
            initialAccounts: [first, second],
            freshnessScheduler: TestCorporateFreshnessScheduler()
        )

        XCTAssertTrue(
            store.trackedAccounts.allSatisfy { $0.isConnected != true }
        )
        let reloaded = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key,
            freshnessScheduler: TestCorporateFreshnessScheduler()
        )
        XCTAssertTrue(
            reloaded.trackedAccounts.allSatisfy { $0.isConnected != true }
        )
    }

    func testLegacyAccountTimestampDecodesAsSuccessfulAttempt() throws {
        let checkedAt = Date(timeIntervalSince1970: 2_000)
        let legacy = LegacyTrackedAIAccount(
            id: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!,
            provider: .codex,
            label: "Legacy",
            email: "legacy@example.com",
            planName: "Team",
            usagePercent: 42,
            resetsAt: Date(timeIntervalSince1970: 9_999),
            lastCheckedAt: checkedAt,
            isConnected: true,
            lifetimeTokens: 123
        )

        let decoded = try JSONDecoder().decode(
            TrackedAIAccount.self,
            from: JSONEncoder().encode(legacy)
        )

        XCTAssertEqual(decoded.lastSuccessfulRefreshAt, checkedAt)
        XCTAssertEqual(decoded.lastRefreshAttemptAt, checkedAt)
        XCTAssertEqual(decoded.lastRefreshCompletedAt, checkedAt)
        XCTAssertEqual(decoded.lastAttemptKind, .refresh)
        XCTAssertNil(decoded.lastRefreshFailure)
        XCTAssertEqual(decoded.lastCheckedAt, checkedAt)
    }

    func testSuccessThenFailurePersistsLastKnownValuesAcrossRestart() throws {
        let suiteName = "CorporateFreshnessTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "workspace"
        var now = Date(timeIntervalSince1970: 1_000)
        let store = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key,
            initialAccounts: CorporateUsageStore.defaultTrackedAccounts,
            clock: { now }
        )
        var account = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.provider == .codex })
        )
        account.isConnected = true
        account.planName = "Team"
        account.usagePercent = 72
        let initialGeneration = try XCTUnwrap(
            store.recordRefreshAttempt(
                accountID: account.id,
                kind: .refresh
            )
        )
        XCTAssertTrue(
            store.recordRefreshSuccess(
                account,
                operationGeneration: initialGeneration
            )
        )

        now = Date(timeIntervalSince1970: 1_200)
        let failureGeneration = try XCTUnwrap(
            store.recordRefreshAttempt(
                accountID: account.id,
                kind: .refresh
            )
        )
        now = Date(timeIntervalSince1970: 1_300)
        XCTAssertTrue(
            store.recordRefreshFailure(
                accountID: account.id,
                operationGeneration: failureGeneration,
                failure: .statusUnavailable
            )
        )

        let reloaded = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key,
            clock: { now }
        )
        let persisted = try XCTUnwrap(
            reloaded.trackedAccounts.first(where: { $0.id == account.id })
        )

        XCTAssertEqual(persisted.planName, "Team")
        XCTAssertEqual(persisted.usagePercent, 72)
        XCTAssertEqual(
            persisted.lastSuccessfulRefreshAt,
            Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(
            persisted.lastRefreshAttemptAt,
            Date(timeIntervalSince1970: 1_200)
        )
        XCTAssertEqual(
            persisted.lastRefreshCompletedAt,
            Date(timeIntervalSince1970: 1_300)
        )
        XCTAssertEqual(persisted.lastRefreshFailure, .statusUnavailable)
        XCTAssertEqual(
            CorporateAccountFreshnessPolicy.state(
                for: persisted,
                now: reloaded.currentDate
            ),
            .failed(
                lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 1_000),
                attemptedAt: Date(timeIntervalSince1970: 1_200),
                failure: .statusUnavailable
            )
        )
    }

    func testClockRollbackAfterRestartMakesSuccessfulValuesStale() throws {
        let suiteName = "CorporateClockTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "workspace"
        var now = Date(timeIntervalSince1970: 5_000)
        let store = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key,
            initialAccounts: CorporateUsageStore.defaultTrackedAccounts,
            clock: { now }
        )
        var account = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.provider == .codex })
        )
        account.isConnected = true
        account.usagePercent = 20
        let generation = try XCTUnwrap(
            store.recordRefreshAttempt(
                accountID: account.id,
                kind: .refresh
            )
        )
        XCTAssertTrue(
            store.recordRefreshSuccess(
                account,
                operationGeneration: generation
            )
        )

        now = Date(timeIntervalSince1970: 4_999)
        let reloaded = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key,
            clock: { now }
        )
        let persisted = try XCTUnwrap(
            reloaded.trackedAccounts.first(where: { $0.id == account.id })
        )

        XCTAssertEqual(
            CorporateAccountFreshnessPolicy.state(
                for: persisted,
                now: reloaded.currentDate
            ),
            .stale(
                lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 5_000),
                reason: .clockAnomaly
            )
        )
    }

    func testAttemptPersistsBeforeCompletionAndRestartsAsInterrupted() throws {
        let suiteName = "CorporateAttemptTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "workspace"
        let now = Date(timeIntervalSince1970: 7_000)
        let store = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key,
            initialAccounts: CorporateUsageStore.defaultTrackedAccounts,
            clock: { now },
            freshnessScheduler: TestCorporateFreshnessScheduler()
        )
        let account = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.provider == .codex })
        )

        XCTAssertNotNil(
            store.recordRefreshAttempt(accountID: account.id, kind: .signIn)
        )

        let reloaded = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key,
            clock: { now },
            freshnessScheduler: TestCorporateFreshnessScheduler()
        )
        let persisted = try XCTUnwrap(
            reloaded.trackedAccounts.first(where: { $0.id == account.id })
        )
        XCTAssertEqual(persisted.lastRefreshAttemptAt, now)
        XCTAssertNil(persisted.lastRefreshCompletedAt)
        XCTAssertEqual(persisted.lastAttemptKind, .signIn)
        XCTAssertEqual(
            CorporateAccountFreshnessPolicy.state(for: persisted, now: now),
            .failed(
                lastSuccessfulRefreshAt: nil,
                attemptedAt: now,
                failure: .interrupted
            )
        )
    }

    func testScheduledInvalidationExpiresAndFailsClosedOnClockRollback() throws {
        let scheduler = TestCorporateFreshnessScheduler()
        var now = Date(timeIntervalSince1970: 8_000)
        let store = CorporateUsageStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistenceKey: "workspace",
            initialAccounts: CorporateUsageStore.defaultTrackedAccounts,
            clock: { now },
            freshnessScheduler: scheduler
        )
        var account = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.provider == .codex })
        )
        account.isConnected = true
        account.usagePercent = 20
        let generation = try XCTUnwrap(
            store.recordRefreshAttempt(
                accountID: account.id,
                kind: .refresh
            )
        )
        XCTAssertTrue(
            store.recordRefreshSuccess(
                account,
                operationGeneration: generation
            )
        )
        account = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.id == account.id })
        )
        XCTAssertTrue(
            CorporateAccountFreshnessPolicy.state(
                for: account,
                now: store.currentDate
            ).isCurrent
        )

        let initialRevision = store.freshnessRevision
        now = Date(
            timeIntervalSince1970: 8_000
                + CorporateAccountFreshnessPolicy.currentAgeThreshold + 1
        )
        scheduler.fire()
        XCTAssertEqual(store.freshnessRevision, initialRevision + 1)
        XCTAssertEqual(
            CorporateAccountFreshnessPolicy.state(
                for: account,
                now: store.currentDate
            ),
            .stale(
                lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 8_000),
                reason: .ageExpired
            )
        )

        now = Date(timeIntervalSince1970: 7_999)
        scheduler.fire()
        XCTAssertEqual(
            CorporateAccountFreshnessPolicy.state(
                for: account,
                now: store.currentDate
            ),
            .stale(
                lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 8_000),
                reason: .clockAnomaly
            )
        )
    }

    func testSuccessfulCompletionPreservesAttemptDuration() throws {
        var now = Date(timeIntervalSince1970: 10_000)
        let store = CorporateUsageStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistenceKey: "workspace",
            initialAccounts: CorporateUsageStore.defaultTrackedAccounts,
            clock: { now },
            freshnessScheduler: TestCorporateFreshnessScheduler()
        )
        let account = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.provider == .codex })
        )
        let generation = try XCTUnwrap(
            store.recordRefreshAttempt(
                accountID: account.id,
                kind: .refresh
            )
        )

        now = Date(timeIntervalSince1970: 10_045)
        XCTAssertTrue(
            store.recordRefreshSuccess(
                account,
                operationGeneration: generation
            )
        )
        let completed = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.id == account.id })
        )
        XCTAssertEqual(
            completed.lastRefreshAttemptAt,
            Date(timeIntervalSince1970: 10_000)
        )
        XCTAssertEqual(completed.lastRefreshCompletedAt, now)
        XCTAssertEqual(completed.lastSuccessfulRefreshAt, now)
        XCTAssertEqual(completed.lastAttemptKind, .refresh)
    }

    func testRemovedAndReaddedAccountRejectsEveryLateCompletion() throws {
        let store = makeStore()
        let original = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.provider == .codex })
        )
        let generation = try XCTUnwrap(
            store.recordRefreshAttempt(
                accountID: original.id,
                kind: .refresh
            )
        )
        store.removeTrackedAccount(id: original.id)

        var replacement = original
        replacement.label = "Replacement record"
        replacement.usagePercent = 7
        replacement.lastCheckedAt = nil
        store.saveTrackedAccount(replacement)

        var lateSuccess = original
        lateSuccess.usagePercent = 99
        XCTAssertFalse(
            store.recordRefreshSuccess(
                lateSuccess,
                operationGeneration: generation
            )
        )
        XCTAssertFalse(
            store.recordRefreshFailure(
                lateSuccess,
                operationGeneration: generation,
                failure: .incompleteProviderData
            )
        )
        XCTAssertFalse(
            store.recordRefreshFailure(
                accountID: original.id,
                operationGeneration: generation,
                failure: .statusUnavailable
            )
        )

        let retained = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.id == original.id })
        )
        XCTAssertEqual(retained.label, "Replacement record")
        XCTAssertEqual(retained.usagePercent, 7)
        XCTAssertNil(retained.lastSuccessfulRefreshAt)
        XCTAssertNil(retained.lastRefreshFailure)
    }

    func testNewAttemptGenerationRejectsOlderResponse() throws {
        let store = makeStore()
        let account = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.provider == .codex })
        )
        let older = try XCTUnwrap(
            store.recordRefreshAttempt(
                accountID: account.id,
                kind: .refresh
            )
        )
        let current = try XCTUnwrap(
            store.recordRefreshAttempt(
                accountID: account.id,
                kind: .signIn
            )
        )

        XCTAssertFalse(
            store.recordRefreshFailure(
                accountID: account.id,
                operationGeneration: older,
                failure: .statusUnavailable
            )
        )
        XCTAssertTrue(
            store.recordRefreshFailure(
                accountID: account.id,
                operationGeneration: current,
                failure: .signInFailed
            )
        )
        let completed = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.id == account.id })
        )
        XCTAssertEqual(completed.lastAttemptKind, .signIn)
        XCTAssertEqual(completed.lastRefreshFailure, .signInFailed)
    }

    func testNewInterruptedPayloadDoesNotSynthesizeCompletion() throws {
        let timestamps: [(Date, Date)] = [
            (
                Date(timeIntervalSince1970: 20_000),
                Date(timeIntervalSince1970: 20_000)
            ),
            (
                Date(timeIntervalSince1970: 20_000),
                Date(timeIntervalSince1970: 19_000)
            ),
        ]

        for (success, attempt) in timestamps {
            let payload = InterruptedTrackedAIAccount(
                id: UUID(),
                provider: .codex,
                label: "Interrupted",
                email: "",
                planName: "Team",
                usagePercent: 25,
                resetsAt: Date(timeIntervalSince1970: 30_000),
                lastCheckedAt: success,
                lastSuccessfulRefreshAt: success,
                lastRefreshAttemptAt: attempt,
                lastAttemptKind: .refresh,
                isConnected: true,
                lifetimeTokens: nil
            )
            let decoded = try JSONDecoder().decode(
                TrackedAIAccount.self,
                from: JSONEncoder().encode(payload)
            )

            XCTAssertEqual(decoded.lastSuccessfulRefreshAt, success)
            XCTAssertEqual(decoded.lastRefreshAttemptAt, attempt)
            XCTAssertNil(decoded.lastRefreshCompletedAt)
            XCTAssertEqual(decoded.lastAttemptKind, .refresh)
            XCTAssertEqual(
                CorporateAccountFreshnessPolicy.state(
                    for: decoded,
                    now: success
                ),
                .failed(
                    lastSuccessfulRefreshAt: success,
                    attemptedAt: attempt,
                    failure: .interrupted
                )
            )
        }
    }

    func testEditorSaveAfterAttemptPreservesAttemptAndInvalidatesResponse()
        throws
    {
        let store = makeStore()
        let baseline = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.provider == .codex })
        )
        var draft = TrackedAccountEditorDraft(account: baseline)
        let generation = try XCTUnwrap(
            store.recordRefreshAttempt(
                accountID: baseline.id,
                kind: .refresh
            )
        )
        let attempted = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.id == baseline.id })
        )

        draft.label = "Edited during refresh"
        store.saveTrackedAccount(draft.merging(into: attempted))

        let saved = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.id == baseline.id })
        )
        XCTAssertEqual(saved.label, "Edited during refresh")
        XCTAssertEqual(saved.lastRefreshAttemptAt, attempted.lastRefreshAttemptAt)
        XCTAssertNil(saved.lastRefreshCompletedAt)
        XCTAssertEqual(saved.lastAttemptKind, .refresh)
        XCTAssertFalse(
            store.isCurrentOperation(
                accountID: baseline.id,
                generation: generation
            )
        )
        var late = saved
        late.usagePercent = 100
        XCTAssertFalse(
            store.recordRefreshSuccess(
                late,
                operationGeneration: generation
            )
        )
        XCTAssertEqual(
            store.trackedAccounts.first(where: { $0.id == baseline.id })?
                .usagePercent,
            saved.usagePercent
        )
    }

    func testEditorSaveAfterCompletionKeepsUntouchedProviderMetadata()
        throws
    {
        var now = Date(timeIntervalSince1970: 40_000)
        let store = CorporateUsageStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistenceKey: "workspace",
            initialAccounts: CorporateUsageStore.defaultTrackedAccounts,
            clock: { now },
            freshnessScheduler: TestCorporateFreshnessScheduler()
        )
        let baseline = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.provider == .codex })
        )
        var draft = TrackedAccountEditorDraft(account: baseline)
        let generation = try XCTUnwrap(
            store.recordRefreshAttempt(
                accountID: baseline.id,
                kind: .refresh
            )
        )
        var providerResult = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.id == baseline.id })
        )
        providerResult.email = "fresh@example.com"
        providerResult.planName = "Enterprise"
        providerResult.usagePercent = 63
        providerResult.resetsAt = Date(timeIntervalSince1970: 50_000)
        now = Date(timeIntervalSince1970: 40_030)
        XCTAssertTrue(
            store.recordRefreshSuccess(
                providerResult,
                operationGeneration: generation
            )
        )
        let refreshed = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.id == baseline.id })
        )

        draft.label = "Edited after completion"
        store.saveTrackedAccount(draft.merging(into: refreshed))

        let saved = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.id == baseline.id })
        )
        XCTAssertEqual(saved.label, "Edited after completion")
        XCTAssertEqual(saved.email, "fresh@example.com")
        XCTAssertEqual(saved.planName, "Enterprise")
        XCTAssertEqual(saved.usagePercent, 63)
        XCTAssertEqual(saved.resetsAt, Date(timeIntervalSince1970: 50_000))
        XCTAssertEqual(saved.lastSuccessfulRefreshAt, now)
        XCTAssertEqual(saved.lastRefreshCompletedAt, now)
        XCTAssertNil(saved.lastRefreshFailure)
    }

    private func makeStore() -> CorporateUsageStore {
        CorporateUsageStore(
            userDefaults: UserDefaults(suiteName: UUID().uuidString)!,
            persistenceKey: "workspace",
            initialAccounts: CorporateUsageStore.defaultTrackedAccounts
        )
    }

    private func makeAccount(
        provider: AIProvider,
        isConnected: Bool
    ) -> TrackedAIAccount {
        TrackedAIAccount(
            id: UUID(),
            provider: provider,
            label: "Test \(provider.displayName) \(UUID().uuidString)",
            email: "",
            planName: "Subscription",
            usagePercent: 0,
            resetsAt: Date(timeIntervalSince1970: 20_000),
            lastCheckedAt: nil,
            isConnected: isConnected,
            lifetimeTokens: nil
        )
    }
}

private struct LegacyCorporateWorkspaceFixture: Codable, Equatable {
    var organizationName: String
    var cycleEndsAt: Date
    var autoRebalanceEnabled: Bool
    var providerPools: [LegacyCorporateProviderPoolFixture]
    var members: [LegacyCorporateMemberFixture]
    var transfers: [LegacyCapacityTransferFixture]
    var trackedAccounts: [TrackedAIAccount]?

    static func full(trackedAccounts: [TrackedAIAccount]?) -> Self {
        let sourceID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000001"
        )!
        let destinationID = UUID(
            uuidString: "00000000-0000-0000-0000-000000000002"
        )!
        return Self(
            organizationName: "Preserved legacy organization",
            cycleEndsAt: Date(timeIntervalSince1970: 12_345),
            autoRebalanceEnabled: true,
            providerPools: [
                LegacyCorporateProviderPoolFixture(
                    provider: .codex,
                    purchasedSeats: 10,
                    assignedSeats: 8,
                    capacityUsedPercent: 64
                )
            ],
            members: [
                LegacyCorporateMemberFixture(
                    id: sourceID,
                    name: "Preserved source",
                    email: "source@example.com",
                    team: "Legacy",
                    role: "Member",
                    claude: .init(
                        allocatedCapacity: 10,
                        consumedCapacity: 2
                    ),
                    codex: .init(
                        allocatedCapacity: 20,
                        consumedCapacity: 5
                    )
                )
            ],
            transfers: [
                LegacyCapacityTransferFixture(
                    id: UUID(
                        uuidString:
                            "00000000-0000-0000-0000-000000000003"
                    )!,
                    provider: .codex,
                    sourceMemberID: sourceID,
                    sourceName: "Preserved source",
                    destinationMemberID: destinationID,
                    destinationName: "Preserved destination",
                    capacity: 3,
                    createdAt: Date(timeIntervalSince1970: 12_000)
                )
            ],
            trackedAccounts: trackedAccounts
        )
    }
}

private struct LegacyCorporateSeatUsageFixture: Codable, Equatable {
    var allocatedCapacity: Int
    var consumedCapacity: Int
}

private struct LegacyCorporateMemberFixture: Codable, Equatable {
    let id: UUID
    var name: String
    var email: String
    var team: String
    var role: String
    var claude: LegacyCorporateSeatUsageFixture
    var codex: LegacyCorporateSeatUsageFixture
}

private struct LegacyCorporateProviderPoolFixture: Codable, Equatable {
    let provider: AIProvider
    var purchasedSeats: Int
    var assignedSeats: Int
    var capacityUsedPercent: Int
}

private struct LegacyCapacityTransferFixture: Codable, Equatable {
    let id: UUID
    let provider: AIProvider
    let sourceMemberID: UUID
    let sourceName: String
    let destinationMemberID: UUID
    let destinationName: String
    let capacity: Int
    let createdAt: Date
}

private struct LegacyTrackedAIAccount: Codable {
    let id: UUID
    let provider: AIProvider
    let label: String
    let email: String
    let planName: String
    let usagePercent: Int
    let resetsAt: Date
    let lastCheckedAt: Date?
    let isConnected: Bool?
    let lifetimeTokens: Int?
}

private struct InterruptedTrackedAIAccount: Codable {
    let id: UUID
    let provider: AIProvider
    let label: String
    let email: String
    let planName: String
    let usagePercent: Int
    let resetsAt: Date
    let lastCheckedAt: Date?
    let lastSuccessfulRefreshAt: Date?
    let lastRefreshAttemptAt: Date?
    let lastAttemptKind: TrackedAccountAttemptKind?
    let isConnected: Bool?
    let lifetimeTokens: Int?
}

@MainActor
private final class TestCorporateFreshnessScheduler:
    CorporateFreshnessScheduling
{
    private var invalidation: (@MainActor () -> Void)?

    func schedule(_ invalidate: @escaping @MainActor () -> Void) {
        invalidation = invalidate
    }

    func fire() {
        invalidation?()
    }
}
