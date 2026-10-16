import Darwin
import XCTest
@testable import Parallax

final class SyncPerformanceTests: ChatFixture {
    func testLineRangesMatchSplit() {
        let inputs = ["", "\n", "\n\n", "a", "a\n", "\na", "a\n\nb", "a\r\nb\r\n", " \n\t\n", String(repeating: "x", count: 100_000)]
            .map { Data($0.utf8) } + [Data("xx\na\n\nb".utf8).dropFirst(3)]
        for data in inputs { XCTAssertEqual(ClaudeChats.lineRanges(data).map { data[$0] }, data.split(separator: 0x0A)) }
    }

    func testHasPrefixMatchesStartsWith() {
        let inputs = ["", "a", "ab", "abc", "abd"].map { Data($0.utf8) } + [Data("xxabc".utf8).dropFirst(2)]
        for data in inputs { for prefix in inputs { XCTAssertEqual(ClaudeChats.hasPrefix(data, prefix), data.starts(with: prefix)) } }
    }

    func testNormalizationMemoryDoesNotAccumulate() async throws {
        let row = line("user", String(repeating: "x", count: 1024)) + "\n"
        let data = Data(String(repeating: row, count: 4 * 1024 * 1024 / row.utf8.count).utf8)
        let cwds: Set<String> = [cwd]
        let growth = try await Task.detached {
            var before = malloc_statistics_t()
            malloc_zone_statistics(nil, &before)
            for _ in 0..<6 {
                let normalized = try ClaudeChats.normalizedTranscript(data, cwds: cwds)
                guard !normalized.isEmpty else { throw ChatError.transcriptMissing }
            }
            var after = malloc_statistics_t()
            malloc_zone_statistics(nil, &after)
            return Int64(after.size_in_use) - Int64(before.size_in_use)
        }.value
        XCTAssertLessThan(growth, Int64(data.count * 3))
    }

    func testSettledChatsAreSkippedAndChangedChatReadsOnlyItsOwnFiles() throws {
        let a = space("A"), b = space("B")
        _ = try namespace(b)
        for id in ["one", "two"] {
            try writeNativeChat(in: a, lines: [line("user", id)], lastActivity: 100, chatID: "local_" + id, cliSessionID: id)
        }
        var cache = ChatSyncCache()
        var reads: [URL] = []
        func sync() -> ClaudeChats.SyncResult {
            reads = []
            return ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache, read: { url in
                reads.append(url); return try Data(contentsOf: url)
            })
        }
        var result = sync()
        XCTAssertEqual(result.checked, 2); XCTAssertEqual(result.transferred, 2)
        result = sync()
        XCTAssertEqual(result.checked, 2); XCTAssertEqual(result.transferred, 0)
        result = sync()
        XCTAssertEqual(result.checked, 0); XCTAssertEqual(result.transferred, 0); XCTAssertTrue(reads.isEmpty)
        try append("new", to: native(a, cli: "one"))
        result = sync()
        XCTAssertEqual(result.checked, 1); XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(Set(reads.map(\.lastPathComponent)), ["one.jsonl"])
    }

    func testEachFileIsNormalizedOncePerPrepare() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("user", "more")], lastActivity: 200, trusted: false)
        _ = try namespace(b)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100, trusted: false,
                            extra: ["stagedTranscriptPath": try XCTUnwrap(record(b)["stagedTranscriptPath"])])
        let extra = try namespace(b, account: "other")
        try Data(contentsOf: recordURL(b)).write(to: extra.appendingPathComponent(chatID + ".json"))
        for damaged in [false, true] {
            if damaged { try Data("{bad".utf8).write(to: native(b)) }
            var counts: [String: Int] = [:]
            let chat = try XCTUnwrap(ClaudeChats.scan([a, b]).first)
            _ = try ClaudeChats.prepare(chat: chat, target: b, spaces: [a, b], read: { url in
                counts[url.path, default: 0] += 1
                return try Data(contentsOf: url)
            })
            XCTAssertFalse(counts.isEmpty)
            XCTAssertTrue(counts.values.allSatisfy { $0 == 1 }, "\(counts)")
        }
    }

    func testDestinationCopyIsMatchedByIdentityWithoutTargetNamespace() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("user", "more")], lastActivity: 200)
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100)
        let extra = try namespace(b, account: "other")
        let staging = extra.appendingPathComponent("imported-staging/fork")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data((line("user", "different") + "\n").utf8).write(to: staging.appendingPathComponent("different.jsonl"))
        var object = try record(b)
        object["cliSessionId"] = "different"
        object["stagedTranscriptPath"] = staging.appendingPathComponent("different.jsonl").path
        try JSONSerialization.data(withJSONObject: object).write(to: extra.appendingPathComponent(chatID + ".json"))
        var chat = try XCTUnwrap(ClaudeChats.scan([a, b]).first)
        for reverse in [false, true] {
            if reverse { chat.copies.reverse() }
            let expected = try XCTUnwrap(chat.copies.first { $0.spaceID == b.spaceID })
            let result = try ClaudeChats.prepare(chat: chat, target: b, spaces: [a, b])
            XCTAssertEqual(result.kind, expected.cliSessionID == "different" ? .replaceDiverged : .update)
            XCTAssertEqual(result.targetRecord?.deletingLastPathComponent(), expected.namespace)
        }
    }

    func testPendingChatCount() throws {
        let a = space("A"), b = space("B")
        var cache = ChatSyncCache()
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 0)
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        XCTAssertThrowsError(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache))
        _ = try namespace(b)
        let pending = try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache).checked, pending)
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 1)
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache, otherSpacesOnly: true), 0)
        _ = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache)
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 0)
        try append("more", to: native(a))
        for other in [false, true] { XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache, otherSpacesOnly: other), 1) }
        _ = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache)
        _ = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache)
        try append("target only", to: native(b))
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 1)
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache, otherSpacesOnly: true), 0)
        _ = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache)
        try writeNativeChat(in: b, lines: [line("user", "target chat")], lastActivity: 100, chatID: "local_own", cliSessionID: "own")
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 1)
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache, otherSpacesOnly: true), 0)
        _ = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache)
        try writeNativeChat(in: a, lines: ["{broken"], lastActivity: 300, chatID: "local_failed", cliSessionID: "failed")
        for _ in 0..<2 {
            let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache)
            XCTAssertEqual(result.issues.count, 1); XCTAssertEqual(result.checked, 1)
            XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 0)
        }
    }

    func testStampSeesEveryInputAndNeverHidesUndeletes() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        _ = try namespace(b)
        var cache = ChatSyncCache()
        func settle() throws {
            for _ in 0..<2 { _ = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache) }
            XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 0)
        }
        try settle()
        let changes: [() throws -> Void] = [
            { try self.editRecord(b) { $0["lastFocusedAt"] = 300 } },
            { let url = try self.recordURL(b); try Data(contentsOf: url).write(to: url, options: .atomic) },
            { try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 42)], ofItemAtPath: self.native(a).path) },
            {
                let url = a.config.appendingPathComponent("projects/duplicate/" + self.cli + ".jsonl")
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: self.native(a)).write(to: url)
            },
        ]
        for change in changes { try change(); XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 1); try settle() }
        let tombstone = try namespace(b).appendingPathComponent("deleted_" + chatID.dropFirst(6))
        try Data().write(to: tombstone)
        try settle()
        try FileManager.default.removeItem(at: tombstone)
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 1)
        try settle()
        try editRecord(b) { $0["isArchived"] = true }
        try settle()
        try editRecord(b) { $0["isArchived"] = false }
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 1)
    }

    func testStampsAreScopedToTargetAndNamespace() throws {
        let a = space("A"), b = space("B"), c = space("C")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        _ = try namespace(b); _ = try namespace(c)
        var cache = ChatSyncCache()
        for _ in 0..<2 { _ = ClaudeChats.syncAll(to: b, spaces: [a, b, c], backups: backups, cache: &cache) }
        XCTAssertEqual(ClaudeChats.syncAll(to: c, spaces: [a, b, c], backups: backups, cache: &cache).transferred, 1)
        let newer = try namespace(b, account: "new")
        try Data(#"{"lastKnownAccountUuid":"new"}"#.utf8).write(to: b.sessions.deletingLastPathComponent().appendingPathComponent("config.json"))
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b, c], cache: cache), 1)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b, c], backups: backups, cache: &cache).transferred, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newer.appendingPathComponent(chatID + ".json").path))
    }

    func testStampsCoverClaudesActualStagedCandidate() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, trusted: false)
        let folder = try namespace(a).appendingPathComponent("imported-staging/fork")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let actual = folder.appendingPathComponent(cli + ".jsonl")
        try Data(contentsOf: native(a)).write(to: actual)
        try editRecord(a) { $0["stagedTranscriptPath"] = folder.appendingPathComponent("parent.jsonl").path }
        _ = try namespace(b)
        var cache = ChatSyncCache()
        for _ in 0..<2 { _ = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache) }
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 0)
        try append("continued", to: actual)
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 1)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache).transferred, 1)
    }

    func testStampCacheIsDisposableAndVersionForcesLineageRepair() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, extra: ["forkedFromSessionId": "local_parent"])
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100)
        let chat = try XCTUnwrap(ClaudeChats.scan([a, b]).first)
        let stamp = try XCTUnwrap(ClaudeChats.syncStamp(chat, target: b, targetNamespace: ClaudeChats.primaryNamespace(in: b), spaces: [a, b], projectFolders: ClaudeChats.projectFolders(for: [a, b])))
        var stale = ChatSyncCache()
        stale.version = "0-x"
        stale.stamps[ChatSyncCache.key(b.spaceID, chatID)] = stamp
        let url = root.appendingPathComponent("cache.json")
        try JSONEncoder().encode(stale).write(to: url)
        XCTAssertTrue(ChatSyncCache.load(from: url).stamps.isEmpty)
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: stale), 1)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &stale).transferred, 1)
        try Data("{broken".utf8).write(to: url)
        XCTAssertTrue(ChatSyncCache.load(from: url).stamps.isEmpty)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &stale)
        XCTAssertEqual(result.checked, 1)
        // Explicit preparation always verifies, irrespective of a settled cache.
        var reads = 0
        _ = try ClaudeChats.prepare(chat: ClaudeChats.scan([a, b])[0], target: b, spaces: [a, b], read: { url in reads += 1; return try Data(contentsOf: url) })
        XCTAssertGreaterThan(reads, 0)
        if ChatSyncCache.currentVersion != nil {
            stale.save(to: url)
            XCTAssertEqual(ChatSyncCache.load(from: url).stamps, stale.stamps)
        } else {
            try FileManager.default.removeItem(at: url)
            stale.save(to: url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testDeletedChatWithCorruptNewestSourceProducesNoIssue() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: ["{bad"], lastActivity: 100)
        let ns = try namespace(b)
        try Data().write(to: ns.appendingPathComponent("deleted_" + chatID.dropFirst(6)))
        var cache = ChatSyncCache()
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache, read: { _ in XCTFail("Deleted chats must not read transcripts"); return Data() })
        XCTAssertEqual(result.checked, 1); XCTAssertEqual(result.transferred, 0); XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache).checked, 0)
    }
}
