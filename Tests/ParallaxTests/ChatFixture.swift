import XCTest
@testable import Parallax

class ChatFixture: XCTestCase {
    var root: URL!
    let cli = "11111111-1111-4111-8111-111111111111"
    let chatID = "local_44444444-4444-4444-8444-444444444444"
    let cwd = "/work/project"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("parallax-chats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func space(_ name: String) -> ClaudeChats.SpaceFolders {
        let id = UUID()
        let folder = root.appendingPathComponent(name)
        return ClaudeChats.folders(for: Space(id: id, name: name, folder: folder.path))
    }

    func namespace(_ space: ClaudeChats.SpaceFolders, account: String = "acct", org: String = "org") throws -> URL {
        let url = space.sessions.appendingPathComponent(account).appendingPathComponent(org)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func line(_ type: String, _ text: String, sessionID: String? = nil) -> String {
        var object: [String: Any] = ["type": type, "uuid": "uuid-\(text)", "cwd": cwd, "message": ["role": type, "content": text],
                                     "sessionId": sessionID ?? cli]
        if type == "assistant" { object["toolUseResult"] = ["agentId": "agent-1", "content": "out"] }
        return String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }

    /// Writes a native chat: a record in the namespace and a CLI transcript under ClaudeConfig/projects.
    func writeNativeChat(in space: ClaudeChats.SpaceFolders, lines: [String], lastActivity: Double,
                                 chatID: String? = nil, cliSessionID: String? = nil, title: String = "Fix the build",
                                 lastFocused: Double? = nil, trusted: Bool = true,
                                 permissionMode: String = "acceptEdits", bypassChosen: Bool = false, extra: [String: Any] = [:]) throws {
        let chatID = chatID ?? self.chatID
        let cli = cliSessionID ?? self.cli
        let ns = try namespace(space)
        var record: [String: Any] = [
            "sessionId": chatID, "cliSessionId": cli, "title": title, "cwd": cwd,
            "createdAt": 1_700_000_000_000.0, "lastActivityAt": lastActivity, "isArchived": false,
            "permissionMode": permissionMode, "spawnSeed": ["token": "secret"],
        ]
        record["lastFocusedAt"] = lastFocused
        if !trusted { record["importedFrom"] = "local-1p-code" }
        if bypassChosen { record["bypassChosenInApp"] = true }
        record.merge(extra) { _, new in new }
        try JSONSerialization.data(withJSONObject: record).write(to: ns.appendingPathComponent(chatID + ".json"))
        let project = space.config.appendingPathComponent("projects/-work-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: project.appendingPathComponent(cli + ".jsonl"))
    }

    var backups: URL { root.appendingPathComponent("Backups") }

    func recordURL(_ space: ClaudeChats.SpaceFolders, id: String? = nil) throws -> URL {
        try namespace(space).appendingPathComponent((id ?? chatID) + ".json")
    }

    func record(_ space: ClaudeChats.SpaceFolders, id: String? = nil) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL(space, id: id))) as? [String: Any])
    }

    func editRecord(_ space: ClaudeChats.SpaceFolders, id: String? = nil, _ edit: (inout [String: Any]) -> Void) throws {
        var object = try record(space, id: id)
        edit(&object)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: recordURL(space, id: id), options: .atomic)
    }

    func native(_ space: ClaudeChats.SpaceFolders, cli: String? = nil) -> URL {
        space.config.appendingPathComponent("projects/-work-project/" + (cli ?? self.cli) + ".jsonl")
    }

    func transfer(to target: ClaudeChats.SpaceFolders, spaces: [ClaudeChats.SpaceFolders]) throws -> ChatTransfer {
        try ClaudeChats.prepare(chat: XCTUnwrap(ClaudeChats.scan(spaces).first { $0.id == chatID }), target: target, spaces: spaces)
    }

    func savedFiles() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: backups.path) else { return [] }
        return try FileManager.default.subpathsOfDirectory(atPath: backups.path).map { backups.appendingPathComponent($0) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    func append(_ text: String, to url: URL) throws {
        var data = try Data(contentsOf: url)
        data.append(Data((line("user", text) + "\n").utf8))
        try data.write(to: url)
    }
}
