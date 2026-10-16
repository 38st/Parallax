import XCTest
@testable import Parallax

final class StagingTests: ChatFixture {
    func testStagedUpdatesKeepOneStagingFolderPerChat() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, trusted: false)
        let ns = try namespace(b)
        for turn in 0..<3 {
            if turn > 0 { try append("turn-\(turn)", to: native(a)) }
            XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
            let entries = try FileManager.default.contentsOfDirectory(atPath: ns.appendingPathComponent("imported-staging").path)
            XCTAssertEqual(entries.count, 1)
            let staged = try XCTUnwrap(record(b)["stagedTranscriptPath"] as? String)
            XCTAssertEqual(URL(fileURLWithPath: staged).deletingLastPathComponent().lastPathComponent, entries[0])
        }
        XCTAssertEqual(try savedFiles().count, 2)
        XCTAssertTrue(try savedFiles().allSatisfy { $0.pathExtension == "json" })
    }

    func testPromotionRemovesStagingAfterNativeWrite() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100, trusted: false)
        _ = try namespace(b)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        let staged = URL(fileURLWithPath: try XCTUnwrap(record(b)["stagedTranscriptPath"] as? String))
        let bytes = try Data(contentsOf: staged)
        try editRecord(a) { $0.removeValue(forKey: "importedFrom") }
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: native(b)), bytes)
        XCTAssertEqual(try savedFiles().count, 1)
        XCTAssertEqual(try savedFiles().first?.pathExtension, "json")
    }

    func testRawPrefixUpdateBacksUpRecordOnly() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        _ = try namespace(b)
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        try append("more", to: native(a))
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups).transferred, 1)
        XCTAssertEqual(try savedFiles().count, 1)
        XCTAssertEqual(try savedFiles().first?.lastPathComponent, chatID + ".json")
    }

    func testNativeDestinationWithClaudeOnlyLinesIsStillBackedUpWhenReplaced() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("user", "more")], lastActivity: 200)
        try writeNativeChat(in: b, lines: [#"{"type":"custom-title","title":"own"}"#, line("user", "hi"),
                            #"{"type":"progress","cwd":"/work/project","own":"state"}"#], lastActivity: 100)
        let bytes = try Data(contentsOf: native(b))
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(result.notes.count, 1)
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertTrue(try savedFiles().contains { (try? Data(contentsOf: $0)) == bytes })
    }

    func testCleanupKeepsReferencedForkArchivedAndSymlinkedFolders() throws {
        let b = space("B")
        try writeNativeChat(in: b, lines: [line("user", "hi"), line("user", "more")], lastActivity: 100)
        let ns = try namespace(b), staging = try namespace(b).appendingPathComponent("imported-staging")
        let bytes = try Data(contentsOf: native(b))
        func candidate(_ digit: Character, cli id: String? = nil, contents: Data? = nil) throws -> URL {
            let id = id ?? cli
            let folder = staging.appendingPathComponent(id + "-" + String(repeating: String(digit), count: 64))
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if let contents { try contents.write(to: folder.appendingPathComponent(id + ".jsonl")) }
            return folder
        }
        let empty = try candidate("0")
        let prefix = try candidate("1", contents: Data(bytes.prefix(30)))
        let referenced = try candidate("2", contents: bytes)
        let divergent = try candidate("3", contents: Data("unique".utf8))
        let extra = try candidate("4", contents: bytes)
        try Data().write(to: extra.appendingPathComponent("keep"))
        let fork = try candidate("5", contents: bytes)
        try Data("reference \(fork.lastPathComponent)".utf8).write(to: ns.appendingPathComponent("local_fork.json.tmp"))
        let unknown = try candidate("6", contents: bytes)
        try Data("\(unknown.lastPathComponent)".utf8).write(to: ns.appendingPathComponent("index"))
        let archived = try candidate("7", cli: "archived", contents: bytes)
        try Data(#"{"sessionId":"local_archived","cliSessionId":"archived","cwd":"/work/project","isArchived":true}"#.utf8)
            .write(to: ns.appendingPathComponent("local_archived.json"))
        let deleted = try candidate("8", cli: "deleted", contents: bytes)
        try Data(#"{"sessionId":"local_deleted","cliSessionId":"deleted","cwd":"/work/project"}"#.utf8)
            .write(to: ns.appendingPathComponent("local_deleted.json"))
        try Data().write(to: ns.appendingPathComponent("deleted_deleted"))
        let outside = root.appendingPathComponent("outside-staging")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let symlink = staging.appendingPathComponent(cli + "-" + String(repeating: "9", count: 64))
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        let flat = staging.appendingPathComponent(cli + ".jsonl")
        try bytes.write(to: flat)
        let wrong = staging.appendingPathComponent("not-a-digest")
        try FileManager.default.createDirectory(at: wrong, withIntermediateDirectories: true)
        try editRecord(b) { $0["unknownReference"] = referenced.lastPathComponent }
        ClaudeChats.removeUnusedStaging(in: ns, space: b)
        for removed in [empty, prefix] { XCTAssertFalse(FileManager.default.fileExists(atPath: removed.path)) }
        for kept in [referenced, divergent, extra, fork, unknown, archived, deleted, symlink, outside, flat, wrong] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path), kept.lastPathComponent)
        }
        // Any unreadable record or unusual top-level entry makes the whole sweep conservative.
        let pending = try candidate("a")
        let unreadable = ns.appendingPathComponent("local_unreadable.json")
        try Data("{broken".utf8).write(to: unreadable)
        ClaudeChats.removeUnusedStaging(in: ns, space: b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        try FileManager.default.removeItem(at: unreadable)
        let topLink = ns.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: topLink, withDestinationURL: flat)
        ClaudeChats.removeUnusedStaging(in: ns, space: b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        try FileManager.default.removeItem(at: topLink)
        let fifo = ns.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        ClaudeChats.removeUnusedStaging(in: ns, space: b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        try FileManager.default.removeItem(at: fifo)
        let denied = ns.appendingPathComponent("unreadable")
        try Data("private".utf8).write(to: denied)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: denied.path) }
        ClaudeChats.removeUnusedStaging(in: ns, space: b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
    }

    func testSweepDoesNotFollowStagingRootSymlinkOrPruneBackups() throws {
        let b = space("B")
        let ns = try namespace(b)
        let outside = root.appendingPathComponent("outside")
        let empty = outside.appendingPathComponent(cli + "-" + String(repeating: "a", count: 64))
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: ns.appendingPathComponent("imported-staging"), withDestinationURL: outside)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let saved = backups.appendingPathComponent("old-only-copy")
        try Data("only bytes".utf8).write(to: saved)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: saved.path)
        ClaudeChats.removeUnusedStaging(in: ns, space: b)
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.path))
        XCTAssertEqual(try Data(contentsOf: saved), Data("only bytes".utf8))
    }
}
