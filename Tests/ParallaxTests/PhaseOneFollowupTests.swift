import XCTest
@testable import Parallax

final class PhaseOneFollowupTests: ChatFixture {
    func testUpdateUsesTheLongestNativeDuplicate() throws {
        let a = space("A"), b = space("B")
        let one = line("user", "one"), two = line("assistant", "two"), three = line("user", "three")
        try writeNativeChat(in: a, lines: [one, two, three], lastActivity: 300)
        try writeNativeChat(in: b, lines: [one], lastActivity: 100)
        let duplicate = b.config.appendingPathComponent("projects/other/\(cli).jsonl")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ownLine = #"{"type":"custom-title","title":"Private title"}"#
        try Data(([one, two, ownLine].joined(separator: "\n") + "\n").utf8).write(to: duplicate)
        let oldShort = try Data(contentsOf: native(b))
        let next = try transfer(to: b, spaces: [a, b])
        XCTAssertEqual(next.targetTranscript, duplicate)
        try ClaudeChats.apply(next, backups: backups)
        let updated = try Data(contentsOf: duplicate)
        XCTAssertTrue(String(decoding: updated, as: UTF8.self).contains("Private title"))
        XCTAssertTrue(String(decoding: updated, as: UTF8.self).contains("three"))
        XCTAssertEqual(try Data(contentsOf: native(b)), oldShort)
        XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .upToDate)
        XCTAssertEqual(ClaudeChats.syncAll(to: a, spaces: [a, b], backups: backups).issues, [])
    }

    func testOwnLineageKeepsClaudeIDsAndDeletedParentExtras() throws {
        let a = space("A"), b = space("B")
        let one = line("user", "one")
        let spawn: [String: Any] = ["sessionId": "session_01ABC", "taskId": "task", "userFork": false,
                                    "deletedParent": ["sessionId": "remote:id", "title": "Parent", "extra": "keep"], "wakeParent": true]
        try writeNativeChat(in: a, lines: [one, line("assistant", "two")], lastActivity: 200)
        try writeNativeChat(in: b, lines: [one], lastActivity: 100,
                            extra: ["forkedFromSessionId": "session_01ABC", "spawnedFrom": spawn, "lineageDetached": false])
        try ClaudeChats.apply(transfer(to: b, spaces: [a, b]), backups: backups)
        let object = try record(b)
        XCTAssertEqual(object["forkedFromSessionId"] as? String, "session_01ABC")
        XCTAssertEqual(object["spawnedFrom"] as? NSDictionary, spawn as NSDictionary)
        XCTAssertEqual(object["lineageDetached"] as? Bool, false)
        var invalid: [String: Any] = ["forkedFromSessionId": chatID, "spawnedFrom": ["sessionId": 3, "taskId": "task"], "lineageDetached": 1]
        ChatLineage.cleanOwn(in: &invalid, sessionID: chatID)
        XCTAssertTrue(invalid.isEmpty)
    }

    func testPendingStagedFileSurvivesConflictingOrUnreadableNatives() throws {
        for unreadable in [false, true] {
            let a = space("A-\(unreadable)"), b = space("B-\(unreadable)")
            try writeNativeChat(in: a, lines: [unreadable ? "bad\n" : line("user", "native one")], lastActivity: 100, trusted: false)
            _ = try namespace(b)
            let second = a.config.appendingPathComponent("projects/second/\(cli).jsonl")
            try FileManager.default.createDirectory(at: second.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((unreadable ? "bad\n" : line("user", "native two") + "\n").utf8).write(to: second)
            let staging = try namespace(a).appendingPathComponent("imported-staging/\(cli).jsonl")
            try FileManager.default.createDirectory(at: staging.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((line("user", "pending") + "\n").utf8).write(to: staging)
            try editRecord(a) { $0["stagedTranscriptPath"] = staging.path }
            let next = try transfer(to: b, spaces: [a, b])
            XCTAssertEqual(next.sourceTranscript, staging)
            try ClaudeChats.apply(next, backups: backups)
            XCTAssertEqual(try transfer(to: b, spaces: [a, b]).kind, .upToDate)
        }
    }

    func testApplyFailureIsExcludedFromPendingUntilInputsChange() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one"), line("assistant", "two")], lastActivity: 200)
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 100)
        let blockedBackups = root.appendingPathComponent("not-a-folder")
        try Data("file".utf8).write(to: blockedBackups)
        var cache = ChatSyncCache()
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: blockedBackups, cache: &cache)
        XCTAssertEqual(result.issues.count, 1)
        XCTAssertNotNil(cache.failed[ChatSyncCache.key(b.spaceID, chatID)])
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache, otherSpacesOnly: true), 0)
        try append("three", to: native(a))
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache, otherSpacesOnly: true), 1)
    }

    func testMissingOrUnreadableTargetDropsTranscriptCoupledKeys() throws {
        for missing in [false, true] {
            let a = space("A-\(missing)"), b = space("B-\(missing)")
            try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 200)
            try writeNativeChat(in: b, lines: [line("user", "old")], lastActivity: 100,
                                extra: ["rewindEdges": ["stale"], "transcriptCuts": ["stale"], "transcriptModelStates": ["stale"]])
            if missing { try FileManager.default.removeItem(at: native(b)) }
            else { try Data("bad\n".utf8).write(to: native(b)) }
            let next = try transfer(to: b, spaces: [a, b])
            XCTAssertEqual(next.kind, .update)
            XCTAssertFalse(next.extendsTarget)
            try ClaudeChats.apply(next, backups: backups)
            let object = try record(b)
            for key in ["rewindEdges", "transcriptCuts", "transcriptModelStates"] { XCTAssertNil(object[key]) }
        }
    }

    func testPrimaryNamespaceFollowsSymlinkedSignedInAccount() throws {
        let a = space("A")
        _ = try namespace(a, account: "stale")
        let actual = root.appendingPathComponent("actual-account")
        try FileManager.default.createDirectory(at: actual.appendingPathComponent("org"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: a.sessions.appendingPathComponent("current"), withDestinationURL: actual)
        try Data(#"{"lastKnownAccountUuid":"current"}"#.utf8).write(to: a.sessions.deletingLastPathComponent().appendingPathComponent("config.json"))
        XCTAssertEqual(try ClaudeChats.primaryNamespace(in: a).resolvingSymlinksInPath(), actual.appendingPathComponent("org"))
    }

    func testTornFinalLineIsIgnoredButBadMiddleLineThrows() throws {
        let good = Data((line("user", "one") + "\n").utf8)
        let normalized = try ClaudeChats.normalizedTranscript(good, cwds: [cwd])
        XCTAssertEqual(try ClaudeChats.normalizedTranscript(good + Data("{\"type\":".utf8), cwds: [cwd]), normalized)
        XCTAssertThrowsError(try ClaudeChats.normalizedTranscript(good + Data("[]".utf8), cwds: [cwd]))
        XCTAssertThrowsError(try ClaudeChats.normalizedTranscript(good + Data("{bad}\n".utf8), cwds: [cwd]))
        XCTAssertThrowsError(try ClaudeChats.normalizedTranscript(good + Data("{bad}\n".utf8) + good, cwds: [cwd]))
        XCTAssertEqual(try ClaudeChats.normalizedTranscript(Data(line("user", "one").utf8), cwds: [cwd]), normalized)
    }
}
