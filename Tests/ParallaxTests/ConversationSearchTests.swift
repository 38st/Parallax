import XCTest
@testable import Parallax

final class ConversationSearchTests: XCTestCase {
    func testSearchMatchesTitleAndProjectOrdersByActivityAndExcludesArchived() {
        func conversation(_ id: String, title: String, project: String, activity: Double, archived: Bool = false) -> LibraryConversation {
            let revision = ConversationRevision(digest: id, originalDigest: id, parent: nil, sourceProfileID: UUID(),
                sourceAccountID: "synthetic", sourceOrganizationID: "synthetic", cliSessionID: id,
                workingDirectory: project, createdAt: 0, lastActivityAt: activity)
            return LibraryConversation(id: id, title: title, head: id, revisions: [id: revision], archived: archived)
        }
        let conversations = [
            conversation("a", title: "Fix navigation", project: "/synthetic/Parallax", activity: 20),
            conversation("b", title: "Review navigation", project: "/synthetic/Parallax", activity: 30),
            conversation("c", title: "Fix history", project: "/synthetic/Other", activity: 40),
            conversation("d", title: "Fix navigation", project: "/synthetic/Parallax", activity: 50, archived: true)
        ]
        let library = ConversationLibrary(id: UUID(), applicationStorageID: UUID(), bindings: [:],
            conversations: Dictionary(uniqueKeysWithValues: conversations.map { ($0.id, $0) }))
        XCTAssertEqual(ConversationSearch.results(in: library, query: "navigation PARALLAX").map(\.id), ["b", "a"])
        XCTAssertEqual(ConversationSearch.results(in: library, query: "").map(\.id), ["c", "b", "a"])
        XCTAssertTrue(ConversationSearch.results(in: library, query: "missing").isEmpty)
        XCTAssertNil(library.selectedConversationID, "Search must never choose a conversation implicitly")
    }
}
