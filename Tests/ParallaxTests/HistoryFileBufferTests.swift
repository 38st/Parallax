import XCTest
@testable import Parallax

final class HistoryFileBufferTests: XCTestCase {
    func testUnlinkedSnapshotOutlivesWriterAndCannotBeChangedAfterFinishing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HistoryBuffer-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var writer: HistoryFileBuffer? = try HistoryFileBuffer(directory: root)
        let bytes = Data(repeating: 65, count: 150_000)
        try writer?.append(bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
        let snapshot = try XCTUnwrap(writer?.finish())
        XCTAssertThrowsError(try writer?.append(Data([66])))
        XCTAssertThrowsError(try writer?.finish())
        writer = nil
        XCTAssertEqual(snapshot, bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testSnapshotSupportsDataMutationWithoutChangingOtherCopies() throws {
        let writer = try HistoryFileBuffer()
        try writer.append(Data(repeating: 65, count: 150_000))
        var snapshot = try writer.finish()
        snapshot[0] = 66
        let copy = snapshot
        snapshot[1] = 67
        XCTAssertEqual(snapshot.prefix(2), Data([66, 67]))
        XCTAssertEqual(copy.prefix(2), Data([66, 65]))
    }

    func testLineReaderHandlesBlankLinesCRLFAndUnterminatedFinalLine() throws {
        let writer = try HistoryFileBuffer()
        try writer.append(Data("\nfirst\r\n\nlast".utf8))
        var lines: [Data] = []
        HistoryFileBuffer.forEachLine(in: try writer.finish()) { lines.append($0) }
        XCTAssertEqual(lines, [Data("first\r".utf8), Data("last".utf8)])
        let empty = try HistoryFileBuffer()
        XCTAssertEqual(try empty.finish(), Data())
    }

    func testUncappedReadSnapshotsBytesBeforeProviderFileIsRewritten() throws {
        let fixture = try ClaudeConversationFixture()
        defer { try? fixture.remove() }
        let path = try fixture.source.transcriptPath(for: fixture.conversation())
        let original = try Data(contentsOf: fixture.sourceTranscriptURL)
        let snapshot = try fixture.source.files.readFile(at: path)
        try Data("changed".utf8).write(to: fixture.sourceTranscriptURL)
        XCTAssertEqual(snapshot, original)
        XCTAssertEqual(try fixture.source.files.readFile(at: path), Data("changed".utf8))
    }

    func testCancelledReadStopsBeforeReturningSnapshot() async throws {
        let fixture = try ClaudeConversationFixture()
        defer { try? fixture.remove() }
        let files = fixture.source.files
        let path = try fixture.source.transcriptPath(for: fixture.conversation())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try files.readFile(at: path)
        }
        do {
            _ = try await task.value
            XCTFail("A cancelled read must stop")
        } catch is CancellationError { }
    }
}
