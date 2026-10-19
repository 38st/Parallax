import XCTest
@testable import Parallax

final class SyncCacheTests: ChatFixture {
    func testCachedSyncsLeaveNothingForAFreshSync() throws {
        let a = space("A"), b = space("B"), c = space("C")
        let spaces = [a, b, c]
        for space in spaces { _ = try namespace(space) }
        try writeNativeChat(in: a, lines: [line("user", "trusted")], lastActivity: 100)
        try writeNativeChat(in: a, lines: [line("user", "untrusted")], lastActivity: 110, chatID: "local_untrusted", cliSessionID: "untrusted", trusted: false)
        try writeNativeChat(in: a, lines: ["{broken"], lastActivity: 120, chatID: "local_broken", cliSessionID: "broken")
        try writeNativeChat(in: b, lines: [line("user", "only B")], lastActivity: 100, chatID: "local_b", cliSessionID: "b")
        var cache = ChatSyncCache()
        func verify() throws {
            for target in spaces {
                let cached = ClaudeChats.syncAll(to: target, spaces: spaces, backups: backups, cache: &cache)
                let fresh = ClaudeChats.syncAll(to: target, spaces: spaces, backups: backups)
                XCTAssertEqual(fresh.transferred, 0, "\(target.name): \(fresh.summary ?? "")")
                XCTAssertTrue(Set(fresh.issues).isSubset(of: Set(cached.issues)))
            }
        }
        try verify()
        try append("continued", to: native(a))
        try verify()
        try editRecord(b) { $0["lastFocusedAt"] = 500 }
        try verify()
        // Deleted before its last use elsewhere, so the deletion stays in C.
        let tombstone = try namespace(c).appendingPathComponent("deleted_" + chatID.dropFirst(6))
        try Data("50".utf8).write(to: tombstone)
        try verify()
        try FileManager.default.removeItem(at: tombstone)
        try verify()
        // Archived before its last use elsewhere, so the archive stays in B.
        try editRecord(b) { $0["isArchived"] = true }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0.05)], ofItemAtPath: recordURL(b).path)
        try verify()
        try editRecord(b) { $0["isArchived"] = false }
        try verify()
        // Native continuation behind an untrusted staging pointer, then trust promotion.
        let untrustedNative = native(b, cli: "untrusted")
        let staged = URL(fileURLWithPath: try XCTUnwrap(record(b, id: "local_untrusted")["stagedTranscriptPath"] as? String))
        try Data(contentsOf: staged).write(to: untrustedNative)
        try append("native continuation", to: untrustedNative)
        try verify()
        try editRecord(b, id: "local_untrusted") { $0["resumeConfirmed"] = true }
        try verify()
        let duplicate = a.config.appendingPathComponent("projects/duplicate/" + cli + ".jsonl")
        try FileManager.default.createDirectory(at: duplicate.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contentsOf: native(a)).write(to: duplicate)
        try verify()
        try FileManager.default.removeItem(at: native(c))
        try verify()
        let record = try recordURL(a)
        try Data(contentsOf: record).write(to: record, options: .atomic)
        try verify()
        // A newer deletion carries over to every space.
        try Data("1000".utf8).write(to: tombstone)
        try verify()
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.path))
    }

    func testWritesDuringPrepareAreNeverStampedAsSettled() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        _ = try namespace(b)
        var cache = ChatSyncCache()
        _ = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache)
        var changed = false
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache, read: { url in
            let data = try Data(contentsOf: url)
            if !changed && url.resolvingSymlinksInPath() == self.native(a).resolvingSymlinksInPath() {
                changed = true
                try self.append("raced", to: url)
            }
            return data
        })
        XCTAssertEqual(result.transferred, 0)
        XCTAssertNil(cache.stamps[ChatSyncCache.key(b.spaceID, chatID)])
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: cache), 1)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache).transferred, 1)
    }

    func testDuplicateSpaceIdsDoNotTrapAndCachePrunesRemovedChatsAndSpaces() throws {
        let a = space("A"), b = space("B")
        XCTAssertEqual(ClaudeChats.projectFolders(for: [a, a, b]).count, 2)
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        _ = try namespace(b)
        var cache = ChatSyncCache()
        for _ in 0..<2 { _ = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache) }
        let absent = ChatSyncCache.key(UUID(), "local_absent")
        cache.stamps[absent] = "old"; cache.failed[absent] = "old"
        try FileManager.default.removeItem(at: recordURL(a))
        try FileManager.default.removeItem(at: recordURL(b))
        _ = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache)
        XCTAssertTrue(cache.stamps.isEmpty); XCTAssertTrue(cache.failed.isEmpty)
    }
}
