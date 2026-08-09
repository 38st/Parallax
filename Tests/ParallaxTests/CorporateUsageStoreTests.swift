import Foundation
import XCTest
@testable import Parallax

@MainActor
final class CorporateUsageStoreTests: XCTestCase {
    private let sourceID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000005"
    )!
    private let destinationID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000001"
    )!

    func testTransferMovesCapacityWithoutChangingOrganizationTotal() throws {
        let store = makeStore()
        let totalBefore = totalCapacity(in: store, provider: .claude)

        try store.transferCapacity(
            provider: .claude,
            from: sourceID,
            to: destinationID,
            capacity: 20,
            createdAt: Date(timeIntervalSince1970: 100)
        )

        XCTAssertEqual(
            store.usage(for: sourceID, provider: .claude)?.allocatedCapacity,
            80
        )
        XCTAssertEqual(
            store.usage(for: destinationID, provider: .claude)?.allocatedCapacity,
            120
        )
        XCTAssertEqual(totalCapacity(in: store, provider: .claude), totalBefore)
        XCTAssertEqual(store.transfers.first?.capacity, 20)
        XCTAssertEqual(store.transfers.first?.provider, .claude)
    }

    func testTransferPreservesSafetyBuffer() {
        let store = makeStore()

        XCTAssertThrowsError(
            try store.transferCapacity(
                provider: .claude,
                from: sourceID,
                to: destinationID,
                capacity: 75
            )
        ) { error in
            XCTAssertEqual(
                error as? CapacityTransferError,
                .insufficientCapacity(available: 72)
            )
        }
    }

    func testTransferPersistsForNextWorkspaceSession() throws {
        let suiteName = "CorporateUsageStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "workspace"
        let store = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key,
            initialSnapshot: CorporateUsageStore.demoSnapshot
        )

        try store.transferCapacity(
            provider: .codex,
            from: sourceID,
            to: destinationID,
            capacity: 20
        )

        let reloaded = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key
        )
        XCTAssertEqual(
            reloaded.usage(for: sourceID, provider: .codex)?.allocatedCapacity,
            60
        )
        XCTAssertEqual(
            reloaded.usage(for: destinationID, provider: .codex)?.allocatedCapacity,
            100
        )
        XCTAssertEqual(reloaded.transfers.count, 1)
    }

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

    func testAccountUsageAndIdentityPersist() throws {
        let suiteName = "CorporateAccountTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "workspace"
        let store = CorporateUsageStore(
            userDefaults: defaults,
            persistenceKey: key,
            initialSnapshot: CorporateUsageStore.demoSnapshot
        )
        var account = try XCTUnwrap(
            store.trackedAccounts.first(where: { $0.provider == .codex })
        )
        account.email = "owner@example.com"
        account.usagePercent = 85
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
        XCTAssertTrue(persisted.needsAttention)
    }

    func testAddingAccountCreatesNextAvailableProviderSlot() {
        let store = makeStore()

        let account = store.addTrackedAccount(provider: .codex)

        XCTAssertEqual(account.label, "Codex Account 5")
        XCTAssertEqual(account.provider, .codex)
        XCTAssertEqual(account.isConnected, false)
        XCTAssertEqual(store.trackedAccounts.count, 6)
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
            initialSnapshot: CorporateUsageStore.demoSnapshot,
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
            initialSnapshot: CorporateUsageStore.demoSnapshot,
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
            initialSnapshot: CorporateUsageStore.demoSnapshot,
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
            initialSnapshot: CorporateUsageStore.demoSnapshot,
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
            initialSnapshot: CorporateUsageStore.demoSnapshot,
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
            initialSnapshot: CorporateUsageStore.demoSnapshot,
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
            initialSnapshot: CorporateUsageStore.demoSnapshot
        )
    }

    private func totalCapacity(
        in store: CorporateUsageStore,
        provider: AIProvider
    ) -> Int {
        store.members.reduce(0) {
            $0 + $1.usage(for: provider).allocatedCapacity
        }
    }
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
