import XCTest
@testable import Parallax

final class LaunchOptionResolverTests: XCTestCase {
    func testUserDataDirectorySupportsEqualsAndSplitForms() {
        let equals = resolve("--user-data-dir='/Fixture Data/UserData'")
        let split = resolve("--user-data-dir '/Fixture Data/UserData'")

        XCTAssertEqual(equals.resolvedValue, "/Fixture Data/UserData")
        XCTAssertEqual(equals.occurrences.first?.form, .equals)
        XCTAssertEqual(split.resolvedValue, "/Fixture Data/UserData")
        XCTAssertEqual(split.occurrences.first?.form, .split)
        XCTAssertTrue(equals.diagnostics.isEmpty)
        XCTAssertTrue(split.diagnostics.isEmpty)
    }

    func testBlankAndMissingValuesAreRejected() {
        let blankEquals = resolve("--user-data-dir=")
        let blankSplit = resolve("--user-data-dir ''")
        let missingSplit = resolve("--flag --user-data-dir")
        let optionInsteadOfValue = resolve("--user-data-dir --another-option")

        XCTAssertEqual(blankEquals.diagnostics.map(\.code), [.blankUserDataDirectory])
        XCTAssertEqual(blankSplit.diagnostics.map(\.code), [.blankUserDataDirectory])
        XCTAssertEqual(missingSplit.diagnostics.map(\.code), [.missingUserDataDirectory])
        XCTAssertEqual(
            optionInsteadOfValue.diagnostics.map(\.code),
            [.missingUserDataDirectory]
        )
        XCTAssertNil(blankEquals.resolvedValue)
        XCTAssertNil(missingSplit.resolvedValue)
    }

    func testDuplicateAndMixedFormsAreRejectedWithoutChoosingAWinner() {
        let duplicate = resolve(
            "--user-data-dir=/one --user-data-dir=/two"
        )
        let mixed = resolve(
            "--user-data-dir=/one --user-data-dir /two"
        )

        XCTAssertEqual(duplicate.occurrences.map(\.value), ["/one", "/two"])
        XCTAssertEqual(duplicate.diagnostics.map(\.code), [.duplicateUserDataDirectory])
        XCTAssertEqual(mixed.diagnostics.map(\.code), [.duplicateUserDataDirectory])
        XCTAssertNotNil(duplicate.diagnostics.first?.relatedRange)
        XCTAssertNil(duplicate.resolvedValue)
        XCTAssertNil(mixed.resolvedValue)
    }

    func testOnlyExactSingletonOptionIsRecognized() {
        let result = resolve(
            "--user-data-directory=/not-matched --user-data-dir-extra=/also-not-matched"
        )

        XCTAssertTrue(result.occurrences.isEmpty)
        XCTAssertNil(result.resolvedValue)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testOptionResolutionIsPureAndRetainsRawTildeValue() {
        let result = resolve("--user-data-dir=~/Fixture")

        XCTAssertEqual(result.resolvedValue, "~/Fixture")
        XCTAssertEqual(result.occurrences.first?.value, "~/Fixture")
    }

    private func resolve(_ text: String) -> UserDataDirectoryResolution {
        UserDataDirectoryOptionResolver.resolve(
            in: LaunchArgumentParser.parse(text).tokens
        )
    }
}
