import XCTest
@testable import Parallax

final class ShellWordsParserTests: XCTestCase {
    func testParseResultReturnsExactWordsForValidQuotedAndEscapedInput() {
        let result = ShellWordsParser.parseResult(
            #"--flag "two words" 'C:\Fixture Data' plain\ value "a\"b""#
        )

        XCTAssertEqual(
            result.words,
            ["--flag", "two words", #"C:\Fixture Data"#, "plain value", #"a"b"#]
        )
        XCTAssertTrue(result.isSyntacticallyValid)
    }

    func testParseResultRetainsPartialWordsForUnmatchedSingleQuote() {
        let result = ShellWordsParser.parseResult("--flag 'editable partial")

        XCTAssertEqual(result.words, ["--flag", "editable partial"])
        XCTAssertFalse(result.isSyntacticallyValid)
    }

    func testParseResultRetainsPartialWordsForUnmatchedDoubleQuote() {
        let result = ShellWordsParser.parseResult("--flag \"editable partial")

        XCTAssertEqual(result.words, ["--flag", "editable partial"])
        XCTAssertFalse(result.isSyntacticallyValid)
    }

    func testParseResultRetainsPartialWordsForTrailingEscape() {
        let result = ShellWordsParser.parseResult(#"--flag editable\"#)

        XCTAssertEqual(result.words, ["--flag", #"editable\"#])
        XCTAssertFalse(result.isSyntacticallyValid)
    }
}
