import XCTest
@testable import Parallax

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[Int]] = []
    func append(_ checked: Int, _ total: Int) { lock.lock(); defer { lock.unlock() }; entries.append([checked, total]) }
    var values: [[Int]] { lock.lock(); defer { lock.unlock() }; return entries }
}

final class SyncReportingTests: ChatFixture {
    func testSyncReportsProgressForEveryChatAndSkipsSettledChatsSilently() throws {
        let a = space("A"), b = space("B")
        _ = try namespace(b)
        for id in ["one", "two", "three"] { try writeNativeChat(in: a, lines: [line("user", id)], lastActivity: 100, chatID: "local_" + id, cliSessionID: id) }
        var cache = ChatSyncCache()
        let recorder = ProgressRecorder()
        let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache, progress: { recorder.append($0, $1) })
        XCTAssertEqual(result.total, 3); XCTAssertEqual(result.checked, 3)
        XCTAssertEqual(recorder.values, [[1, 3], [2, 3], [3, 3]])
        _ = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache)
        let empty = ProgressRecorder()
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache, progress: { empty.append($0, $1) }).total, 0)
        XCTAssertTrue(empty.values.isEmpty)
    }

    func testCancelledSyncStopsBetweenChatsAndRecordsNoUnprocessedStamp() async throws {
        let a = space("A"), b = space("B")
        _ = try namespace(b)
        for id in ["one", "two", "three"] { try writeNativeChat(in: a, lines: [line("user", id)], lastActivity: 100, chatID: "local_" + id, cliSessionID: id) }
        let backups = backups
        let (result, cache) = await Task.detached {
            var cache = ChatSyncCache()
            let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache, progress: { done, _ in
                if done == 1 { withUnsafeCurrentTask { $0?.cancel() } }
            })
            return (result, cache)
        }.value
        XCTAssertTrue(result.stopped); XCTAssertEqual(result.checked, 1); XCTAssertEqual(result.transferred, 1)
        XCTAssertEqual(cache.stamps.count, 1); XCTAssertTrue(cache.failed.isEmpty)
        XCTAssertEqual(ClaudeChats.scan([b]).count, 1)
        XCTAssertFalse(try FileManager.default.subpathsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".tmp") })
        var resumed = cache
        XCTAssertEqual(ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &resumed).transferred, 2)
    }

    func testCancelledSyncChecksNothing() async throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi")], lastActivity: 100)
        _ = try namespace(b)
        let backups = backups
        let (result, cache) = await Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            var cache = ChatSyncCache()
            let result = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups, cache: &cache)
            return (result, cache)
        }.value
        XCTAssertTrue(result.stopped); XCTAssertEqual(result.checked, 0); XCTAssertEqual(result.transferred, 0)
        XCTAssertTrue(cache.stamps.isEmpty); XCTAssertTrue(cache.failed.isEmpty); XCTAssertTrue(ClaudeChats.scan([b]).isEmpty)
    }

    func testSummaryExcludesShownIssuesButKeepsNotes() {
        var result = ClaudeChats.SyncResult()
        result.transferred = 1; result.notes = ["Backed up in /scratch/Backups."]; result.issues = ["Broken chat."]
        XCTAssertEqual(result.summary(excluding: ["Broken chat."]), "Carried over 1 chat.\n\nBacked up in /scratch/Backups.")
        result.notes = []
        XCTAssertNil(result.summary(excluding: ["Broken chat."]))
    }

    func testSummaryCapsIssuesWithPointerAndAdviceFitsCause() throws {
        var result = ClaudeChats.SyncResult()
        result.issues = (0..<7).map { "issue \($0)" }
        let summary = try XCTUnwrap(result.summary)
        XCTAssertTrue(summary.contains("issue 4")); XCTAssertFalse(summary.contains("issue 5"))
        XCTAssertTrue(summary.contains("…and 2 more. See Last carry-over on the Claude page."))
        let a = space("A"), b = space("B")
        _ = try namespace(b)
        try writeNativeChat(in: a, lines: ["{bad"], lastActivity: 100)
        let unsupported = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertFalse(try XCTUnwrap(unsupported.summary).contains("try again"))
        try FileManager.default.removeItem(at: native(a))
        let missing = ClaudeChats.syncAll(to: b, spaces: [a, b], backups: backups)
        XCTAssertTrue(try XCTUnwrap(missing.summary).contains("Open this chat once"))
    }

    func testApplyRefusesAnEmptyTranscript() throws {
        let a = space("A"), b = space("B")
        try writeNativeChat(in: a, lines: [line("user", "hi"), line("user", "more")], lastActivity: 200)
        _ = try namespace(b)
        var add = try transfer(to: b, spaces: [a, b])
        add.transcript = Data()
        XCTAssertThrowsError(try ClaudeChats.apply(add, backups: backups))
        XCTAssertTrue(ClaudeChats.scan([b]).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.config.path))
        try writeNativeChat(in: b, lines: [line("user", "hi")], lastActivity: 100)
        var update = try transfer(to: b, spaces: [a, b])
        XCTAssertEqual(update.kind, .update)
        let original = try Data(contentsOf: native(b)), record = try Data(contentsOf: recordURL(b))
        update.transcript = Data()
        XCTAssertThrowsError(try ClaudeChats.apply(update, backups: backups))
        XCTAssertEqual(try Data(contentsOf: native(b)), original)
        XCTAssertEqual(try Data(contentsOf: recordURL(b)), record)
        XCTAssertTrue(try savedFiles().isEmpty)
    }
}
