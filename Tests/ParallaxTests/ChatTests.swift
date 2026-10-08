import XCTest
@testable import Parallax

final class ChatTests: XCTestCase {
    private var root: URL!
    private let cli = "11111111-1111-4111-8111-111111111111"
    private let chatID = "local_44444444-4444-4444-8444-444444444444"
    private let cwd = "/work/project"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parallax-chats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func space(_ name: String) -> ClaudeChats.SpaceFolders {
        let id = UUID()
        let folder = root.appendingPathComponent(name)
        return ClaudeChats.folders(for: Space(id: id, name: name, folder: folder.path))
    }

    private func namespace(_ space: ClaudeChats.SpaceFolders, account: String = "acct", org: String = "org") throws -> URL {
        let url = space.sessions.appendingPathComponent(account).appendingPathComponent(org)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func line(_ type: String, _ text: String, sessionID: String? = nil) -> String {
        var object: [String: Any] = ["type": type, "uuid": "uuid-\(text)", "cwd": cwd, "message": ["role": type, "content": text],
                                     "sessionId": sessionID ?? cli]
        if type == "assistant" { object["toolUseResult"] = ["agentId": "agent-1", "content": "out"] }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Writes a native chat: a record in the namespace and a CLI transcript under ClaudeConfig/projects.
    private func writeNativeChat(in space: ClaudeChats.SpaceFolders, lines: [String], lastActivity: Double,
                                 chatID: String? = nil, cliSessionID: String? = nil, title: String = "Fix the build") throws {
        let chatID = chatID ?? self.chatID
        let cli = cliSessionID ?? self.cli
        let ns = try namespace(space)
        let record: [String: Any] = [
            "sessionId": chatID, "cliSessionId": cli, "title": title, "cwd": cwd,
            "createdAt": 1_700_000_000_000.0, "lastActivityAt": lastActivity, "isArchived": false,
            "permissionMode": "acceptEdits", "spawnSeed": ["token": "secret"],
        ]
        try JSONSerialization.data(withJSONObject: record).write(to: ns.appendingPathComponent(chatID + ".json"))
        let project = space.config.appendingPathComponent("projects/-work-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: project.appendingPathComponent(cli + ".jsonl"))
    }

    func testContinuingAddsChatToOtherAccountWithoutPrivateFields() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "hello"), #"{"type":"summary"}"#], lastActivity: 1_700_000_001_000)
        _ = try namespace(b, account: "acct-b", org: "org-b")

        let chats = ClaudeChats.scan([a, b])
        XCTAssertEqual(chats.count, 1)
        let transfer = try ClaudeChats.prepare(chat: chats[0], target: b, spaces: [a, b])
        XCTAssertEqual(transfer.kind, .add)
        try ClaudeChats.apply(transfer, backups: root.appendingPathComponent("Backups"))

        let ns = b.sessions.appendingPathComponent("acct-b/org-b")
        let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: ns.appendingPathComponent(chatID + ".json"))) as? [String: Any])
        XCTAssertEqual(Set(record.keys), ["cliSessionId", "createdAt", "cwd", "importedFrom", "isArchived", "lastActivityAt", "originCwd", "sessionId", "stagedTranscriptPath", "title"])
        XCTAssertEqual(record["sessionId"] as? String, chatID)
        let staged = try XCTUnwrap(record["stagedTranscriptPath"] as? String)
        XCTAssertTrue(URL(fileURLWithPath: staged).resolvingSymlinksInPath().path
            .hasPrefix(ns.appendingPathComponent("imported-staging").resolvingSymlinksInPath().path))
        XCTAssertEqual(URL(fileURLWithPath: staged).lastPathComponent, cli + ".jsonl")

        let transcript = try String(contentsOfFile: staged, encoding: .utf8)
        let lines = transcript.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "Metadata lines without a working directory are dropped")
        XCTAssertFalse(transcript.contains("sessionId"))
        XCTAssertFalse(transcript.contains("agent-1"))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: staged)[.posixPermissions] as? Int, 0o600)

        let after = ClaudeChats.scan([a, b])
        XCTAssertEqual(after[0].copies.count, 2)
        XCTAssertEqual(try ClaudeChats.prepare(chat: after[0], target: b, spaces: [a, b]).kind, .upToDate)
    }

    func testOlderCopyIsUpdatedAndDivergedCopyIsBackedUp() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "hello")], lastActivity: 1_700_000_001_000)
        _ = try namespace(b)
        let backups = root.appendingPathComponent("Backups")
        try ClaudeChats.apply(try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b]), backups: backups)

        // A continues the chat.
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "hello"), line("user", "more")], lastActivity: 1_700_000_009_000)
        let update = try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b])
        XCTAssertEqual(update.kind, .update)
        try ClaudeChats.apply(update, backups: backups)
        XCTAssertEqual(try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b]).kind, .upToDate)

        // Both continue separately; B's copy is replaced only after a backup.
        let bChat = ClaudeChats.scan([b])[0]
        let bTranscript = try XCTUnwrap(ClaudeChats.transcriptURL(for: bChat.newest, in: b))
        try Data((try String(contentsOf: bTranscript, encoding: .utf8) + line("user", "only in b") + "\n").utf8).write(to: bTranscript)
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "hello"), line("user", "more"), line("user", "only in a")],
                            lastActivity: 1_700_000_099_000)
        let diverged = try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b])
        XCTAssertEqual(diverged.kind, .replaceDiverged)
        try ClaudeChats.apply(diverged, backups: backups)
        let saved = try FileManager.default.subpathsOfDirectory(atPath: backups.path)
        XCTAssertTrue(saved.contains { $0.hasSuffix(cli + ".jsonl") })
        XCTAssertTrue(saved.contains { $0.hasSuffix(chatID + ".json") })
    }

    func testPrimaryNamespaceIgnoresSchedulingOnlyFolders() throws {
        let b = space("B")
        let scheduling = try namespace(b, account: "old", org: "org")
        try Data("{}".utf8).write(to: scheduling.appendingPathComponent("scheduled-tasks.json"))
        let active = try namespace(b, account: "current", org: "org")
        try Data(#"{"sessionId":"local_x","cliSessionId":"x","cwd":"/w","isArchived":false}"#.utf8)
            .write(to: active.appendingPathComponent("local_x.json"))
        XCTAssertEqual(try ClaudeChats.primaryNamespace(in: b).resolvingSymlinksInPath().path, active.resolvingSymlinksInPath().path)

        let empty = space("C")
        _ = try namespace(empty, account: "one", org: "org")
        _ = try namespace(empty, account: "two", org: "org")
        XCTAssertThrowsError(try ClaudeChats.primaryNamespace(in: empty))
    }

    func testDeletedArchivedAndRemoteChatsAreHidden() throws {
        let a = space("A")
        let ns = try namespace(a)
        func write(_ id: String, _ extra: [String: Any] = [:]) throws {
            var record: [String: Any] = ["sessionId": id, "cliSessionId": UUID().uuidString, "cwd": "/w", "lastActivityAt": 1.0]
            record.merge(extra) { _, new in new }
            try JSONSerialization.data(withJSONObject: record).write(to: ns.appendingPathComponent(id + ".json"))
        }
        try write("local_keep")
        try write("local_gone")
        try Data().write(to: ns.appendingPathComponent("deleted_gone"))
        try write("local_archived", ["isArchived": true])
        try write("local_remote", ["sshConfig": ["host": "x"]])
        XCTAssertEqual(ClaudeChats.scan([a]).map(\.id), ["local_keep"])
    }

    func testForeignSessionLinesAreRefused() {
        let data = Data((line("user", "hi") + "\n" + line("user", "x", sessionID: "someone-else") + "\n").utf8)
        XCTAssertThrowsError(try ClaudeChats.normalizedTranscript(data, cliSessionID: cli, cwd: cwd))
    }

    func testMalformedMessagesAreNotSilentlyDropped() throws {
        for invalid in ["{broken", #"{"type":"user","message":{"content":"lost"}}"#] {
            let data = Data((line("user", "hi") + "\n" + invalid + "\n").utf8)
            XCTAssertThrowsError(try ClaudeChats.normalizedTranscript(data, cliSessionID: cli, cwd: cwd))
        }
    }

    func testRecordIdentifiersCannotEscapeTheirFolders() throws {
        for key in ["sessionId", "cliSessionId"] {
            for value in ["local_x/../../outside", "..", "", "local_x\0bad"] {
                var record = ["sessionId": chatID, "cliSessionId": cli, "cwd": cwd]
                record[key] = value
                let data = try JSONSerialization.data(withJSONObject: record)
                XCTAssertNil(ClaudeChats.parseRecord(data, namespace: root, spaceID: UUID()))
            }
        }
    }

    func testHiddenTargetRecordsAndTombstonesAreNotOverwritten() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        let ns = try namespace(b)
        let record = ns.appendingPathComponent(chatID + ".json")
        try Data("{broken".utf8).write(to: record)
        XCTAssertThrowsError(try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b]))
        XCTAssertEqual(try Data(contentsOf: record), Data("{broken".utf8))
        try FileManager.default.removeItem(at: record)
        try Data().write(to: ns.appendingPathComponent("deleted_" + chatID.dropFirst(6)))
        XCTAssertThrowsError(try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b]))
    }

    func testAddDoesNotOverwriteARecordCreatedAfterPreparation() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        let ns = try namespace(b)
        let transfer = try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b])
        let record = ns.appendingPathComponent(chatID + ".json")
        let data = Data("new target record".utf8)
        try data.write(to: record)
        XCTAssertThrowsError(try ClaudeChats.apply(transfer, backups: root.appendingPathComponent("Backups")))
        XCTAssertEqual(try Data(contentsOf: record), data)
    }

    func testCustomUserDataFolderIsScanned() throws {
        let custom = root.appendingPathComponent("custom data")
        let space = Space(name: "Custom", folder: root.appendingPathComponent("space").path,
                          arguments: LaunchText.join(["--user-data-dir", custom.path]))
        let folders = ClaudeChats.folders(for: space)
        XCTAssertEqual(folders.sessions.path, custom.appendingPathComponent("claude-code-sessions").path)
        try writeNativeChat(in: folders, lines: [line("user", "hi")], lastActivity: 100)
        XCTAssertEqual(ClaudeChats.scan([folders]).map(\.id), [chatID])
    }

    func testContinueURL() {
        XCTAssertEqual(ClaudeChats.continueURL(chatID: chatID)?.absoluteString, "claude://code/continue?session=\(chatID)")
    }

    func testBulkCarryoverCombinesBothAccountsAndRepeatsIncrementally() throws {
        let a = space("A")
        let b = space("B")
        let backups = root.appendingPathComponent("Backups")
        try writeNativeChat(in: a, lines: [line("user", "first")], lastActivity: 100)
        try writeNativeChat(in: a, lines: [line("user", "second", sessionID: "second")], lastActivity: 200,
                            chatID: "local_second", cliSessionID: "second")
        try writeNativeChat(in: b, lines: [line("user", "third", sessionID: "third")], lastActivity: 300,
                            chatID: "local_third", cliSessionID: "third")

        let toB = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertEqual(toB.transferred, 2)
        XCTAssertNil(toB.summary)
        let toA = ClaudeChats.syncAll(to: a, spaces: [a, b], backups: backups)
        XCTAssertEqual(toA.transferred, 1)
        XCTAssertNil(toA.summary)
        XCTAssertEqual(ClaudeChats.scan([a]).count, 3)
        XCTAssertEqual(ClaudeChats.scan([b]).count, 3)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path), "Unchanged chats need no backups or writes")

        try writeNativeChat(in: a, lines: [line("user", "first"), line("assistant", "continued")], lastActivity: 400)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
    }

    func testBulkCarryoverFindsNativeContinuationBehindStaleStagingAndEqualTimestamps() throws {
        let a = space("A")
        let b = space("B")
        let backups = root.appendingPathComponent("Backups")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        _ = try namespace(b)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)

        // Claude keeps the imported record and staged path while its native transcript grows.
        // The record's timestamp and staged file can both lag behind this continuation.
        let native = b.config.appendingPathComponent("projects/-work-project/" + cli + ".jsonl")
        try FileManager.default.createDirectory(at: native.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((line("user", "hi") + "\n" + line("assistant", "new in B") + "\n").utf8).write(to: native)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: native.path)

        let copy = try XCTUnwrap(ClaudeChats.scan([b]).first?.newest)
        XCTAssertEqual(ClaudeChats.transcriptURL(for: copy, in: b)?.resolvingSymlinksInPath(), native.resolvingSymlinksInPath())
        let result = ClaudeChats.syncAll(to: a, spaces: [b, a], backups: backups)
        XCTAssertEqual(result.transferred, 1, "An equal timestamp cannot hide a longer copy in the other account")
        XCTAssertNil(result.summary)
        let updated = try XCTUnwrap(ClaudeChats.scan([a]).first?.newest)
        let transcript = try XCTUnwrap(ClaudeChats.transcriptURL(for: updated, in: a))
        XCTAssertTrue(try String(contentsOf: transcript, encoding: .utf8).contains("new in B"))
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 0)
    }

    func testPendingStagedImportStillWinsOverShorterNativeTranscript() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "more")], lastActivity: 200)
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups")).transferred, 1)
        let updated = try XCTUnwrap(ClaudeChats.scan([b]).first?.newest)
        let transcript = try XCTUnwrap(ClaudeChats.transcriptURL(for: updated, in: b))
        XCTAssertEqual(transcript.path, updated.stagedTranscriptPath)
        XCTAssertTrue(try String(contentsOf: transcript, encoding: .utf8).contains("more"))

        // Native metadata or divergent content doesn't prove a pending import was consumed.
        let native = b.config.appendingPathComponent("projects/-work-project/" + cli + ".jsonl")
        try Data((line("user", "different native branch") + "\n").utf8).write(to: native)
        XCTAssertEqual(ClaudeChats.transcriptURL(for: updated, in: b)?.path, updated.stagedTranscriptPath)
    }

    func testLongerTranscriptWinsDespiteOlderActivityMetadata() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 200)
        try writeNativeChat(in: b, lines: [line("user", "hi"), line("assistant", "continued")], lastActivity: 100)
        let result = ClaudeChats.syncAll(to: a, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 1)
        XCTAssertNil(result.summary)
        let copy = try XCTUnwrap(ClaudeChats.scan([a]).first?.newest)
        let transcript = try XCTUnwrap(ClaudeChats.transcriptURL(for: copy, in: a))
        XCTAssertTrue(try String(contentsOf: transcript, encoding: .utf8).contains("continued"))
    }

    func testEqualTimeDamagedTargetTranscriptIsBackedUpAndRepaired() throws {
        let a = space("A")
        try writeNativeChat(in: a, lines: [line("user", "healthy")], lastActivity: 100)
        for damage in ["missing", "corrupt"] {
            let b = space("B-" + damage)
            let backups = root.appendingPathComponent("Backups-" + damage)
            try writeNativeChat(in: b, lines: [line("user", "old")], lastActivity: 100)
            let native = b.config.appendingPathComponent("projects/-work-project/" + cli + ".jsonl")
            if damage == "missing" {
                try FileManager.default.removeItem(at: native)
            } else {
                try Data("{broken".utf8).write(to: native)
            }
            let result = ClaudeChats.syncAll(to: b, spaces: [b, a], backups: backups)
            XCTAssertEqual(result.transferred, 1)
            XCTAssertNil(result.summary)
            let saved = try FileManager.default.subpathsOfDirectory(atPath: backups.path)
            XCTAssertTrue(saved.contains { $0.hasSuffix(chatID + ".json") })
            if damage == "corrupt" {
                let path = try XCTUnwrap(saved.first { $0.hasSuffix(cli + ".jsonl") })
                XCTAssertEqual(try String(contentsOf: backups.appendingPathComponent(path), encoding: .utf8), "{broken")
            }
        }
    }

    func testBulkCarryoverBacksUpDivergentMessagesAndReportsThem() throws {
        let a = space("A")
        let b = space("B")
        let backups = root.appendingPathComponent("Backups")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "only in A")], lastActivity: 200)
        try writeNativeChat(in: b, lines: [line("user", "hi"), line("assistant", "only in B")], lastActivity: 100)

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(try XCTUnwrap(result.summary).contains("Fix the build"))
        XCTAssertTrue(try XCTUnwrap(result.summary).contains(backups.path))
        let saved = try FileManager.default.subpathsOfDirectory(atPath: backups.path)
        let transcript = try XCTUnwrap(saved.first { $0.hasSuffix(cli + ".jsonl") })
        XCTAssertTrue(try String(contentsOf: backups.appendingPathComponent(transcript), encoding: .utf8).contains("only in B"))
        XCTAssertTrue(saved.contains { $0.hasSuffix(chatID + ".json") })
    }

    func testBulkCarryoverContinuesAfterMissingAndCorruptTranscripts() throws {
        let a = space("A")
        let b = space("B")
        _ = try namespace(b)
        try writeNativeChat(in: a, lines: [line("user", "good")], lastActivity: 100)
        try writeNativeChat(in: a, lines: ["{broken"], lastActivity: 300,
                            chatID: "local_corrupt", cliSessionID: "corrupt", title: "Corrupt chat")
        try writeNativeChat(in: a, lines: [], lastActivity: 200,
                            chatID: "local_missing", cliSessionID: "missing", title: "Missing chat")
        try FileManager.default.removeItem(at: a.config.appendingPathComponent("projects/-work-project/missing.jsonl"))

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(result.issues.count, 2)
        XCTAssertTrue(try XCTUnwrap(result.summary).contains("Corrupt chat"))
        XCTAssertTrue(try XCTUnwrap(result.summary).contains("Missing chat"))
        XCTAssertEqual(ClaudeChats.scan([b]).map(\.id), [chatID])
    }

    func testBulkCarryoverRespectsTargetArchivesAndDeletions() throws {
        let a = space("A")
        let b = space("B")
        let ns = try namespace(b)
        try writeNativeChat(in: a, lines: [line("user", "archived")], lastActivity: 100)
        try writeNativeChat(in: a, lines: [line("user", "deleted", sessionID: "deleted")], lastActivity: 200,
                            chatID: "local_deleted", cliSessionID: "deleted")
        let archived = try JSONSerialization.data(withJSONObject: ["sessionId": chatID, "cliSessionId": cli, "cwd": cwd, "isArchived": true])
        try archived.write(to: ns.appendingPathComponent(chatID + ".json"))
        try Data().write(to: ns.appendingPathComponent("deleted_deleted"))

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 0)
        XCTAssertNil(result.summary)
        XCTAssertEqual(try Data(contentsOf: ns.appendingPathComponent(chatID + ".json")), archived)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ns.appendingPathComponent("local_deleted.json").path))
    }

    func testMissingDestinationNamespaceReportsOnceForAllChats() throws {
        let a = space("A")
        let b = space("New account")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        try writeNativeChat(in: a, lines: [line("user", "two", sessionID: "two")], lastActivity: 100,
                            chatID: "local_two", cliSessionID: "two")
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 0)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertTrue(try XCTUnwrap(result.summary).contains("Open Claude Code once in New account"))
    }

    func testUnsupportedSourceAndUnreadableTargetRecordsAreReported() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        let sourceNamespace = try namespace(a)
        try Data("{broken".utf8).write(to: sourceNamespace.appendingPathComponent("local_broken.json"))
        let targetRecord = try namespace(b).appendingPathComponent(chatID + ".json")
        let original = Data("{unreadable".utf8)
        try original.write(to: targetRecord)

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 0)
        XCTAssertEqual(result.issues.count, 2)
        XCTAssertTrue(try XCTUnwrap(result.summary).contains("unsupported format"))
        XCTAssertTrue(try XCTUnwrap(result.summary).contains("destination"))
        XCTAssertEqual(try Data(contentsOf: targetRecord), original)
    }

    func testBulkCarryoverKeepsOneDestinationNamespaceForTheWholeBatch() throws {
        let a = space("A")
        let b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "shared"), line("assistant", "new")], lastActivity: 500)
        try writeNativeChat(in: a, lines: [line("user", "second", sessionID: "second")], lastActivity: 400,
                            chatID: "local_second", cliSessionID: "second")
        try writeNativeChat(in: b, lines: [line("user", "shared")], lastActivity: 100)
        try writeNativeChat(in: b, lines: [line("user", "current", sessionID: "current")], lastActivity: 100,
                            chatID: "local_current", cliSessionID: "current")
        let old = try namespace(b)
        let current = try namespace(b, account: "current")
        let anchor = current.appendingPathComponent("local_current.json")
        try FileManager.default.moveItem(at: old.appendingPathComponent("local_current.json"), to: anchor)
        let oldRecord = old.appendingPathComponent(chatID + ".json")
        let oldData = try Data(contentsOf: oldRecord)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: oldRecord.path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1000)], ofItemAtPath: anchor.path)

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: root.appendingPathComponent("Backups"))
        XCTAssertEqual(result.transferred, 2)
        XCTAssertNil(result.summary)
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent(chatID + ".json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.appendingPathComponent("local_second.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.appendingPathComponent("local_second.json").path))
        XCTAssertEqual(try Data(contentsOf: oldRecord), oldData)
    }
}
