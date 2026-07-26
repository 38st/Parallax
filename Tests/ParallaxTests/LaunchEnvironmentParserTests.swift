import XCTest
@testable import Parallax

final class LaunchEnvironmentParserTests: XCTestCase {
    func testParsesOrderedAssignmentsCommentsEmptyAndUnset() {
        let result = LaunchEnvironmentParser.parse(
            """
              # comment
            FIRST=one
            EMPTY=
            unset FIRST
            LAST=three
            """
        )

        XCTAssertEqual(result.entries.map(\.name), ["FIRST", "EMPTY", "FIRST", "LAST"])
        XCTAssertEqual(
            result.entries.map(\.operation),
            [.set("one"), .set(""), .unset, .set("three")]
        )
        XCTAssertEqual(result.effectiveOperations["FIRST"], .unset)
        XCTAssertEqual(result.effectiveOperations["EMPTY"], .set(""))
        XCTAssertEqual(result.effectiveValues, ["EMPTY": "", "LAST": "three"])
    }

    func testPreservesValueWhitespaceAndEmbeddedEqualsAndCommentCharacters() {
        let result = LaunchEnvironmentParser.parse(
            "VALUE=  leading and trailing  \nEMBEDDED=one=two#literal"
        )

        XCTAssertEqual(
            result.entries.map(\.operation),
            [.set("  leading and trailing  "), .set("one=two#literal")]
        )
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testCRLFLinesHaveStableLineAndUTF16Ranges() throws {
        let result = LaunchEnvironmentParser.parse("ONE=1\r\nTWO=🙂\r\n")
        let first = try XCTUnwrap(result.entries.first)
        let second = try XCTUnwrap(result.entries.dropFirst().first)

        XCTAssertEqual(result.entries.map(\.name), ["ONE", "TWO"])
        XCTAssertEqual(first.range.start.line, 1)
        XCTAssertEqual(second.range.start.line, 2)
        XCTAssertEqual(second.range.start.utf16Offset, 7)
        XCTAssertEqual(second.valueRange?.end.utf16Offset, 13)
    }

    func testInvalidNamesAndMalformedLinesProduceErrors() {
        let result = LaunchEnvironmentParser.parse(
            "1INVALID=value\nNO_EQUALS\nunset BAD-NAME"
        )

        XCTAssertEqual(
            result.diagnostics.map(\.code),
            [.invalidEnvironmentName, .malformedEnvironmentLine, .invalidEnvironmentName]
        )
        XCTAssertTrue(result.hasErrors)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testDuplicateAssignmentsWarnAndLastEntryWins() {
        let result = LaunchEnvironmentParser.parse(
            "DUPLICATE=first\nDUPLICATE=second"
        )

        XCTAssertEqual(result.entries.count, 2)
        XCTAssertEqual(result.diagnostics.map(\.code), [.duplicateEnvironmentName])
        XCTAssertEqual(result.diagnostics.map(\.severity), [.warning])
        XCTAssertNotNil(result.diagnostics.first?.relatedRange)
        XCTAssertEqual(result.effectiveValues["DUPLICATE"], "second")
    }

    func testControlCharactersAreRejectedWithoutLosingOtherValidLines() {
        let result = LaunchEnvironmentParser.parse(
            "GOOD=value\nBAD=before\u{0000}after"
        )

        XCTAssertEqual(result.entries.map(\.name), ["GOOD"])
        XCTAssertEqual(
            result.diagnostics.map(\.code),
            [.unsupportedControlCharacter]
        )
        XCTAssertEqual(result.effectiveValues, ["GOOD": "value"])
    }
}
