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
