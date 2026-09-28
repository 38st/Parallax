import XCTest
@testable import Parallax

final class ClaudeArtifactReferenceScannerTests: XCTestCase {
    func testPlainURLsAreOrderedAndDeduplicatedWithoutChangingBytes() {
        let transcript = Data(#"{"text":"See (https://claude.ai/artifact/first), https://claude.ai/artifact/second. https://claude.ai/artifact/first"}"#.utf8)
        let original = transcript
        XCTAssertEqual(ClaudeArtifactReferenceScanner.scan(transcript), [
            ClaudeArtifactReference(url: "https://claude.ai/artifact/first", sourceFilePath: nil),
            ClaudeArtifactReference(url: "https://claude.ai/artifact/second", sourceFilePath: nil),
        ])
        XCTAssertEqual(transcript, original)
    }

    func testEscapedSlashesCodeArtifactsAndOtherArtifactPaths() {
        let transcript = Data(#"{"text":"https:\/\/claude.ai\/code\/artifact\/11111111-1111-4111-8111-111111111111 https://claude.ai/code/artifact/11111111-1111-4111-8111-111111111111 https://claude.ai/public/artifacts/second?view=1#content"}"#.utf8)
        XCTAssertEqual(ClaudeArtifactReferenceScanner.scan(transcript).map(\.url), [
            "https://claude.ai/code/artifact/11111111-1111-4111-8111-111111111111",
            "https://claude.ai/public/artifacts/second?view=1#content",
        ])
    }

    func testOtherClaudeURLsAndLookalikeHostsAreIgnored() {
        let text = """
        https://claude.ai/chat/example
        https://claude.ai/code/example
        https://claude.ai/chat/example?next=/artifact/example
        https://claude.ai/artifact/
        https://claude.ai/artifact
        https://claude.ai/artifactish/example
        https://claude.ai.example.test/artifact/example
        https://other.test/artifact/example
        """
        XCTAssertTrue(ClaudeArtifactReferenceScanner.scan(Data(text.utf8)).isEmpty)
        XCTAssertTrue(ClaudeArtifactReferenceScanner.scan(Data()).isEmpty)
    }

    func testScansTextEvenWhenJSONIsMalformed() {
        let text = "{broken https://claude.ai/artifact/example\n"
        XCTAssertEqual(ClaudeArtifactReferenceScanner.scan(Data(text.utf8)), [
            ClaudeArtifactReference(url: "https://claude.ai/artifact/example", sourceFilePath: nil),
        ])
    }

    func testAssociatesFilePathInToolInputAndSameObject() {
        let text = #"""
        {"message":{"content":[{"type":"tool_use","input":{"file_path":"/tmp/source.html","url":"https://claude.ai/artifact/first"}}]}}
        {"file_path":"\/tmp\/second.html","published_url":"https:\/\/claude.ai\/code\/artifact\/second"}
        {"type":"tool_use","input":{"file_path":"/tmp/third.html"},"result":"https://claude.ai/artifact/third"}
        """#
        XCTAssertEqual(ClaudeArtifactReferenceScanner.scan(Data(text.utf8)).map(\.sourceFilePath), [
            "/tmp/source.html", "/tmp/second.html", "/tmp/third.html",
        ])
    }

    func testLaterAssociationEnrichesFirstReferenceAndConflictingPathsStayUnknown() {
        let text = #"""
        {"text":"https://claude.ai/artifact/first https://claude.ai/artifact/second"}
        {"file_path":"/tmp/source.html","url":"https://claude.ai/artifact/first"}
        {"file_path":"/tmp/one.html","url":"https://claude.ai/artifact/second"}
        {"file_path":"/tmp/two.html","url":"https://claude.ai/artifact/second"}
        """#
        XCTAssertEqual(ClaudeArtifactReferenceScanner.scan(Data(text.utf8)), [
            ClaudeArtifactReference(url: "https://claude.ai/artifact/first", sourceFilePath: "/tmp/source.html"),
            ClaudeArtifactReference(url: "https://claude.ai/artifact/second", sourceFilePath: nil),
        ])
    }

    func testDoesNotGuessAcrossRecordsOrSeparateToolCallsOrMultipleArtifacts() {
        let text = #"""
        {"file_path":"/tmp/unrelated.html"}
        {"text":"https://claude.ai/artifact/first"}
        {"content":[{"type":"tool_use","input":{"file_path":"/tmp/unrelated.html"}},{"type":"tool_use","input":{"url":"https://claude.ai/artifact/second"}}]}
        {"file_path":"/tmp/ambiguous.html","text":"https://claude.ai/artifact/third https://claude.ai/artifact/fourth"}
        {"file_path":"/tmp/one.html","input":{"file_path":"/tmp/two.html"},"url":"https://claude.ai/artifact/fifth"}
        """#
        let references = ClaudeArtifactReferenceScanner.scan(Data(text.utf8))
        XCTAssertEqual(references.count, 5)
        XCTAssertTrue(references.allSatisfy { $0.sourceFilePath == nil })
    }

    func testUncertainAndUnsafePathsAreNotAssociated() throws {
        for path in ["relative.html", "~/source.html", "/tmp/../source.html", "//server/file", "/tmp/source\n.html", "/tmp/"] {
            let transcript = try JSONSerialization.data(withJSONObject: [
                "file_path": path, "url": "https://claude.ai/artifact/example",
            ])
            XCTAssertNil(try XCTUnwrap(ClaudeArtifactReferenceScanner.scan(transcript).first).sourceFilePath)
        }
    }

    func testRepublishPromptIncludesOnlyExistingFilesOnceInOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeArtifacts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first file.html")
        let second = root.appendingPathComponent("second.html")
        try Data().write(to: first)
        try Data().write(to: second)
        let paths: [String?] = [first.path, root.appendingPathComponent("missing.html").path,
            nil, first.path, root.path, second.path]
        let references = paths.enumerated().map {
            ClaudeArtifactReference(url: "https://claude.ai/artifact/\($0.offset)", sourceFilePath: $0.element)
        }
        let review = ClaudeArtifactReview(references: references)
        XCTAssertEqual(review.items.map(\.sourceFileExists), [true, false, false, true, false, true])
        let heading = String(localized: "Please republish these files as new artifacts:", bundle: PackagedRuntimeResources.bundle)
        XCTAssertEqual(review.republishPrompt, heading + "\n" + first.path + "\n" + second.path)
        try FileManager.default.removeItem(at: first)
        try FileManager.default.removeItem(at: second)
        XCTAssertNil(ClaudeArtifactReview(references: references).republishPrompt)
        XCTAssertNil(ClaudeArtifactReview(references: []).republishPrompt)
    }
}
