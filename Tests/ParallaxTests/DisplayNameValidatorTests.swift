import XCTest
@testable import Parallax

final class DisplayNameValidatorTests: XCTestCase {
    func testCanonicalizesUnicodeAndTrimsOnlyEdges() {
        let decomposed = "  Cafe\u{301}  Work\u{00A0}"

        XCTAssertEqual(
            DisplayNameValidator.normalized(decomposed),
            "Café  Work"
        )
    }

    func testRejectsEmptyControlsSeparatorsAndDirectionalFormatting() {
        let rejected = [
            "",
            "\u{00A0}\u{2003}\u{2028}",
            "Client\u{0000}Name",
            "Client\nName",
            "Client\u{2028}Name",
            "Client\u{202E}Name",
            "Client\u{200B}Name",
            "\u{200D}",
            "\u{200D}Client",
            "Client\u{200C}",
            "\u{301}",
        ]

        for name in rejected {
            XCTAssertNil(
                DisplayNameValidator.normalized(name),
                "Expected rejection for \(name.debugDescription)"
            )
        }
    }

    func testAllowsMeaningfulUnicodeJoinersAndDisplaySeparators() {
        XCTAssertEqual(
            DisplayNameValidator.normalized("Family 👩‍👩‍👧‍👦"),
            "Family 👩‍👩‍👧‍👦"
        )
        XCTAssertEqual(
            DisplayNameValidator.normalized("می‌خواهم"),
            "می‌خواهم"
        )
        XCTAssertEqual(
            DisplayNameValidator.normalized("Client / QA \\ Review"),
            "Client / QA \\ Review"
        )
        XCTAssertEqual(
            DisplayNameValidator.normalized("Archives"),
            "Archives",
            "Storage namespace words are valid labels because storage uses UUIDs."
        )
    }

    func testReservesNavigationTokensIncludingWidthConfusables() {
        XCTAssertEqual(
            DisplayNameValidator.validate(".").issue,
            .reserved
        )
        XCTAssertEqual(
            DisplayNameValidator.validate("  ..  ").issue,
            .reserved
        )
        XCTAssertEqual(
            DisplayNameValidator.validate("．．").issue,
            .reserved
        )
        XCTAssertEqual(DisplayNameValidator.normalized("..."), "...")
    }

    func testEnforcesNormalizedUTF8ByteLimit() {
        XCTAssertNotNil(
            DisplayNameValidator.normalized(
                String(repeating: "é", count: 128)
            )
        )
        XCTAssertEqual(
            DisplayNameValidator.validate(
                String(repeating: "é", count: 129)
            ).issue,
            .tooLong(maximumUTF8Bytes: 256)
        )
    }

    func testCollisionKeyIsComparisonOnlyAndDoesNotBanCrossScriptNames() {
        XCTAssertEqual(
            DisplayNameValidator.collisionKey("  Ｃafé  "),
            DisplayNameValidator.collisionKey("cafe\u{301}")
        )
        XCTAssertEqual(
            DisplayNameValidator.normalized("Сlient"),
            "Сlient",
            "Cross-script labels remain valid because names convey no authority."
        )
    }
}
