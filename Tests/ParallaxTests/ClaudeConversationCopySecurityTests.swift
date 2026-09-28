import Darwin
import XCTest
@testable import Parallax

final class ClaudeConversationCopySecurityTests: XCTestCase {
    private func fixture() throws -> ClaudeConversationFixture {
        let fixture = try ClaudeConversationFixture()
        let root = fixture.root
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return fixture
    }

    func testSourceSymlinkAndHardLinkAreRejectedWithoutReadingOutsideStorage() throws {
        let fixture = try fixture()
        let external = fixture.root.appendingPathComponent("external.jsonl")
        try FileManager.default.moveItem(at: fixture.sourceTranscriptURL, to: external)
        for symbolic in [true, false] {
            if symbolic {
                try FileManager.default.createSymbolicLink(at: fixture.sourceTranscriptURL, withDestinationURL: external)
            } else {
                try FileManager.default.linkItem(at: external, to: fixture.sourceTranscriptURL)
            }
            XCTAssertThrowsError(try fixture.plan())
            try FileManager.default.removeItem(at: fixture.sourceTranscriptURL)
        }
        XCTAssertEqual(try fixture.destination.catalog().conversations.count, 1)
    }

    func testDestinationStagingSymlinkCannotWriteOutsideStorage() throws {
        let fixture = try fixture()
        let plan = try fixture.plan()
        let external = fixture.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let staging = fixture.destinationRoot.appendingPathComponent(
            plan.stagedTranscript.components.dropLast().joined(separator: "/"))
        try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: external)
        XCTAssertThrowsError(try fixture.source.copy(plan, destination: fixture.destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
        XCTAssertEqual(try fixture.destination.files.itemState(at: plan.publishedRecord), .missing)
    }

    func testReadRejectsParentReplacementBetweenTraversalAndOpen() throws {
        let fixture = try fixture()
        let parent = fixture.sourceTranscriptURL.deletingLastPathComponent()
        let moved = parent.appendingPathExtension("moved")
        let external = fixture.root.appendingPathComponent("external")
        let leaf = fixture.sourceTranscriptURL.lastPathComponent
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let files = try SecureManagedFileSystem(rootURL: fixture.sourceRoot, boundaryHook: { boundary in
            if case .beforeOpenFile(let name, _) = boundary, name == leaf {
                try FileManager.default.moveItem(at: parent, to: moved)
                try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: external)
            }
        })
        let source = ClaudeConversationCopyService(files: files)
        XCTAssertThrowsError(try source.prepare(fixture.conversation(), destination: fixture.destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: external.path), [])
    }

    func testSnapshotsRejectOversizedFilesAndNonregularFilesWithoutBlocking() throws {
        let fixture = try fixture()
        let path = try SecureManagedPath(["large"])
        try fixture.source.files.write(Data(repeating: 65, count: 20), to: path)
        XCTAssertThrowsError(try fixture.source.files.readFile(at: path, maximumBytes: 10))
        XCTAssertEqual(try fixture.source.files.readFile(at: path, maximumBytes: 20).count, 20)
        let fifo = fixture.sourceRoot.appendingPathComponent("fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try fixture.source.files.readFile(at: SecureManagedPath(["fifo"]), maximumBytes: 20))
        XCTAssertThrowsError(try fixture.source.files.readFile(at: SecureManagedPath(["UserData"]), maximumBytes: 20))
    }

    func testSourceRootReplacementInvalidatesPinnedService() throws {
        let fixture = try fixture()
        let conversation = try fixture.conversation()
        try FileManager.default.moveItem(at: fixture.sourceRoot, to: fixture.sourceRoot.appendingPathExtension("moved"))
        try FileManager.default.createDirectory(at: fixture.sourceRoot, withIntermediateDirectories: true)
        XCTAssertThrowsError(try fixture.source.prepare(conversation, destination: fixture.destination))
    }
}
