import Foundation
import XCTest
@testable import Parallax

final class AuditRegressionTests: XCTestCase {
    func testStagedTranscriptPublicationRepairsOnlyAnExactPrefix() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AuditHistory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try SecureManagedFileSystem(rootURL: root)
        let bytes = Data("{\"message\":\"complete transcript\"}\n".utf8)
        for prefixLength in [0, 9, bytes.count] {
            let path = try SecureManagedPath(["transcript-\(prefixLength).jsonl"])
            try files.write(Data(bytes.prefix(prefixLength)), to: path)
            XCTAssertTrue(try files.publishStagedHistoryFile(bytes, at: path))
            XCTAssertEqual(try files.readFile(at: path), bytes)
        }
        let missing = try SecureManagedPath(["missing.jsonl"])
        XCTAssertTrue(try files.publishStagedHistoryFile(bytes, at: missing))
        XCTAssertEqual(try files.readFile(at: missing), bytes)
        let conflicting = try SecureManagedPath(["conflict.jsonl"])
        try files.write(Data("foreign".utf8), to: conflicting)
        XCTAssertFalse(try files.publishStagedHistoryFile(bytes, at: conflicting))
        XCTAssertEqual(try files.readFile(at: conflicting), Data("foreign".utf8))
    }

    func testTranscriptJSONRepairsLoneSurrogatesWithoutChangingValidEscapes() throws {
        for (input, expected) in [
            (#"{"text":"\ud83d"}"#, "�"),
            (#"{"text":"\udc00"}"#, "�"),
            (#"{"text":"\ud83d\ude00"}"#, "😀"),
            (#"{"text":"\\ud83d"}"#, #"\ud83d"#)
        ] {
            let result = try XCTUnwrap(ClaudeConversationCopyService.transcriptJSONObject(Data(input.utf8)) as? [String: String])
            XCTAssertEqual(result["text"], expected)
        }
        for input in [#"{"text":"\ud83d\ude00"}"#, #"{"text":"\\ud83d"}"#] {
            XCTAssertNil(ClaudeConversationCopyService.replacingLoneSurrogateEscapes(in: Data(input.utf8)))
        }
        for input in [#"{"text":"\ud83d" broken}"#, #"{"text":"\ud83d""#, #"{"text":"\q"}"#] {
            XCTAssertThrowsError(try ClaudeConversationCopyService.transcriptJSONObject(Data(input.utf8)))
        }
    }

    @MainActor
    func testUnreadableAccountInventoryRemainsReadOnlyThroughEverySavePath() throws {
        let suite = "AuditInventory-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = Data(#"{"trackedAccounts":[{"newerBuildField":true}]}"#.utf8)
        defaults.set(original, forKey: "inventory")
        let store = CorporateUsageStore(userDefaults: defaults, persistenceKey: "inventory")
        XCTAssertNotNil(store.persistenceErrorMessage)
        var account = try XCTUnwrap(store.trackedAccounts.first)
        account.label = "Must not persist"
        XCTAssertFalse(store.saveTrackedAccount(account))
        store.discardFailedUserSave(accountID: account.id)
        XCTAssertNotNil(store.persistenceErrorMessage)
        XCTAssertNil(store.recordRefreshAttempt(accountID: account.id, kind: .refresh))
        store.removeTrackedAccount(id: account.id)
        XCTAssertEqual(defaults.data(forKey: "inventory"), original)
        XCTAssertEqual(defaults.data(forKey: CorporateUsageStore.undecodableBackupKey(for: "inventory")), original)
        XCTAssertNotNil(store.persistenceErrorMessage)
    }

    @MainActor
    func testInterruptedAccountRefreshIsDueDespiteRecentAttemptAndSuccess() throws {
        let suite = "AuditRefresh-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var account = try XCTUnwrap(CorporateUsageStore.defaultTrackedAccounts.first)
        account.isConnected = true
        account.lastRefreshAttemptAt = now
        account.lastSuccessfulRefreshAt = now
        let store = CorporateUsageStore(userDefaults: defaults, initialAccounts: [account], clock: { now })
        let coordinator = CorporateAccountOperationCoordinator(store: store, service: ControlledCorporateAccountOperationService())
        XCTAssertFalse(coordinator.isDue(account, now: now))
        account.lastRefreshFailure = .interrupted
        XCTAssertTrue(coordinator.isDue(account, now: now))
        account.isConnected = false
        XCTAssertFalse(coordinator.isDue(account, now: now))
    }

    func testRelocationRoundsEachFileUpToAllocationBlock() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("SmallFiles")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in [0, 1, 4_096, 4_097] {
            let url = directory.appendingPathComponent(String(size))
            try Data(repeating: 65, count: size).write(to: url)
            XCTAssertEqual(try fixture.coordinator.estimate(at: url).allocatedBytes,
                size == 0 ? 0 : size <= 4_096 ? 4_096 : 8_192)
        }
        XCTAssertEqual(try fixture.coordinator.estimate(at: directory).allocatedBytes, 16_384)
    }
}
