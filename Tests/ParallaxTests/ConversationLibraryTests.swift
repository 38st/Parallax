import XCTest
@testable import Parallax

final class ConversationLibraryTests: XCTestCase {
    private func fixture() throws -> (ClaudeConversationFixture, ConversationLibraryStore, [SharedHistoryParticipant], ConversationLibrary) {
        let fixture = try ClaudeConversationFixture()
        let root = fixture.root
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: fixture.destinationRecordURL)
        let support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let store = try ConversationLibraryStore(applicationSupportURL: support, id: UUID(), create: true)
        let participants = [SharedHistoryParticipant(storageID: UUID(), files: fixture.source.files, provider: "claude"),
                            SharedHistoryParticipant(storageID: UUID(), files: fixture.destination.files, provider: "claude")]
        let bindings = try participants.enumerated().map { index, participant in
            try ConversationLibraryClaudeAdapter.bind(profileID: participant.storageID, label: "Account \(index)",
                namespace: fixture.namespace.components, files: participant.files)
        }
        let library = try ConversationLibraryService.enroll(store: store, applicationID: UUID(), bindings: bindings, participants: participants)
        return (fixture, store, participants, library)
    }

    private func switchTo(_ index: Int, store: ConversationLibraryStore, participants: [SharedHistoryParticipant],
                          selected: String? = nil) throws -> ConversationLibrary {
        let target = participants[index].storageID
        let prepared = try ConversationLibraryService.prepare(store: store, targetID: target, selectedID: selected, participants: participants)
        let request = try XCTUnwrap(prepared.handoff?.id)
        try ConversationLibraryService.markOpening(store: store, targetID: target, requestID: request)
        try ConversationLibraryService.completeOpening(store: store, targetID: target, requestID: request)
        return try XCTUnwrap(store.read())
    }

    private func append(_ text: String, fixture: ClaudeConversationFixture, participant: SharedHistoryParticipant) throws {
        let service = ClaudeConversationCopyService(files: participant.files)
        let conversation = try XCTUnwrap(service.catalog().conversations.first)
        let path = try service.transcriptPath(for: conversation)
        var data = try participant.files.readFile(at: path)
        data.append(try JSONSerialization.data(withJSONObject: ["type": "user", "cwd": fixture.project.path,
            "uuid": UUID().uuidString, "message": ["role": "user", "content": text]]))
        data.append(10)
        try data.write(to: URL(fileURLWithPath: participant.files.rootPath).appendingPathComponent(path.components.joined(separator: "/")))
    }

    func testRoundTripUsesOneConversationAndPreservesCredentialsAndOriginalHistory() throws {
        let (fixture, store, participants, initial) = try fixture()
        let id = try XCTUnwrap(initial.conversations.keys.first)
        let original = try Data(contentsOf: fixture.sourceTranscriptURL)
        _ = try switchTo(1, store: store, participants: participants, selected: id)
        try append("From second account", fixture: fixture, participant: participants[1])
        let back = try switchTo(0, store: store, participants: participants, selected: id)
        XCTAssertEqual(back.conversations.count, 1)
        let conversation = try XCTUnwrap(back.conversations[id])
        XCTAssertEqual(conversation.revisions.count, 2)
        XCTAssertTrue(String(decoding: try store.blob(conversation.head), as: UTF8.self).contains("From second account"))
        XCTAssertEqual(try Data(contentsOf: fixture.sourceTranscriptURL), original)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationRoot.appendingPathComponent("UserData/config.json")),
            Data("destination credentials sentinel".utf8))
        let native = try Data(contentsOf: fixture.sourceRecordURL)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: native) as? [String: Any])
        XCTAssertNil(object["permissionMode"])
        XCTAssertNil(object["spawnSeed"])
        let libraryBytes = try Data(contentsOf: URL(fileURLWithPath: store.files.rootPath).appendingPathComponent("library.json"))
        XCTAssertFalse(String(decoding: libraryBytes, as: UTF8.self).contains("source-secret"))
        for name in try FileManager.default.contentsOfDirectory(atPath: store.files.rootPath) where name.hasSuffix(".jsonl") {
            XCTAssertFalse(String(decoding: try Data(contentsOf: URL(fileURLWithPath: store.files.rootPath).appendingPathComponent(name)), as: UTF8.self).contains("source-secret"))
        }
        let repeated = try switchTo(1, store: store, participants: participants, selected: id)
        XCTAssertEqual(repeated.conversations[id]?.revisions, conversation.revisions)
    }

    private func changingBinding(_ binding: ConversationAccountBinding,
                                 values: [String: Any], removing: [String] = []) throws -> ConversationAccountBinding {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as? [String: Any])
        for (key, value) in values { object[key] = value }
        for key in removing { object.removeValue(forKey: key) }
        return try JSONDecoder().decode(ConversationAccountBinding.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    func testRemountedVolumeSurvivesLibraryReloadAndRepeatedSwitches() throws {
        let (_, store, participants, initial) = try fixture()
        for binding in initial.bindings.values {
            XCTAssertNotNil(binding.rootVolumeUUID)
            let remounted = try changingBinding(binding, values: ["rootVolumeID": binding.rootVolumeID + 1])
            XCTAssertTrue(binding.hasSameStorage(as: remounted))
            try store.transaction { $0?.bindings[binding.profileStorageID.uuidString] = remounted }
        }
        // New descriptors and a new catalog reader model reopening Parallax.
        let reopened = try ConversationLibraryStore(applicationSupportURL:
            URL(fileURLWithPath: store.files.rootPath).deletingLastPathComponent().deletingLastPathComponent(), id: store.id)
        let fresh = try participants.map {
            SharedHistoryParticipant(storageID: $0.storageID,
                files: try SecureManagedFileSystem(rootURL: URL(fileURLWithPath: $0.files.rootPath)), provider: "claude")
        }
        _ = try switchTo(1, store: reopened, participants: fresh)
        _ = try switchTo(0, store: reopened, participants: fresh)
        _ = try switchTo(0, store: reopened, participants: fresh)
        XCTAssertEqual(try reopened.read()?.conversations.count, initial.conversations.count)
    }

    func testVolumeMismatchAndReplacedFoldersStillRequireReview() throws {
        let (_, _, participants, initial) = try fixture()
        let participant = participants[0]
        let binding = try XCTUnwrap(initial.bindings[participant.storageID.uuidString])
        for values: [String: Any] in [
            ["rootVolumeUUID": UUID().uuidString],
            ["rootFileID": binding.rootFileID + 1],
            ["namespaceFileID": binding.namespaceFileID + 1]
        ] {
            let changed = try changingBinding(binding, values: values)
            XCTAssertFalse(binding.hasSameStorage(as: changed))
            XCTAssertThrowsError(try ConversationLibraryClaudeAdapter.validate(changed, files: participant.files)) {
                XCTAssertEqual($0 as? ConversationLibraryError, .accountChanged)
            }
        }
        XCTAssertFalse(binding.matchesVolume(StorageVolumeIdentity(device: binding.rootVolumeID,
            inode: binding.rootFileID, volumeUUID: nil)))
    }

    func testLegacyBindingsDecodeAndRequireReviewAfterDeviceChange() throws {
        let (_, _, participants, initial) = try fixture()
        let participant = participants[0]
        let binding = try XCTUnwrap(initial.bindings[participant.storageID.uuidString])
        let legacy = try changingBinding(binding, values: [:], removing: ["rootVolumeUUID"])
        XCTAssertNil(legacy.rootVolumeUUID)
        XCTAssertNoThrow(try ConversationLibraryClaudeAdapter.validate(legacy, files: participant.files))
        let stale = try changingBinding(legacy, values: ["rootVolumeID": legacy.rootVolumeID + 1])
        XCTAssertThrowsError(try ConversationLibraryClaudeAdapter.validate(stale, files: participant.files)) {
            XCTAssertEqual($0 as? ConversationLibraryError, .accountChanged)
        }
    }

    func testExtraSchedulingFoldersDoNotInvalidateExplicitBindingButForeignChatsDo() throws {
        let (fixture, store, participants, _) = try fixture()
        let extra = fixture.destinationRoot.appendingPathComponent("UserData/claude-code-sessions/\(UUID())/\(UUID())")
        try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: extra.appendingPathComponent("scheduled-tasks.json"))
        _ = try switchTo(1, store: store, participants: participants)
        try fixture.writeJSON(fixture.record, to: extra.appendingPathComponent(fixture.sourceRecordURL.lastPathComponent))
        XCTAssertThrowsError(try ConversationLibraryService.prepare(store: store, targetID: participants[0].storageID,
            selectedID: nil, participants: participants)) { XCTAssertEqual($0 as? ConversationLibraryError, .accountChanged) }
    }

    func testMissingChatDoesNotBlockOtherAccountAndRequiresExplicitRestoration() throws {
        let (fixture, store, participants, initial) = try fixture()
        let id = try XCTUnwrap(initial.conversations.keys.first)
        _ = try switchTo(1, store: store, participants: participants)
        try FileManager.default.removeItem(at: fixture.destinationRecordURL)
        let back = try switchTo(0, store: store, participants: participants, selected: id)
        XCTAssertEqual(back.conversations[id]?.problems[participants[1].storageID.uuidString], .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationRecordURL.path))
        _ = try switchTo(1, store: store, participants: participants)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationRecordURL.path))
        let head = try XCTUnwrap(back.conversations[id]?.head)
        try ConversationLibraryService.chooseRevision(store: store, conversationID: id, revisionID: head,
            restoringTo: participants[1].storageID)
        _ = try switchTo(1, store: store, participants: participants, selected: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.destinationRecordURL.path))
    }

    func testConflictsRetainBothVersionsAndAnExplicitChoiceSurvivesCapture() throws {
        let (fixture, store, participants, initial) = try fixture()
        let id = try XCTUnwrap(initial.conversations.keys.first)
        _ = try switchTo(1, store: store, participants: participants)
        try append("First branch", fixture: fixture, participant: participants[0])
        try append("Second branch", fixture: fixture, participant: participants[1])
        XCTAssertThrowsError(try ConversationLibraryService.prepare(store: store, targetID: participants[0].storageID,
            selectedID: id, participants: participants)) { XCTAssertEqual($0 as? ConversationLibraryError, .selectedConversation) }
        let captured = try XCTUnwrap(store.read()?.conversations[id])
        XCTAssertEqual(captured.revisions.count, 3)
        XCTAssertTrue(captured.problems.values.contains(.conflict))
        try ConversationLibraryService.recover(store: store)
        _ = try switchTo(0, store: store, participants: participants)
        try ConversationLibraryService.chooseRevision(store: store, conversationID: id, revisionID: captured.head, restoringTo: nil)
        let resolved = try switchTo(0, store: store, participants: participants, selected: id)
        XCTAssertEqual(resolved.conversations[id]?.head, captured.head)
        XCTAssertEqual(resolved.conversations[id]?.problems, [:])
    }

    func testCaptureCommitsBeforeFailedPublicationAndRetryKeepsIdentity() throws {
        let (fixture, store, participants, initial) = try fixture()
        let id = try XCTUnwrap(initial.conversations.keys.first)
        _ = try switchTo(1, store: store, participants: participants)
        try append("Saved before failure", fixture: fixture, participant: participants[1])
        XCTAssertThrowsError(try ConversationLibraryService.prepare(store: store, targetID: participants[0].storageID,
            selectedID: id, participants: participants, beforePublication: { throw CocoaError(.fileWriteOutOfSpace) }))
        let captured = try XCTUnwrap(store.read())
        XCTAssertEqual(captured.handoff?.phase, .preparing)
        XCTAssertEqual(captured.conversations[id]?.revisions.count, 2)
        XCTAssertThrowsError(try ConversationLibraryService.prepare(store: store, targetID: participants[1].storageID,
            selectedID: id, participants: participants)) { XCTAssertEqual($0 as? ConversationLibraryError, .busy) }
        let retried = try switchTo(0, store: store, participants: participants, selected: id)
        XCTAssertNil(retried.handoff)
        XCTAssertEqual(retried.conversations[id]?.head, captured.conversations[id]?.head)
    }

    func testWrongLaunchReceiptCannotFinishHandoff() throws {
        let (_, store, participants, _) = try fixture()
        let target = participants[1].storageID
        let prepared = try ConversationLibraryService.prepare(store: store, targetID: target, selectedID: nil, participants: participants)
        let request = try XCTUnwrap(prepared.handoff?.id)
        try ConversationLibraryService.markOpening(store: store, targetID: target, requestID: request)
        XCTAssertThrowsError(try ConversationLibraryService.completeOpening(store: store, targetID: target, requestID: UUID()))
        XCTAssertNil(try store.read()?.activeProfileID)
        try ConversationLibraryService.completeOpening(store: store, targetID: target, requestID: request)
        XCTAssertEqual(try store.read()?.activeProfileID, target)
    }

    func testMalformedUnrelatedRecordDoesNotBlockValidConversation() throws {
        let (fixture, store, participants, initial) = try fixture()
        let id = try XCTUnwrap(initial.conversations.keys.first)
        let bad = fixture.sourceRecordURL.deletingLastPathComponent().appendingPathComponent("local_\(UUID()).json")
        try Data("{invalid}".utf8).write(to: bad)
        let result = try switchTo(1, store: store, participants: participants, selected: id)
        XCTAssertEqual(result.unavailableRecords[participants[0].storageID.uuidString]?.count, 1)
        XCTAssertEqual(result.conversations.count, 1)
    }

    func testCorruptBlobAndFutureCatalogAreRefusedWithoutDiscardingFiles() throws {
        let (_, store, _, library) = try fixture()
        let digest = try XCTUnwrap(library.conversations.values.first?.head)
        let blob = URL(fileURLWithPath: store.files.rootPath).appendingPathComponent(digest + ".jsonl")
        try Data("corrupt".utf8).write(to: blob)
        XCTAssertThrowsError(try store.blob(digest)) { XCTAssertEqual($0 as? ConversationLibraryError, .corrupt) }
        XCTAssertThrowsError(try store.transaction { value in value?.schemaVersion = 999 }) {
            XCTAssertEqual($0 as? ConversationLibraryError, .unsupported)
        }
        XCTAssertEqual(try store.read()?.schemaVersion, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob.path))
    }

    func testRecoveredOrReplacedRequestCannotPublish() throws {
        let (fixture, store, participants, _) = try fixture()
        let request = UUID()
        let target = participants[1].storageID
        try ConversationLibraryService.beginSwitch(store: store, targetID: target, selectedID: nil, requestID: request)
        XCTAssertThrowsError(try ConversationLibraryService.beginSwitch(store: store, targetID: target, selectedID: nil, requestID: UUID()))
        XCTAssertThrowsError(try ConversationLibraryService.prepare(store: store, targetID: target, selectedID: nil,
            participants: participants, requestID: request, beforePublication: {
                try ConversationLibraryService.recover(store: store, expectedRequestID: request)
                try ConversationLibraryService.beginSwitch(store: store, targetID: target, selectedID: nil, requestID: UUID())
            })) { XCTAssertEqual($0 as? ConversationLibraryError, .changed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationRecordURL.path))
        try ConversationLibraryService.recover(store: store)
        XCTAssertThrowsError(try ConversationLibraryService.prepare(store: store, targetID: target, selectedID: nil,
            participants: participants, requestID: request)) { XCTAssertEqual($0 as? ConversationLibraryError, .changed) }
        XCTAssertNil(try store.read()?.handoff)
    }

    func testNativeArchiveStaysLocalUntilExplicitRestore() throws {
        let (fixture, store, participants, initial) = try fixture()
        let id = try XCTUnwrap(initial.conversations.keys.first)
        _ = try switchTo(1, store: store, participants: participants)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.destinationRecordURL)) as? [String: Any])
        record["isArchived"] = true
        try fixture.writeJSON(record, to: fixture.destinationRecordURL)
        let saved = try Data(contentsOf: fixture.destinationRecordURL)
        let back = try switchTo(0, store: store, participants: participants, selected: id)
        XCTAssertEqual(back.conversations[id]?.problems[participants[1].storageID.uuidString], .archived)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationRecordURL), saved)
        XCTAssertThrowsError(try switchTo(1, store: store, participants: participants, selected: id))
        try ConversationLibraryService.recover(store: store)
        try ConversationLibraryService.chooseRevision(store: store, conversationID: id,
            revisionID: try XCTUnwrap(back.conversations[id]?.head), restoringTo: participants[1].storageID)
        _ = try switchTo(1, store: store, participants: participants, selected: id)
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.destinationRecordURL)) as? [String: Any])
        XCTAssertEqual(restored["isArchived"] as? Bool, false)
    }

    func testAnchoredCompactionIsRetainedAndCanRoundTrip() throws {
        let (fixture, store, participants, initial) = try fixture()
        let id = try XCTUnwrap(initial.conversations.keys.first)
        let head = try XCTUnwrap(initial.conversations[id]?.head)
        _ = try switchTo(0, store: store, participants: participants)
        var last: String?
        try HistoryFileBuffer.forEachLine(in: store.blob(head)) { line in
            last = (try JSONSerialization.jsonObject(with: line) as? [String: Any])?["uuid"] as? String
        }
        let records: [[String: Any]] = [
            ["type": "system", "subtype": "compact_boundary", "logicalParentUuid": try XCTUnwrap(last), "cwd": fixture.project.path],
            ["type": "user", "uuid": UUID().uuidString, "cwd": fixture.project.path, "message": ["role": "user", "content": "Summary of prior work"]]
        ]
        var compacted = Data()
        for record in records { compacted.append(try JSONSerialization.data(withJSONObject: record)); compacted.append(10) }
        try compacted.write(to: fixture.sourceTranscriptURL)
        let next = try switchTo(1, store: store, participants: participants, selected: id)
        XCTAssertEqual(next.conversations[id]?.revisions.count, 2)
        XCTAssertNotEqual(next.conversations[id]?.head, head)
        XCTAssertEqual(next.conversations[id]?.problems, [:])
        XCTAssertNotNil(try store.blob(head))
        let back = try switchTo(0, store: store, participants: participants, selected: id)
        XCTAssertEqual(back.conversations[id]?.head, next.conversations[id]?.head)
        XCTAssertFalse(try ConversationLibraryClaudeAdapter.supportedCompaction(previous: store.blob(head),
            next: Data("{\"type\":\"system\",\"subtype\":\"compact_boundary\",\"logicalParentUuid\":\"wrong\"}\n".utf8)))
    }

    func testNamespaceReplacementRequiresRebindingAndRetainsRevisionProvenance() throws {
        let (fixture, store, participants, initial) = try fixture()
        let source = participants[0]
        _ = try switchTo(0, store: store, participants: participants)
        let old = try XCTUnwrap(initial.bindings[source.storageID.uuidString])
        let namespace = fixture.sourceRecordURL.deletingLastPathComponent()
        let retained = namespace.appendingPathExtension("retained")
        try FileManager.default.moveItem(at: namespace, to: retained)
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ConversationLibraryClaudeAdapter.validate(old, files: source.files))
        let new = try ConversationLibraryClaudeAdapter.bind(profileID: source.storageID, label: old.label,
            namespace: old.namespace, files: source.files)
        let bindings = initial.bindings.values.map { $0.profileStorageID == source.storageID ? new : $0 }
        try ConversationLibraryService.rebind(store: store, bindings: bindings)
        let rebound = try XCTUnwrap(store.read())
        XCTAssertNil(rebound.activeProfileID)
        XCTAssertEqual(rebound.conversations.values.first?.revisions, initial.conversations.values.first?.revisions)
        XCTAssertEqual(rebound.conversations.values.first?.revisions.values.first?.sourceAccountID, old.namespace[2])
        XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
    }

    func testTargetChangesAfterCaptureArePreservedAndCanBeRecovered() throws {
        let (fixture, store, participants, _) = try fixture()
        let unexpected = Data("new writer".utf8)
        XCTAssertThrowsError(try ConversationLibraryService.prepare(store: store, targetID: participants[1].storageID,
            selectedID: nil, participants: participants, beforePublication: {
                try unexpected.write(to: fixture.destinationRecordURL)
            }))
        XCTAssertEqual(try Data(contentsOf: fixture.destinationRecordURL), unexpected)
        XCTAssertEqual(try store.read()?.handoff?.phase, .preparing)
        try ConversationLibraryService.recover(store: store)
        let result = try switchTo(0, store: store, participants: participants)
        XCTAssertEqual(result.conversations.count, 1)
        XCTAssertEqual(result.unavailableRecords[participants[1].storageID.uuidString]?.count, 1)
    }

    func testNoOpCaptureDoesNotRewriteCatalogAndLockedWritersPreserveUpdates() async throws {
        let (_, store, participants, initial) = try fixture()
        try store.transaction { document in
            guard var library = document else { return XCTFail("Missing library") }
            for participant in participants {
                try ConversationLibraryClaudeAdapter.capture(binding: XCTUnwrap(library.bindings[participant.storageID.uuidString]),
                    files: participant.files, library: &library, store: store)
            }
            document = library
        }
        XCTAssertEqual(try store.read(), initial)
        let id = try XCTUnwrap(initial.conversations.keys.first)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<12 {
                group.addTask {
                    try store.transaction { document in document?.conversations[id]?.title = "Update \(index)" }
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(try store.read()?.generation, initial.generation + 12)
    }

    func testPreviewUsesRecentMessageTextAndBoundsLongMessages() throws {
        var data = Data()
        for index in 0..<6 {
            let record: [String: Any] = ["type": "user", "message": ["content": [["type": "text", "text": "Message \(index) " + String(repeating: "a", count: 3_000)]]]]
            data.append(try JSONSerialization.data(withJSONObject: record)); data.append(10)
        }
        data.append(Data("{\"type\":\"assistant\",\"isSidechain\":true,\"message\":{\"content\":\"private subagent\"}}\n".utf8))
        let preview = try ConversationLibraryService.messagePreview(data)
        XCTAssertFalse(preview.contains("Message 1"))
        XCTAssertFalse(preview.contains("private subagent"))
        XCTAssertTrue(preview.contains("Message 5"))
        XCTAssertLessThanOrEqual(preview.count, 8_006)
        XCTAssertThrowsError(try ConversationLibraryService.messagePreview(Data("invalid\n".utf8)))
    }

    func testSourceChangeAfterCaptureCannotPublishAnOutdatedHandoff() throws {
        let (fixture, store, participants, _) = try fixture()
        XCTAssertThrowsError(try ConversationLibraryService.prepare(store: store, targetID: participants[1].storageID,
            selectedID: nil, participants: participants, beforePublication: {
                try self.append("Independent writer", fixture: fixture, participant: participants[0])
            })) { XCTAssertEqual($0 as? ConversationLibraryError, .changed) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destinationRecordURL.path))
        let retried = try switchTo(1, store: store, participants: participants)
        XCTAssertEqual(retried.conversations.values.first?.revisions.count, 2)
    }

    func testExplicitSavedVersionCanContinueAwayFromUnreadableSourceButDoesNotOverwriteIt() throws {
        let (fixture, store, participants, initial) = try fixture()
        let id = try XCTUnwrap(initial.conversations.keys.first)
        let head = try XCTUnwrap(initial.conversations[id]?.head)
        let broken = Data("broken transcript\n".utf8)
        try broken.write(to: fixture.sourceTranscriptURL)
        XCTAssertThrowsError(try switchTo(1, store: store, participants: participants, selected: id))
        try ConversationLibraryService.recover(store: store)
        try ConversationLibraryService.chooseRevision(store: store, conversationID: id, revisionID: head, restoringTo: participants[1].storageID)
        let recovered = try switchTo(1, store: store, participants: participants, selected: id)
        XCTAssertEqual(recovered.conversations[id]?.head, head)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceTranscriptURL), broken)
        XCTAssertThrowsError(try switchTo(0, store: store, participants: participants, selected: id))
        try ConversationLibraryService.recover(store: store)
        try Data("different broken transcript\n".utf8).write(to: fixture.sourceTranscriptURL)
        XCTAssertThrowsError(try switchTo(0, store: store, participants: participants, selected: id))
        let updated = try XCTUnwrap(store.read())
        XCTAssertNotEqual(updated.conversations[id]?.reviewedSourceFailures?[participants[0].storageID.uuidString],
            updated.unavailableRecords[participants[0].storageID.uuidString]?[id + ".json"])
        XCTAssertEqual(updated.conversations[id]?.revisions.count, 1)
    }
}

extension ConversationLibraryTests {
    func testAuditWaitingSwitchRetryAndReleaseAreRequestScoped() throws {
        let (_, store, participants, initial) = try fixture()
        let target = participants[1].storageID
        let id = UUID()
        try ConversationLibraryService.beginSwitch(store: store, targetID: target, selectedID: nil, requestID: id)
        let waiting = try store.read()
        try ConversationLibraryService.beginSwitch(store: store, targetID: target, selectedID: nil, requestID: id)
        XCTAssertEqual(try store.read(), waiting)
        XCTAssertThrowsError(try ConversationLibraryService.beginSwitch(store: store, targetID: target, selectedID: nil, requestID: UUID())) {
            XCTAssertEqual($0 as? ConversationLibraryError, .busy)
        }
        XCTAssertFalse(try ConversationLibraryService.releaseWaiting(store: store, requestID: UUID()))
        XCTAssertTrue(try ConversationLibraryService.releaseWaiting(store: store, requestID: id))
        XCTAssertNil(try store.read()?.handoff)
        XCTAssertEqual(try store.read()?.conversations, initial.conversations)
        _ = try ConversationLibraryService.prepare(store: store, targetID: target, selectedID: nil, participants: participants)
        let preparedID = try XCTUnwrap(store.read()?.handoff?.id)
        XCTAssertFalse(try ConversationLibraryService.releaseWaiting(store: store, requestID: preparedID))
        XCTAssertNotNil(try store.read()?.handoff)
    }

    func testAuditRecoveryAfterOpeningClearsActiveAccount() throws {
        let (_, store, participants, _) = try fixture()
        _ = try switchTo(0, store: store, participants: participants)
        let target = participants[1].storageID
        let prepared = try ConversationLibraryService.prepare(store: store, targetID: target, selectedID: nil, participants: participants)
        let id = try XCTUnwrap(prepared.handoff?.id)
        try ConversationLibraryService.markOpening(store: store, targetID: target, requestID: id)
        try ConversationLibraryService.recover(store: store, expectedRequestID: id)
        XCTAssertNil(try store.read()?.activeProfileID)
        XCTAssertNil(try store.read()?.handoff)
    }

    func testAuditLegacyMissingHistoryDoesNotMarkNewMemberMissing() throws {
        for previouslyMember in [false, true] {
            let (fixture, prior, participants, initial) = try fixture()
            let id = try XCTUnwrap(initial.conversations.keys.first)
            let support = fixture.root.appendingPathComponent("migration")
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let store = try ConversationLibraryStore(applicationSupportURL: support, id: UUID(), create: true)
            let migrated = try ConversationLibraryService.enroll(store: store, applicationID: initial.applicationStorageID,
                bindings: Array(initial.bindings.values), participants: participants, previouslySharedIDs: [id],
                previousMembers: previouslyMember ? Set(participants.map(\.storageID)) : [participants[0].storageID])
            XCTAssertEqual(migrated.conversations[id]?.problems[participants[1].storageID.uuidString], previouslyMember ? .missing : nil)
            XCTAssertEqual(try prior.read(), initial)
        }
    }

    func testAuditGoneUnavailableRecordWithoutProjectionClearsProblem() throws {
        let (_, store, participants, initial) = try fixture()
        let id = try XCTUnwrap(initial.conversations.keys.first)
        let target = participants[1]
        let key = target.storageID.uuidString
        var library = initial
        library.conversations[id]?.problems[key] = .unavailable
        library.conversations[id]?.projections[key] = nil
        library.unavailableRecords[key] = [id + ".json": "unreadable"]
        try ConversationLibraryClaudeAdapter.capture(binding: XCTUnwrap(library.bindings[key]), files: target.files, library: &library, store: store)
        XCTAssertNil(library.conversations[id]?.problems[key])
        XCTAssertTrue(library.unavailableRecords[key, default: [:]].isEmpty)
    }
}
