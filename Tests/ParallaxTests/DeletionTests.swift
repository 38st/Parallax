import XCTest
@testable import Parallax

final class DeletionTests: ChatFixture {
    /// Deletes the chat in a space the way Claude does: the record goes and a marker holding the time stays.
    private func deleteInClaude(_ space: ClaudeChats.SpaceFolders, at time: Int) throws {
        try FileManager.default.removeItem(at: recordURL(space))
        try Data(String(time).utf8).write(to: namespace(space).appendingPathComponent("deleted_" + chatID.dropFirst(6)))
    }

    func testDeletionCarriesOverWithBackupAndKeepsMessages() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        try writeNativeChat(in: b, lines: [line("user", "one")], lastActivity: 100)
        try deleteInClaude(a, at: 200)
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: ChatSyncCache(), otherSpacesOnly: true), 1)

        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertEqual(result.deleted, 1)
        XCTAssertTrue(result.issues.isEmpty, "\(result.issues)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: try recordURL(b).path))
        let marker = try namespace(b).appendingPathComponent("deleted_" + chatID.dropFirst(6))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "200")
        XCTAssertEqual(try savedFiles().map(\.lastPathComponent), [chatID + ".json"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: native(b).path), "Messages stay on disk")
        XCTAssertTrue(ClaudeChats.scan([a, b]).isEmpty)
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: [a, b], cache: ChatSyncCache(), otherSpacesOnly: true), 0)
    }

    func testChatUsedAfterTheDeletionIsKept() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        try writeNativeChat(in: b, lines: [line("user", "one"), line("user", "two")], lastActivity: 300)
        try deleteInClaude(a, at: 200)
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertEqual(result.deleted, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try recordURL(b).path))
        XCTAssertTrue(ClaudeChats.deletedElsewhere(ClaudeChats.scan([a, b]), spaces: [a, b]).isEmpty)
    }

    func testDeletedChatIsNotCopiedOnwardAndLeavesTheList() throws {
        let a = space("A"), b = space("B"), c = space("C")
        try writeNativeChat(in: a, lines: [line("user", "one")], lastActivity: 100)
        try writeNativeChat(in: c, lines: [line("user", "one")], lastActivity: 100)
        _ = try namespace(b)
        try deleteInClaude(a, at: 200)
        let spaces = [a, b, c]
        XCTAssertEqual(ClaudeChats.deletedElsewhere(ClaudeChats.scan(spaces), spaces: spaces).map(\.chat.id), [chatID])
        XCTAssertEqual(try ClaudeChats.pendingChatCount(to: b, spaces: spaces, cache: ChatSyncCache(), otherSpacesOnly: true), 0)
        let result = ClaudeChats.syncAll(to: b, spaces: spaces, backups: backups)
        XCTAssertEqual(result.transferred, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try recordURL(b).path))
    }
}
