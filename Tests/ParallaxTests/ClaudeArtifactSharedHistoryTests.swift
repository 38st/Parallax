import XCTest
@testable import Parallax

final class ClaudeArtifactSharedHistoryTests: XCTestCase {
    func testReviewCountsUniqueReferencesAcrossSpacesWithoutChangingTranscripts() throws {
        let fixture = try ClaudeConversationFixture()
        defer { try? fixture.remove() }
        var messages = fixture.messages
        messages[0]["message"] = ["content": "https://claude.ai/artifact/first https://claude.ai/code/artifact/second"]
        try fixture.writeTranscript(messages, to: fixture.sourceTranscriptURL)
        let plan = try fixture.plan()
        let original = try Data(contentsOf: fixture.sourceTranscriptURL)
        let references = ClaudeArtifactReferenceScanner.scan(plan.transcript)
        XCTAssertEqual(references.count, 2)
        _ = ClaudeArtifactReview(references: references)
        _ = try fixture.source.copy(plan, destination: fixture.destination)
        XCTAssertEqual(try fixture.destination.files.readFile(at: plan.stagedTranscript), plan.transcript)
        try FileManager.default.removeItem(at: fixture.destinationRecordURL)
        let participants = [
            SharedHistoryParticipant(storageID: UUID(), files: fixture.source.files, provider: "claude"),
            SharedHistoryParticipant(storageID: UUID(), files: fixture.destination.files, provider: "claude"),
        ]
        XCTAssertEqual(try SharedHistoryService.claudeArtifactReferenceCount(participants), 2)
        XCTAssertEqual(try Data(contentsOf: fixture.sourceTranscriptURL), original)
        XCTAssertEqual(try fixture.destination.files.readFile(at: plan.stagedTranscript), plan.transcript)
    }

    func testReviewExcludesArchivedConversations() throws {
        let fixture = try ClaudeConversationFixture()
        defer { try? fixture.remove() }
        var messages = fixture.messages
        messages[0]["message"] = ["content": "https://claude.ai/artifact/archived"]
        try fixture.writeTranscript(messages, to: fixture.sourceTranscriptURL)
        var record = fixture.record
        record["isArchived"] = true
        try fixture.writeJSON(record, to: fixture.sourceRecordURL)
        let participant = SharedHistoryParticipant(storageID: UUID(), files: fixture.source.files, provider: "claude")
        XCTAssertEqual(try SharedHistoryService.claudeArtifactReferenceCount([participant]), 0)
    }

    func testReviewDoesNotReportZeroWhenTranscriptCannotBeRead() throws {
        let fixture = try ClaudeConversationFixture()
        defer { try? fixture.remove() }
        try FileManager.default.removeItem(at: fixture.sourceTranscriptURL)
        let participant = SharedHistoryParticipant(storageID: UUID(), files: fixture.source.files, provider: "claude")
        XCTAssertThrowsError(try SharedHistoryService.claudeArtifactReferenceCount([participant]))
    }
}
