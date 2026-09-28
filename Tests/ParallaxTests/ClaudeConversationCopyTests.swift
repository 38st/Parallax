import XCTest
@testable import Parallax

final class ClaudeConversationCopyTests: XCTestCase {
    private func makeFixture() throws -> ClaudeConversationFixture {
        let fixture = try ClaudeConversationFixture()
        let root = fixture.root
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return fixture
    }

    func testCopyPublishesIndependentImportedConversationWithoutCredentialsOrApprovals() throws {
        let fixture = try makeFixture()
        let sourceBefore = try fixture.source.files.manifest(at: SecureManagedPath(["UserData"]))
        let oldTargetRecord = try Data(contentsOf: fixture.destinationRecordURL)
        let plan = try fixture.plan()
        XCTAssertNotEqual(plan.copyID.uuidString.lowercased(), fixture.cliID)
        XCTAssertEqual(try fixture.source.copy(plan, destination: fixture.destination), .copied)
        XCTAssertEqual(try fixture.source.files.manifest(at: SecureManagedPath(["UserData"])), sourceBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.destinationRecordURL), oldTargetRecord)
        let copied = try fixture.destination.files.readFile(at: plan.publishedRecord, maximumBytes: 1_024_000)
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: copied) as? [String: Any])
        XCTAssertEqual(Set(record.keys), ["sessionId", "cliSessionId", "cwd", "originCwd", "title", "createdAt", "lastActivityAt", "isArchived", "importedFrom", "stagedTranscriptPath"])
        XCTAssertEqual(record["importedFrom"] as? String, "local-1p-code")
        XCTAssertEqual(record["isArchived"] as? Bool, false)
        XCTAssertEqual(record["cwd"] as? String, fixture.project.path)
        let transcript = try fixture.destination.files.readFile(at: plan.stagedTranscript, maximumBytes: 1_024_000)
        let entries = try transcript.split(separator: 10).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0["sessionId"] == nil })
        let toolResult = try XCTUnwrap(entries.last?["toolUseResult"] as? [String: Any])
        XCTAssertNil(toolResult["agentId"])
        XCTAssertEqual(toolResult["content"] as? String, "synthetic tool output")
        XCTAssertEqual(try Data(contentsOf: fixture.destinationRoot.appendingPathComponent("UserData/config.json")), Data("destination credentials sentinel".utf8))
        XCTAssertFalse(String(decoding: copied, as: UTF8.self).contains("source-secret"))
        for path in [plan.publishedRecord, plan.stagedTranscript] {
            let url = fixture.destinationRoot.appendingPathComponent(path.components.joined(separator: "/"))
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode?.intValue, 0o600)
        }
        XCTAssertEqual(try fixture.source.copy(plan, destination: fixture.destination), .alreadyCopied)
    }

    func testInterruptedCopyCanBeRetriedWithoutPublishingPartialConversation() throws {
        let fixture = try makeFixture()
        let plan = try fixture.plan()
        XCTAssertThrowsError(try fixture.source.copy(plan, destination: fixture.destination) {
            throw CocoaError(.fileWriteOutOfSpace)
        })
        XCTAssertEqual(try fixture.destination.files.itemState(at: plan.publishedRecord), .missing)
        XCTAssertEqual(try fixture.destination.files.readFile(at: plan.stagedTranscript, maximumBytes: 1_024_000), plan.transcript)
        let retryPlan = try fixture.plan()
        XCTAssertEqual(plan, retryPlan)
        XCTAssertEqual(try fixture.source.copy(retryPlan, destination: fixture.destination), .copied)
        XCTAssertEqual(try fixture.destination.catalog().conversations.count, 2)
    }

    func testFailureAfterRenameIsReconciledByRetry() throws {
        let fixture = try makeFixture()
        let plan = try fixture.plan()
        let failing = ClaudeConversationCopyService(files: try SecureManagedFileSystem(rootURL: fixture.destinationRoot, boundaryHook: {
            if $0 == .afterRename { throw CocoaError(.fileWriteOutOfSpace) }
        }))
        XCTAssertThrowsError(try fixture.source.copy(plan, destination: failing))
        XCTAssertEqual(try fixture.source.copy(plan, destination: fixture.destination), .alreadyCopied)
    }

    func testChangedSourceAfterPreviewDoesNotWriteDestination() throws {
        let fixture = try makeFixture()
        let plan = try fixture.plan()
        var data = try Data(contentsOf: fixture.sourceTranscriptURL)
        data.append(contentsOf: [32])
        try data.write(to: fixture.sourceTranscriptURL)
        XCTAssertThrowsError(try fixture.source.copy(plan, destination: fixture.destination))
        XCTAssertEqual(try fixture.destination.files.itemState(at: plan.stagedTranscript), .missing)
        XCTAssertEqual(try fixture.destination.files.itemState(at: plan.publishedRecord), .missing)
    }

    func testSourceChangeDuringStagingRefusesPublication() throws {
        let fixture = try makeFixture()
        let plan = try fixture.plan()
        XCTAssertThrowsError(try fixture.source.copy(plan, destination: fixture.destination) {
            try Data("changed".utf8).write(to: fixture.sourceTranscriptURL)
        })
        XCTAssertEqual(try fixture.destination.files.itemState(at: plan.publishedRecord), .missing)
    }

    func testChangedRecordRequiresFreshSelection() throws {
        let fixture = try makeFixture()
        let conversation = try fixture.conversation()
        var record = fixture.record
        record["title"] = "Changed title"
        try fixture.writeJSON(record, to: fixture.sourceRecordURL)
        XCTAssertThrowsError(try fixture.source.prepare(conversation, destination: fixture.destination)) {
            XCTAssertEqual($0 as? ClaudeConversationCopyError, .changed)
        }
    }

    func testDestinationNamespaceReplacementInvalidatesPreview() throws {
        let fixture = try makeFixture()
        let plan = try fixture.plan()
        let namespace = fixture.destinationRoot.appendingPathComponent(fixture.namespace.components.joined(separator: "/"))
        try FileManager.default.moveItem(at: namespace, to: namespace.appendingPathExtension("old"))
        try FileManager.default.createDirectory(at: namespace, withIntermediateDirectories: true)
        XCTAssertThrowsError(try fixture.source.copy(plan, destination: fixture.destination))
        XCTAssertEqual(try fixture.destination.files.itemState(at: plan.publishedRecord), .missing)
    }

    func testMultipleDestinationAccountsAreNeverChosenImplicitly() throws {
        let fixture = try makeFixture()
        let path = fixture.destinationRoot.appendingPathComponent("UserData/claude-code-sessions/\(UUID())/\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        XCTAssertThrowsError(try fixture.plan()) {
            XCTAssertEqual($0 as? ClaudeConversationCopyError, .ambiguousAccount)
        }
    }

    func testNoAccountAndSameSpaceAreRejected() throws {
        let fixture = try makeFixture()
        XCTAssertThrowsError(try fixture.source.prepare(fixture.conversation(), destination: fixture.source)) {
            XCTAssertEqual($0 as? ClaudeConversationCopyError, .sameSpace)
        }
        try FileManager.default.removeItem(at: fixture.destinationRoot.appendingPathComponent("UserData/claude-code-sessions"))
        XCTAssertThrowsError(try fixture.plan()) {
            XCTAssertEqual($0 as? ClaudeConversationCopyError, .unavailable)
        }
    }

    func testMissingAndAmbiguousTranscriptsAreRejected() throws {
        let fixture = try makeFixture()
        let second = fixture.sourceRoot.appendingPathComponent("UserData/ClaudeConfig/projects/other/\(fixture.cliID).jsonl")
        try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.sourceTranscriptURL, to: second)
        XCTAssertThrowsError(try fixture.plan()) {
            XCTAssertEqual($0 as? ClaudeConversationCopyError, .missingTranscript)
        }
        try FileManager.default.removeItem(at: second)
        try FileManager.default.removeItem(at: fixture.sourceTranscriptURL)
        XCTAssertThrowsError(try fixture.plan())
    }

    func testMalformedTranscriptIsNeverPartiallyImported() throws {
        let fixture = try makeFixture()
        let original = try Data(contentsOf: fixture.sourceTranscriptURL)
        for suffix in [Data("{bad}\n".utf8), Data("[]\n".utf8)] {
            try (original + suffix).write(to: fixture.sourceTranscriptURL)
            XCTAssertThrowsError(try fixture.plan())
        }
        try Data("{\"type\":\"user\"}\n".utf8).write(to: fixture.sourceTranscriptURL)
        XCTAssertThrowsError(try fixture.plan())
    }

    func testTranscriptSessionBindingAndWorkingDirectoryAreValidated() throws {
        let fixture = try makeFixture()
        for fields in [["sessionId": UUID().uuidString], ["cwd": "/tmp/../escape"], ["cwd": "relative/path"]] {
            var message = fixture.messages[0]
            for (key, value) in fields { message[key] = value }
            try fixture.writeTranscript([message], to: fixture.sourceTranscriptURL)
            XCTAssertThrowsError(try fixture.plan())
        }
    }

    func testRemoteAndInvalidRecordsAreCountedWithoutBeingOffered() throws {
        let fixture = try makeFixture()
        for fields: [String: Any] in [["sshConfig": ["host": "fixture"]], ["wslConfig": [:]], ["cwd": "relative"], ["sessionId": "local_../../escape"]] {
            var record = fixture.record
            for (key, value) in fields { record[key] = value }
            try fixture.writeJSON(record, to: fixture.sourceRecordURL)
            let catalog = try fixture.source.catalog()
            XCTAssertTrue(catalog.conversations.isEmpty)
            XCTAssertEqual(catalog.unavailableCount, 1)
        }
    }

    func testRecordCollisionPreservesExistingBytes() throws {
        let fixture = try makeFixture()
        let plan = try fixture.plan()
        let url = fixture.destinationRoot.appendingPathComponent(plan.publishedRecord.components.joined(separator: "/"))
        let sentinel = Data("unrelated conversation".utf8)
        try sentinel.write(to: url)
        XCTAssertThrowsError(try fixture.source.copy(plan, destination: fixture.destination))
        XCTAssertEqual(try Data(contentsOf: url), sentinel)
        XCTAssertEqual(try fixture.destination.files.itemState(at: plan.stagedTranscript), .missing)
    }

    func testStagedCollisionPreservesExistingBytes() throws {
        let fixture = try makeFixture()
        let plan = try fixture.plan()
        let url = fixture.destinationRoot.appendingPathComponent(plan.stagedTranscript.components.joined(separator: "/"))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = Data("unrelated data".utf8)
        try sentinel.write(to: url)
        XCTAssertThrowsError(try fixture.source.copy(plan, destination: fixture.destination))
        XCTAssertEqual(try Data(contentsOf: url), sentinel)
        XCTAssertEqual(try fixture.destination.files.itemState(at: plan.publishedRecord), .missing)
    }

    func testCopiedConversationCanBeCopiedAgainWithoutFollowingExternalStagingPaths() throws {
        let fixture = try makeFixture()
        let plan = try fixture.plan()
        _ = try fixture.source.copy(plan, destination: fixture.destination)
        let copy = try XCTUnwrap(fixture.destination.catalog().conversations.first { $0.cliSessionID == plan.copyID.uuidString.lowercased() })
        XCTAssertNoThrow(try fixture.destination.prepare(copy, destination: fixture.source))
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: plan.record) as? [String: Any])
        record["stagedTranscriptPath"] = fixture.sourceTranscriptURL.path
        let path = fixture.destinationRoot.appendingPathComponent(plan.publishedRecord.components.joined(separator: "/"))
        try fixture.writeJSON(record, to: path)
        let changed = try XCTUnwrap(fixture.destination.catalog().conversations.first { $0.cliSessionID == copy.cliSessionID })
        XCTAssertThrowsError(try fixture.destination.prepare(changed, destination: fixture.source))
    }
}

struct ClaudeConversationFixture {
    let root: URL
    let sourceRoot: URL
    let destinationRoot: URL
    let project: URL
    let source: ClaudeConversationCopyService
    let destination: ClaudeConversationCopyService
    let namespace: SecureManagedPath
    let sourceRecordURL: URL
    let destinationRecordURL: URL
    let sourceTranscriptURL: URL
    let cliID = "11111111-1111-4111-8111-111111111111"
    let record: [String: Any]
    let messages: [[String: Any]]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCopy-\(UUID())")
        sourceRoot = root.appendingPathComponent("source")
        destinationRoot = root.appendingPathComponent("destination")
        project = root.appendingPathComponent("project")
        namespace = try SecureManagedPath(["UserData", "claude-code-sessions", "22222222-2222-4222-8222-222222222222", "33333333-3333-4333-8333-333333333333"])
        for path in [sourceRoot, destinationRoot] {
            try FileManager.default.createDirectory(at: path.appendingPathComponent(namespace.components.joined(separator: "/")), withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        source = ClaudeConversationCopyService(files: try SecureManagedFileSystem(rootURL: sourceRoot))
        destination = ClaudeConversationCopyService(files: try SecureManagedFileSystem(rootURL: destinationRoot))
        let recordPath = namespace.components.joined(separator: "/") + "/local_44444444-4444-4444-8444-444444444444.json"
        sourceRecordURL = sourceRoot.appendingPathComponent(recordPath)
        destinationRecordURL = destinationRoot.appendingPathComponent(recordPath)
        sourceTranscriptURL = sourceRoot.appendingPathComponent("UserData/ClaudeConfig/projects/synthetic-project/\(cliID).jsonl")
        record = ["sessionId": "local_44444444-4444-4444-8444-444444444444", "cliSessionId": cliID,
                  "title": "Synthetic conversation", "cwd": project.path, "createdAt": 1_700_000_000_000,
                  "lastActivityAt": 1_700_000_001_000, "permissionMode": "bypassPermissions",
                  "sessionPermissionUpdates": ["allow everything"], "emailAddress": "synthetic@example.test",
                  "spawnSeed": ["token": "source-secret"], "remoteMcpServersConfig": ["source-secret"]]
        messages = [
            ["type": "user", "uuid": UUID().uuidString, "sessionId": cliID, "cwd": project.path,
             "message": ["role": "user", "content": "Continue the synthetic work"]],
            ["type": "assistant", "uuid": UUID().uuidString, "sessionId": cliID, "cwd": project.path,
             "message": ["role": "assistant", "content": "Synthetic response"],
             "toolUseResult": ["agentId": "agent-old", "content": "synthetic tool output"]],
        ]
        try writeJSON(record, to: sourceRecordURL)
        try writeJSON(record, to: destinationRecordURL)
        try writeTranscript(messages, to: sourceTranscriptURL)
        try Data("source credentials sentinel".utf8).write(to: sourceRoot.appendingPathComponent("UserData/config.json"))
        try Data("destination credentials sentinel".utf8).write(to: destinationRoot.appendingPathComponent("UserData/config.json"))
    }

    func writeJSON(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }
    func writeTranscript(_ messages: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for message in messages { data.append(try JSONSerialization.data(withJSONObject: message)); data.append(10) }
        try data.write(to: url)
    }
    func conversation() throws -> ClaudeConversation { try XCTUnwrap(source.catalog().conversations.first) }
    func plan() throws -> ClaudeConversationCopyPlan { try source.prepare(conversation(), destination: destination) }
    func remove() throws { try FileManager.default.removeItem(at: root) }
}
