import XCTest
@testable import Parallax

final class SidebarTests: ChatFixture {
    private func config(_ space: ClaudeChats.SpaceFolders) -> URL {
        space.sessions.deletingLastPathComponent().appendingPathComponent("claude_desktop_config.json")
    }

    private func writeConfig(_ space: ClaudeChats.SpaceFolders, prefs: [String: Any], modified: Date, extra: [String: Any] = [:]) throws {
        var preferences: [String: Any] = ["sidebarMode": "epitaxy", "epitaxyPrefs": prefs]
        preferences.merge(extra) { _, new in new }
        try JSONSerialization.data(withJSONObject: ["preferences": preferences, "keep": "me"]).write(to: config(space))
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: config(space).path)
    }

    private func writePresets(_ space: ClaudeChats.SpaceFolders, account: String, _ presets: [(id: String, cwd: String)]) throws {
        let list = presets.map { ["id": $0.id, "name": "x", "target": ["kind": "local", "cwd": $0.cwd]] as [String: Any] }
        try JSONSerialization.data(withJSONObject: ["byAccount": [account: ["presets": list]]])
            .write(to: space.sessions.deletingLastPathComponent().appendingPathComponent("ccd-session-presets.json"))
    }

    private func prefs(_ space: ClaudeChats.SpaceFolders) throws -> [String: Any] {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config(space))) as? [String: Any])
        return try XCTUnwrap((object["preferences"] as? [String: Any])?["epitaxyPrefs"] as? [String: Any])
    }

    func testLayoutFromTheLastUsedSpaceIsCopiedUnderTheTargetAccount() throws {
        let a = space("A"), b = space("B")
        _ = try namespace(a, account: "acctA", org: "orgA")
        _ = try namespace(b, account: "acctB", org: "orgB")
        let group = ["groups": [["id": "cg-1", "name": "payloop"]], "assignments": ["code:" + chatID: "cg-1"],
                     "order": ["cg-1": ["code:" + chatID]]] as [String: Any]
        try writePresets(a, account: "acctA", [("pa", "/work/project"), ("pb", "/work/other")])
        try writePresets(b, account: "acctB", [("pz", "/work/project")])
        try writeConfig(a, prefs: [
            "dframe-group-scopes": ["acctA/orgA": group],
            "dframe-code-sections": ["acctA/orgA": ["sections": [["id": "cg-1", "kind": "manual"]]]],
            "dframe-local-slice": ["pinnedOrder": ["code:" + chatID]],
            "starred-local-code-sessions": [chatID],
            "code-projects-order.acctA": ["preset::pb", "preset::pa", "38st/repo", "preset::gone"],
        ], modified: Date(timeIntervalSince1970: 2_000))
        try writeConfig(b, prefs: [
            "dframe-group-scopes": ["acctB/orgB": ["groups": []], "other/scope": ["groups": ["kept"]]],
            "fastMode": true,
        ], modified: Date(timeIntervalSince1970: 1_000), extra: ["coworkWebSearchEnabled": true])

        XCTAssertNil(ClaudeChats.carriedLayout(to: a, spaces: [a, b]), "The newest layout is never overwritten by an older one")
        XCTAssertTrue(try ClaudeChats.carryLayout(to: b, spaces: [a, b], backups: backups))
        let carried = try prefs(b)
        let scopes = try XCTUnwrap(carried["dframe-group-scopes"] as? [String: Any])
        XCTAssertEqual(scopes["acctB/orgB"] as? NSDictionary, group as NSDictionary)
        XCTAssertEqual(scopes["other/scope"] as? NSDictionary, ["groups": ["kept"]] as NSDictionary)
        XCTAssertNotNil((carried["dframe-code-sections"] as? [String: Any])?["acctB/orgB"])
        XCTAssertEqual(carried["starred-local-code-sessions"] as? [String], [chatID])
        XCTAssertEqual(carried["code-projects-order.acctB"] as? [String], ["/work/other", "preset::pz", "38st/repo"])
        XCTAssertEqual(carried["fastMode"] as? Bool, true, "Other preferences stay")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: config(b))) as? [String: Any])
        XCTAssertEqual(object["keep"] as? String, "me")
        XCTAssertEqual((object["preferences"] as? [String: Any])?["coworkWebSearchEnabled"] as? Bool, true)
        XCTAssertEqual(try savedFiles().map(\.lastPathComponent), ["claude_desktop_config.json"])
        XCTAssertNil(ClaudeChats.carriedLayout(to: b, spaces: [a, b]), "Once copied, there is nothing left to carry")
    }

    func testSyncCarriesTheLayout() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        _ = try namespace(b)
        try writeConfig(a, prefs: ["dframe-local-slice": ["pinnedOrder": ["code:" + chatID]]], modified: Date(timeIntervalSince1970: 2_000))
        try writeConfig(b, prefs: [:], modified: Date(timeIntervalSince1970: 1_000))
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.layoutCarried)
        XCTAssertEqual((try prefs(b)["dframe-local-slice"] as? [String: Any])?["pinnedOrder"] as? [String], ["code:" + chatID])
    }

    func testActivityTimeCatchesUpWhenMessagesMatch() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 500)
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 100)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .updateMetadata)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual((try record(b)["lastActivityAt"] as? NSNumber)?.doubleValue, 500)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .upToDate)
        XCTAssertEqual(try transfer(to: a, spaces: [a, b]).kind, .upToDate)
    }
}
