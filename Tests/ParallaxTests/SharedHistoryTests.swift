import XCTest
@testable import Parallax

final class SharedHistoryTests: XCTestCase {
    private func fixture() throws -> (ClaudeConversationFixture, [SharedHistoryParticipant]) {
        let fixture = try ClaudeConversationFixture()
        let root = fixture.root
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        // The destination is signed in, but has no conversation yet.
        try FileManager.default.removeItem(at: fixture.destinationRecordURL)
        return (fixture, [
            SharedHistoryParticipant(storageID: UUID(), files: fixture.source.files, provider: "claude"),
            SharedHistoryParticipant(storageID: UUID(), files: fixture.destination.files, provider: "claude"),
        ])
    }

    func testClaudeRoundTripKeepsIDsAndTitleAndDoesNotCopyAccountOrPermissionState() throws {
        let (fixture, members) = try fixture()
        let originalTranscript = try Data(contentsOf: fixture.sourceTranscriptURL)
        let originalCredentials = try Data(contentsOf: fixture.destinationRoot.appendingPathComponent("UserData/config.json"))
        let ids = try SharedHistoryService.synchronize(members, knownIDs: [])
        let id = try XCTUnwrap(ids.first)
        XCTAssertEqual(ids.count, 1)
        let first = try XCTUnwrap(SharedHistoryService.catalog(members[1])[id])
        XCTAssertEqual(first.claude?.title, "Synthetic conversation")
        XCTAssertEqual(first.claude?.cliSessionID, fixture.cliID)
        let record = try Data(contentsOf: fixture.destinationRecordURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: record) as? [String: Any])
        for key in ["spawnSeed", "emailAddress", "permissionMode", "sessionPermissionUpdates", "remoteMcpServersConfig"] {
            XCTAssertNil(object[key])
        }
        let message: [String: Any] = ["type": "user", "cwd": fixture.project.path,
            "uuid": "new-message", "message": ["role": "user", "content": "Continue with second account"]]
        var continued = first.original
        continued.append(try JSONSerialization.data(withJSONObject: message)); continued.append(10)
        try continued.write(to: fixture.destinationRoot.appendingPathComponent(first.path.components.joined(separator: "/")))
        XCTAssertEqual(try SharedHistoryService.synchronize(members, knownIDs: ids), ids)
        let back = try XCTUnwrap(SharedHistoryService.catalog(members[0])[id])
        XCTAssertEqual(back.normalized, try SharedHistoryService.catalog(members[1])[id]?.normalized)
        XCTAssertTrue(String(decoding: back.normalized, as: UTF8.self).contains("Continue with second account"))
        // Repeating a switch creates neither a second chat nor a new recovery file.
        let recovery = fixture.sourceRoot.appendingPathComponent(".parallax-history-recovery")
        let retained = try FileManager.default.contentsOfDirectory(atPath: recovery.path)
        XCTAssertEqual(retained.count, 1)
        _ = try SharedHistoryService.synchronize(members, knownIDs: ids)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: recovery.path), retained)
        XCTAssertEqual(try fixture.source.catalog().conversations.count, 1)
        XCTAssertEqual(try fixture.destination.catalog().conversations.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationRoot.appendingPathComponent("UserData/config.json")), originalCredentials)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceTranscriptURL),
            originalTranscript) // Original transcript remains native until import confirmation.
    }

    func testDivergentMessagesFailBeforePublishingAnything() throws {
        let (fixture, members) = try fixture()
        let ids = try SharedHistoryService.synchronize(members, knownIDs: [])
        for (index, member) in members.enumerated() {
            let conversation = try XCTUnwrap(SharedHistoryService.catalog(member).values.first)
            var data = conversation.original
            data.append(try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": fixture.project.path,
                "message": ["content": "different branch \(index)"]]))
            data.append(10)
            try data.write(to: URL(fileURLWithPath: member.files.rootPath).appendingPathComponent(conversation.path.components.joined(separator: "/")))
        }
        let before = try members.map(SharedHistoryService.catalog)
        XCTAssertThrowsError(try SharedHistoryService.synchronize(members, knownIDs: ids)) {
            XCTAssertEqual($0 as? SharedHistoryError, .conflict)
        }
        XCTAssertEqual(try members.map(SharedHistoryService.catalog), before)
    }

    func testTruncatingPreviouslySharedMessagesIsNotSilentlyRestored() throws {
        let (fixture, members) = try fixture()
        let ids = try SharedHistoryService.synchronize(members, knownIDs: [])
        let snapshot = try SharedHistoryService.catalog(members[0])
        let baselines = snapshot.mapValues { SharedHistoryBaseline($0.normalized) }
        try fixture.writeTranscript([fixture.messages[0]], to: fixture.sourceTranscriptURL)
        XCTAssertThrowsError(try SharedHistoryService.synchronize(members, knownIDs: ids, baselines: baselines)) {
            XCTAssertEqual($0 as? SharedHistoryError, .conflict)
        }
        XCTAssertNotEqual(try SharedHistoryService.catalog(members[0]), snapshot)
    }

    func testLargeCombinedHistorySynchronizesWithoutMaterializingTheWholeGroup() throws {
        let (fixture, initial) = try fixture()
        var messages = fixture.messages
        for index in messages.indices {
            messages[index]["message"] = ["content": String(repeating: "x", count: 10 * 1_024 * 1_024)]
        }
        try fixture.writeTranscript(messages, to: fixture.sourceTranscriptURL)
        var members = initial
        for index in 0..<6 {
            let root = fixture.root.appendingPathComponent("linked-\(index)")
            try FileManager.default.copyItem(at: fixture.sourceRoot, to: root)
            members.append(SharedHistoryParticipant(storageID: UUID(),
                files: try SecureManagedFileSystem(rootURL: root), provider: "claude"))
        }
        let id = try fixture.conversation().sessionID
        let first = try XCTUnwrap(SharedHistoryService.snapshot(members[0])[id])
        // Seven copies of this valid history exceed the former 256 MiB group
        // limit, although each conversation is below the per-transcript bound.
        XCTAssertGreaterThan(first.baseline.byteCount * 2 * 7, SharedHistoryService.maximumTotalBytes)
        let ids = try SharedHistoryService.synchronize(members, knownIDs: [])
        XCTAssertEqual(ids, [id])
        let copied = try XCTUnwrap(SharedHistoryService.snapshot(members[1])[id])
        XCTAssertEqual(copied.baseline, first.baseline)
        XCTAssertEqual(copied.claude?.cliSessionID, fixture.cliID)
        // Persisted baselines also use the streaming scan, including on retry.
        let baselines = try SharedHistoryService.snapshot(members[1]).mapValues(\.baseline)
        XCTAssertEqual(try SharedHistoryService.synchronize(members, knownIDs: ids, baselines: baselines), ids)
    }

    func testSnapshotRejectsRecordChangesBeforeLoadingTranscript() throws {
        let (fixture, members) = try fixture()
        let snapshot = try XCTUnwrap(SharedHistoryService.snapshot(members[0]).values.first)
        var record = fixture.record
        record["cwd"] = "/different-project"
        try fixture.writeJSON(record, to: fixture.sourceRecordURL)
        XCTAssertThrowsError(try SharedHistoryService.load(snapshot, from: members[0])) {
            XCTAssertEqual($0 as? SharedHistoryError, .changed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationRecordURL.path))
    }

    func testDeletionAndArchiveAreNotResurrected() throws {
        for archive in [false, true] {
            let (fixture, members) = try fixture()
            let ids = try SharedHistoryService.synchronize(members, knownIDs: [])
            if archive {
                var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.destinationRecordURL)) as? [String: Any])
                record["isArchived"] = true
                try fixture.writeJSON(record, to: fixture.destinationRecordURL)
            } else { try FileManager.default.removeItem(at: fixture.destinationRecordURL) }
            XCTAssertThrowsError(try SharedHistoryService.synchronize(members, knownIDs: ids)) {
                XCTAssertEqual($0 as? SharedHistoryError, .removed)
            }
        }
    }

    func testChangedSourceAfterPlanningFailsWithoutDestinationRecord() throws {
        let (fixture, members) = try fixture()
        XCTAssertThrowsError(try SharedHistoryService.synchronize(members, knownIDs: [], beforePublication: {
            try fixture.writeTranscript(fixture.messages + [["type": "user", "cwd": fixture.project.path]], to: fixture.sourceTranscriptURL)
        })) { XCTAssertEqual($0 as? SharedHistoryError, .changed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationRecordURL.path))
    }

    func testUnsupportedAndAmbiguousClaudeHistoriesFailClosed() throws {
        let (fixture, members) = try fixture()
        try Data("{}".utf8).write(to: fixture.sourceRecordURL)
        XCTAssertThrowsError(try SharedHistoryService.synchronize(members, knownIDs: [])) {
            XCTAssertEqual($0 as? SharedHistoryError, .unavailable)
        }
        try fixture.writeJSON(fixture.record, to: fixture.sourceRecordURL)
        let other = fixture.destinationRoot.appendingPathComponent("UserData/claude-code-sessions/55555555-5555-4555-8555-555555555555/66666666-6666-4666-8666-666666666666")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SharedHistoryService.synchronize(members, knownIDs: [])) {
            XCTAssertEqual($0 as? ClaudeConversationCopyError, .ambiguousAccount)
        }
    }

    func testDuplicateRootsAndMixedProvidersCannotShare() throws {
        let (_, members) = try fixture()
        XCTAssertThrowsError(try SharedHistoryService.synchronize([members[0], members[0]], knownIDs: []))
        XCTAssertThrowsError(try SharedHistoryService.synchronize([members[0],
            SharedHistoryParticipant(storageID: UUID(), files: members[1].files, provider: "codex")], knownIDs: []))
    }

    func testHistoryReplacementRetainsOldBytesAndRejectsStaleOrUnsafeTargets() throws {
        let (fixture, _) = try fixture()
        let files = fixture.source.files
        let path = try SecureManagedPath(["value.jsonl"])
        try files.write(Data("old".utf8), to: path)
        try files.replaceHistoryFile(at: path, expected: Data("old".utf8), with: Data("new".utf8))
        XCTAssertEqual(try files.readFile(at: path, maximumBytes: 10), Data("new".utf8))
        let recovery = try SecureManagedPath([".parallax-history-recovery"])
        let retained = try XCTUnwrap(files.directoryNames(at: recovery).first)
        XCTAssertEqual(try files.readFile(at: recovery.appending(retained), maximumBytes: 10), Data("old".utf8))
        XCTAssertThrowsError(try files.replaceHistoryFile(at: path, expected: Data("old".utf8), with: Data()))
        XCTAssertThrowsError(try files.replaceHistoryFile(at: path, expected: nil, with: Data()))
        let link = fixture.sourceRoot.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.sourceRoot.appendingPathComponent("value.jsonl"))
        XCTAssertThrowsError(try files.replaceHistoryFile(at: SecureManagedPath(["link"]), expected: Data("new".utf8), with: Data()))
    }

    func testInterruptedReplacementPreservesBothVersionsAndRetryIsIdempotent() throws {
        let (fixture, _) = try fixture()
        let path = try SecureManagedPath(["value"])
        try fixture.source.files.write(Data("old".utf8), to: path)
        let files = try SecureManagedFileSystem(rootURL: fixture.sourceRoot, boundaryHook: { boundary in
            if boundary == .afterRename { throw SharedHistoryError.changed }
        })
        XCTAssertThrowsError(try files.replaceHistoryFile(at: path, expected: Data("old".utf8), with: Data("new".utf8)))
        XCTAssertEqual(try files.readFile(at: path, maximumBytes: 10), Data("new".utf8))
        try fixture.source.files.replaceHistoryFile(at: path, expected: Data("new".utf8), with: Data("new".utf8))
        XCTAssertEqual(try files.directoryNames(at: SecureManagedPath([".parallax-history-recovery"])).count, 1)
    }

    func testHistoryReplacementDetectsTargetSwapAtPublicationBoundary() throws {
        let (fixture, _) = try fixture()
        let path = try SecureManagedPath(["value"])
        let url = fixture.sourceRoot.appendingPathComponent("value")
        try fixture.source.files.write(Data("old".utf8), to: path)
        let files = try SecureManagedFileSystem(rootURL: fixture.sourceRoot, boundaryHook: { boundary in
            if boundary == .beforeRename { try Data("unexpected".utf8).write(to: url, options: .atomic) }
        })
        XCTAssertThrowsError(try files.replaceHistoryFile(at: path, expected: Data("old".utf8), with: Data("new".utf8)))
        XCTAssertEqual(try Data(contentsOf: url), Data("unexpected".utf8))
    }
}
