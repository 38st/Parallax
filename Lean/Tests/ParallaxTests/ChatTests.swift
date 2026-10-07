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
    private func writeNativeChat(in space: ClaudeChats.SpaceFolders, lines: [String], lastActivity: Double) throws {
        let ns = try namespace(space)
        let record: [String: Any] = [
            "sessionId": chatID, "cliSessionId": cli, "title": "Fix the build", "cwd": cwd,
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
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("assistant", "hello"), #"{"type":"summary"}"#, "{broken"], lastActivity: 1_700_000_001_000)
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
        XCTAssertEqual(lines.count, 2, "Lines without a working directory and unreadable lines are dropped")
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

    func testContinueURL() {
        XCTAssertEqual(ClaudeChats.continueURL(chatID: chatID)?.absoluteString, "claude://code/continue?session=\(chatID)")
    }
}
