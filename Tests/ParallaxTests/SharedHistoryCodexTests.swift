import XCTest
@testable import Parallax

final class SharedHistoryCodexTests: XCTestCase {
    private let sessionID = "11111111-1111-4111-8111-111111111111"

    @MainActor
    func testIndexRefreshOnlyInitializesAndListsLocalHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SharedIndex-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("codex")
        let text = #"""
        #!/bin/sh
        while IFS= read -r request; do
          printf '%s\n' "$request" >> "$CODEX_HOME/requests.jsonl"
          case "$request" in
            *'"initialize"'*) printf '%s\n' '{"id":0,"result":{}}' ;;
            *'useStateDbOnly'*) printf '%s\n' '{"id":1,"result":{"data":[],"nextCursor":null}}' ;;
          esac
        done
        """#
        try Data(text.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let executable = try ProviderExecutableLocator(fixedDirectories: [root], homebrewRoots: []).locate(named: "codex")
        try await SharedHistoryCodexIndex.refresh(root, executable: executable)
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(requests.compactMap { $0?["method"] as? String }, ["initialize", "initialized", "thread/list"])
        let last = try XCTUnwrap(requests.last.flatMap { $0 })
        let params = try XCTUnwrap(last["params"] as? [String: Any])
        XCTAssertEqual(params["useStateDbOnly"] as? Bool, false)
        XCTAssertEqual(params["limit"] as? Int, 200)
    }

    private func transcript(version: String = "0.153.2", source: Any = "vscode", text: String = "first") throws -> Data {
        let records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": "2026-09-28T10:00:00Z", "payload": [
                "id": sessionID, "cwd": "/synthetic/project", "cli_version": version, "source": source]],
            ["type": "event_msg", "payload": ["type": "user_message", "message": text]],
        ]
        var result = Data()
        for record in records { result.append(try JSONSerialization.data(withJSONObject: record)); result.append(10) }
        return result
    }

    func testCodexMirrorsExistingAndNewMessagesInBothDirectionsWithoutAuthOrDatabaseFiles() throws {
        let fixture = try ClaudeConversationFixture()
        defer { try? fixture.remove() }
        let a = SharedHistoryParticipant(storageID: UUID(), files: fixture.source.files, provider: "codex")
        let b = SharedHistoryParticipant(storageID: UUID(), files: fixture.destination.files, provider: "codex")
        let path = try SecureManagedPath(["sessions", "2026", "09", "28", "rollout-2026-09-28T10-00-00-\(sessionID).jsonl"])
        let root = try SecureManagedPath(Array(path.components.dropLast()))
        try a.files.createDirectory(at: root)
        try a.files.write(transcript(), to: path)
        for member in [a, b] {
            try member.files.write(Data(member.storageID.uuidString.utf8), to: SecureManagedPath(["auth.json"]))
            try member.files.write(Data("private database".utf8), to: SecureManagedPath(["state_5.sqlite"]))
        }
        let beforeAuth = try [a, b].map { try $0.files.readFile(at: SecureManagedPath(["auth.json"]), maximumBytes: 100) }
        let ids = try SharedHistoryService.synchronize([a, b], knownIDs: [])
        XCTAssertEqual(ids, [sessionID])
        var continued = try b.files.readFile(at: path, maximumBytes: 4_096)
        continued.append(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"user_message\",\"message\":\"second account\"}}\n".utf8))
        try continued.write(to: fixture.destinationRoot.appendingPathComponent(path.components.joined(separator: "/")))
        _ = try SharedHistoryService.synchronize([a, b], knownIDs: ids)
        XCTAssertEqual(try a.files.readFile(at: path, maximumBytes: 4_096), continued)
        XCTAssertEqual(try [a, b].map { try $0.files.readFile(at: SecureManagedPath(["auth.json"]), maximumBytes: 100) }, beforeAuth)
        for member in [a, b] {
            XCTAssertEqual(try member.files.readFile(at: SecureManagedPath(["state_5.sqlite"]), maximumBytes: 100), Data("private database".utf8))
        }
        _ = try SharedHistoryService.synchronize([a, b], knownIDs: ids)
        XCTAssertEqual(try SharedHistoryService.catalog(a).count, 1)
    }

    func testCodexFormatRejectsRemoteUnknownVersionAndPartialRecords() throws {
        XCTAssertNoThrow(try SharedHistoryService.codexTranscript(transcript(version: "0.158.0-alpha.2.1")))
        for data in [try transcript(version: "9.0"), try transcript(source: "remote"),
                     try transcript(source: ["subagent": "parent"]), Data("{}\n".utf8),
                     Data(try transcript().dropLast()), Data()] {
            XCTAssertThrowsError(try SharedHistoryService.codexTranscript(data))
        }
    }

    func testCodexSymlinkAndDuplicateSessionIDsFailClosed() throws {
        let fixture = try ClaudeConversationFixture()
        defer { try? fixture.remove() }
        let participant = SharedHistoryParticipant(storageID: UUID(), files: fixture.source.files, provider: "codex")
        let sessions = try SecureManagedPath(["sessions"])
        try participant.files.createDirectory(at: sessions)
        let first = try sessions.appending("rollout-one-\(sessionID).jsonl")
        let second = try sessions.appending("rollout-two-\(sessionID).jsonl")
        try participant.files.write(transcript(), to: first)
        try participant.files.write(transcript(), to: second)
        XCTAssertThrowsError(try SharedHistoryService.catalog(participant))
        try FileManager.default.removeItem(at: fixture.sourceRoot.appendingPathComponent(second.components.joined(separator: "/")))
        try FileManager.default.createSymbolicLink(at: fixture.sourceRoot.appendingPathComponent(second.components.joined(separator: "/")),
            withDestinationURL: fixture.sourceRoot.appendingPathComponent(first.components.joined(separator: "/")))
        XCTAssertThrowsError(try SharedHistoryService.catalog(participant))
    }
}
