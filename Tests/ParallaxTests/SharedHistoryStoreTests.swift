import XCTest
@testable import Parallax

final class SharedHistoryStoreTests: XCTestCase {
    private func group(application: UUID = UUID(), profiles: [UUID] = [UUID(), UUID()]) -> SharedHistoryGroup {
        SharedHistoryGroup(applicationStorageID: application, provider: "claude", profileStorageIDs: profiles,
            rootPaths: Dictionary(uniqueKeysWithValues: Set(profiles).map { ($0.uuidString, "/synthetic/" + $0.uuidString) }))
    }
    private func fixture() throws -> (URL, SharedHistoryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SharedHistory-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, try SharedHistoryStore(applicationSupportURL: root))
    }

    func testMembershipPersistsAndStaleWritersCannotOverwriteOrDisconnectIt() throws {
        let (root, store) = try fixture()
        let group = group()
        XCTAssertEqual(try store.groups(), [])
        try store.replace(nil, with: group)
        let second = try SharedHistoryStore(applicationSupportURL: root)
        XCTAssertEqual(try second.groups(), [group])
        var update = group
        update.knownConversationIDs = ["saved-chat"]
        update.baselines = ["saved-chat": SharedHistoryBaseline(Data("saved".utf8))]
        try store.replace(group, with: update)
        XCTAssertThrowsError(try second.replace(group, with: nil)) { XCTAssertEqual($0 as? SharedHistoryError, .changed) }
        XCTAssertEqual(try second.groups(), [update])
        try second.replace(update, with: nil)
        XCTAssertEqual(try store.groups(), [])
    }

    func testAllAccountSettingIsPersistentScopedAndRejectsStaleChanges() throws {
        let (root, store) = try fixture()
        let app = UUID()
        let path = root.appendingPathComponent("Parallax/shared-history.json")
        XCTAssertFalse(try store.includesAllAccounts(applicationID: app))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        try store.setIncludesAllAccounts(true, applicationID: app, expected: false)
        let saved = try Data(contentsOf: path)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: saved) as? [String: Any])?["schemaVersion"] as? Int, 3)
        let restarted = try SharedHistoryStore(applicationSupportURL: root)
        XCTAssertTrue(try restarted.includesAllAccounts(applicationID: app))
        XCTAssertFalse(try restarted.includesAllAccounts(applicationID: UUID()))
        try restarted.setIncludesAllAccounts(true, applicationID: app, expected: true)
        XCTAssertEqual(try Data(contentsOf: path), saved)
        XCTAssertThrowsError(try store.setIncludesAllAccounts(false, applicationID: app, expected: false)) {
            XCTAssertEqual($0 as? SharedHistoryError, .changed)
        }
        XCTAssertEqual(try Data(contentsOf: path), saved)
    }

    func testAutomaticPublicationRequiresPolicyAndDisconnectClearsIt() throws {
        let (_, store) = try fixture()
        let original = group()
        let app = original.applicationStorageID
        try store.setIncludesAllAccounts(true, applicationID: app, expected: false)
        try store.replace(nil, with: original, requiringAllAccountsFor: app)
        XCTAssertTrue(try store.includesAllAccounts(applicationID: app))
        try store.setIncludesAllAccounts(false, applicationID: app, expected: true)
        XCTAssertEqual(try store.groups(), [original])
        XCTAssertThrowsError(try store.replace(original, with: original, requiringAllAccountsFor: app)) {
            XCTAssertEqual($0 as? SharedHistoryError, .changed)
        }
        try store.setIncludesAllAccounts(true, applicationID: app, expected: false)
        try store.replace(original, with: nil)
        XCTAssertFalse(try store.includesAllAccounts(applicationID: app))
        XCTAssertEqual(try store.groups(), [])
    }

    func testSeparateGroupsCannotBeSilentlyMergedByTheSetting() throws {
        let (root, store) = try fixture()
        let app = UUID()
        try store.replace(nil, with: group(application: app))
        try store.replace(nil, with: group(application: app))
        let path = root.appendingPathComponent("Parallax/shared-history.json")
        let saved = try Data(contentsOf: path)
        XCTAssertThrowsError(try store.setIncludesAllAccounts(true, applicationID: app, expected: false)) {
            XCTAssertEqual($0 as? AllAccountHistoryError, .multipleLibraries)
        }
        XCTAssertEqual(try Data(contentsOf: path), saved)
        XCTAssertFalse(try store.includesAllAccounts(applicationID: app))
    }

    func testLegacyReceiptsStayUntouchedUntilPolicyMigration() throws {
        let (root, store) = try fixture()
        let original = group()
        try store.replace(nil, with: original)
        let path = root.appendingPathComponent("Parallax/shared-history.json")
        let saved = try Data(contentsOf: path)
        XCTAssertFalse(try store.includesAllAccounts(applicationID: original.applicationStorageID))
        XCTAssertEqual(try Data(contentsOf: path), saved)
        try store.setIncludesAllAccounts(true, applicationID: original.applicationStorageID, expected: false)
        let backup = root.appendingPathComponent("Parallax/shared-history-v1-\(LibraryPersistence.sha256(saved)).json")
        XCTAssertEqual(try Data(contentsOf: backup), saved)
        XCTAssertEqual(try store.groups(), [original])
    }

    func testPolicyInLegacySchemaAndFutureReceiptsBlockAllWrites() throws {
        let (root, store) = try fixture()
        let path = root.appendingPathComponent("Parallax/shared-history.json")
        for schema in [1, 2, 4] {
            let saved = try JSONSerialization.data(withJSONObject: ["schemaVersion": schema, "groups": [],
                "allAccountApplicationIDs": [UUID().uuidString]])
            try saved.write(to: path)
            XCTAssertThrowsError(try store.includesAllAccounts(applicationID: UUID()))
            XCTAssertThrowsError(try store.setIncludesAllAccounts(true, applicationID: UUID(), expected: false))
            XCTAssertEqual(try Data(contentsOf: path), saved)
        }
    }

    func testMembershipRejectsOverlapsAndDuplicateOrSingleMembers() throws {
        let (_, store) = try fixture()
        let application = UUID(), profile = UUID()
        let group = group(application: application, profiles: [profile, UUID()])
        try store.replace(nil, with: group)
        for members in [[profile, UUID()], [UUID()], [profile, profile]] {
            XCTAssertThrowsError(try store.replace(nil, with: SharedHistoryGroup(
                applicationStorageID: application, provider: "codex", profileStorageIDs: members)))
        }
        XCTAssertEqual(try store.groups(), [group])
    }

    func testCorruptOrFutureReceiptsArePreservedAndBlockMutation() throws {
        let (root, store) = try fixture()
        let path = root.appendingPathComponent("Parallax/shared-history.json")
        for text in ["{", "{\"schemaVersion\":9,\"groups\":[]}"] {
            let data = Data(text.utf8)
            try data.write(to: path)
            XCTAssertThrowsError(try store.groups())
            XCTAssertThrowsError(try store.replace(nil, with: nil))
            XCTAssertEqual(try Data(contentsOf: path), data)
        }
    }

    func testLargeReceiptsAndConversationBaselinesHaveNoSizeOrCountCap() throws {
        let (root, store) = try fixture()
        var group = group()
        let baselineJSON = "{\"byteCount\":1073741824,\"digest\":\"\(String(repeating: "a", count: 64))\"}"
        let baseline = try JSONDecoder().decode(SharedHistoryBaseline.self, from: Data(baselineJSON.utf8))
        for index in 0..<25_000 {
            let id = "local_" + UUID().uuidString.lowercased() + "-\(index)"
            group.knownConversationIDs.insert(id)
            group.baselines[id] = baseline
        }
        try store.replace(nil, with: group)
        let bytes = try Data(contentsOf: root.appendingPathComponent("Parallax/shared-history.json"))
        XCTAssertGreaterThan(bytes.count, 4 * 1_024 * 1_024)
        XCTAssertEqual(try store.groups(), [group])
    }

    func testReceiptSymlinkNeverWritesOutsideTrustedContainer() throws {
        let (root, store) = try fixture()
        let sentinel = root.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Parallax/shared-history.json"), withDestinationURL: sentinel)
        XCTAssertThrowsError(try store.replace(nil, with: nil))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
    }

    func testMalformedOrUnboundValidationCacheCannotBePersisted() throws {
        let (_, store) = try fixture()
        let original = group()
        try store.replace(nil, with: original)
        for invalid in [[:], ["unknown-space": [:]]] as [[String: [String: SharedHistoryValidation]]] {
            var changed = original
            changed.claudeValidation = invalid
            XCTAssertThrowsError(try store.replace(original, with: changed))
            XCTAssertEqual(try store.groups(), [original])
        }
    }

    func testOversizedOptionalCacheFallsBackWithoutLosingHistoryBaselines() throws {
        let (_, store) = try fixture()
        let original = group()
        try store.replace(nil, with: original)
        var updated = original
        let baseline = SharedHistoryBaseline(Data("saved".utf8))
        updated.knownConversationIDs = ["chat"]
        updated.baselines = ["chat": baseline]
        let entry = SharedHistoryValidation(recordPath: ["chat.json"], recordDigest: baseline.digest,
            transcriptPath: [String(repeating: "x", count: 3 * 1_024 * 1_024)],
            transcriptDigest: baseline.digest, baseline: baseline)
        updated.claudeValidation = Dictionary(uniqueKeysWithValues: original.profileStorageIDs.map {
            ($0.uuidString, ["chat": entry])
        })
        let fitted = try store.fittingValidationCache(updated, replacing: original)
        XCTAssertNil(fitted.claudeValidation)
        XCTAssertEqual(fitted.baselines, updated.baselines)
        XCTAssertEqual(fitted.knownConversationIDs, updated.knownConversationIDs)
        try store.replace(original, with: fitted)
        XCTAssertEqual(try store.groups(), [fitted])
    }
}
