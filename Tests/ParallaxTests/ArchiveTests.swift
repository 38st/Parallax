import XCTest
@testable import Parallax

final class ArchiveTests: ChatFixture {
    /// Archives the chat in a space the way Claude does, at the given time in milliseconds.
    private func archiveInClaude(_ space: ClaudeChats.SpaceFolders, at time: Double) throws {
        try editRecord(space) { $0["isArchived"] = true }
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: time / 1000)],
                                              ofItemAtPath: recordURL(space).path)
    }

    func testArchiveCarriesOverWithBackup() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100_000)
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 100_000)
        try archiveInClaude(a, at: 200_000)
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: ChatSyncCache(), otherSpacesOnly: true), 1)

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertEqual(result.archived, 1)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertEqual(try record(b)["isArchived"] as? Bool, true)
        XCTAssertEqual(try record(b)["title"] as? String, "Fix the build")
        XCTAssertEqual(try savedFiles().map(\.lastPathComponent), [chatID + ".json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: native(b).path), "Messages stay on disk")
        XCTAssertTrue(ClaudeChats.scan([a, b]).isEmpty)
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: ChatSyncCache(), otherSpacesOnly: true), 0)
    }

    func testChatUsedAfterTheArchiveIsKept() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100_000)
        try writeNativeChat(in: b, lines: [line("user", "one"), line("user", "two")], lastActivity: 300_000)
        try archiveInClaude(a, at: 200_000)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertEqual(result.archived, 0)
        XCTAssertNotEqual(try record(b)["isArchived"] as? Bool, true)
        XCTAssertTrue(ClaudeChats.archivedElsewhere(ClaudeChats.scan([a, b]), spaces: [a, b]).isEmpty)
    }

    func testArchivedChatIsNotCopiedOnward() throws {
        let a = space("A"), b = space("B"), c = space("C")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100_000)
        try writeNativeChat(in: c, lines: [line("user", "one")], lastActivity: 100_000)
        _ = try namespace(b)
        try archiveInClaude(a, at: 200_000)
        let spaces = [a, b, c]
        XCTAssertEqual(ClaudeChats.archivedElsewhere(ClaudeChats.scan(spaces), spaces: spaces).map(\.id), [chatID])
        let result = ClaudeChats.syncAll(to: b, spaces: spaces, backups: backups)
        XCTAssertEqual(result.transferred, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try recordURL(b).path))
    }
}
