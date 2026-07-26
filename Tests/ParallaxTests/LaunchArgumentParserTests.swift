import XCTest
@testable import Parallax

final class LaunchArgumentParserTests: XCTestCase {
    func testCompatibilityGrammarPreservesEmptyAndQuotedArguments() {
        let result = LaunchArgumentParser.parse(
            "--flag \"\" 'two words' plain\\ value \"a\\\"b\""
        )

        XCTAssertEqual(
            result.tokens.map(\.value),
            ["--flag", "", "two words", "plain value", "a\"b"]
        )
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testSerializerRoundTripsSpacesQuotesBackslashesAndEmptyValues() {
        let words = [
            "",
            "--flag=two words",
            "don't",
            #"C:\Fixture Data\Profile"#,
            "quote\"inside",
            "🙂"
        ]

        let serialized = LaunchArgumentParser.serialize(words)
        let reparsed = LaunchArgumentParser.parse(serialized)

        XCTAssertEqual(reparsed.tokens.map(\.value), words)
        XCTAssertTrue(reparsed.diagnostics.isEmpty)
    }

    func testUnmatchedQuotesAndTrailingEscapeHaveSourceRanges() {
        let unmatched = LaunchArgumentParser.parse("--flag 'unterminated")
        let unmatchedDouble = LaunchArgumentParser.parse("--flag \"unterminated")
        let trailingEscape = LaunchArgumentParser.parse("--flag value\\")

        XCTAssertEqual(unmatched.diagnostics.map(\.code), [.unmatchedSingleQuote])
        XCTAssertEqual(
            unmatchedDouble.diagnostics.map(\.code),
            [.unmatchedDoubleQuote]
        )
        XCTAssertEqual(unmatched.diagnostics.first?.range.start.line, 1)
        XCTAssertEqual(unmatched.diagnostics.first?.range.start.column, 8)
        XCTAssertEqual(unmatched.diagnostics.first?.range.start.utf16Offset, 7)
        XCTAssertEqual(
            unmatched.diagnostics.first?.range.end.utf16Offset,
            "--flag 'unterminated".utf16.count
        )

        XCTAssertEqual(trailingEscape.diagnostics.map(\.code), [.trailingEscape])
        XCTAssertEqual(
            trailingEscape.diagnostics.first?.range.start.utf16Offset,
            "--flag value".utf16.count
        )
        XCTAssertEqual(
            trailingEscape.diagnostics.first?.range.end.utf16Offset,
            "--flag value\\".utf16.count
        )
    }

    func testTokenRangesUseUTF16Offsets() {
        let result = LaunchArgumentParser.parse("🙂 \"two words\"")

        XCTAssertEqual(result.tokens.count, 2)
        XCTAssertEqual(result.tokens[0].range.start.utf16Offset, 0)
        XCTAssertEqual(result.tokens[0].range.end.utf16Offset, 2)
        XCTAssertEqual(result.tokens[1].range.start.utf16Offset, 3)
        XCTAssertEqual(result.tokens[1].range.end.utf16Offset, 14)
        XCTAssertEqual(result.tokens[1].range.start.column, 4)
    }

    func testControlCharacterProducesBlockingDiagnostic() {
        let result = LaunchArgumentParser.parse("--flag=\u{0000}")

        XCTAssertEqual(result.diagnostics.map(\.code), [.unsupportedControlCharacter])
        XCTAssertTrue(result.hasErrors)
    }
}
