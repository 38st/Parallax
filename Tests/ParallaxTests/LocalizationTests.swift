import Foundation
import XCTest
@testable import Parallax

final class LocalizationTests: XCTestCase {
    func testEveryCountLabelCoversZeroOneAndMany() {
        let cases: [((Int, Locale) -> String, String, String, String)] = [
            (LocalizedCount.applications, "0 applications", "1 application", "2 applications"),
            (LocalizedCount.profiles, "0 profiles", "1 profile", "2 profiles"),
            (LocalizedCount.spaces, "0 spaces", "1 space", "2 spaces"),
            (LocalizedCount.profileConfigurations, "0 profile configurations", "1 profile configuration", "2 profile configurations"),
            (LocalizedCount.launchArguments, "0 launch arguments", "1 launch argument", "2 launch arguments"),
            (LocalizedCount.environmentOperations, "0 environment operations", "1 environment operation", "2 environment operations"),
            (LocalizedCount.accounts, "0 accounts", "1 account", "2 accounts"),
            (LocalizedCount.trackedAccounts, "0 accounts tracked", "1 account tracked", "2 accounts tracked"),
        ]
        for locale in ["en", "fr_FR", "ja_JP", "ar", "ru_RU"] {
            for (format, zero, one, many) in cases {
                XCTAssertEqual(format(0, Locale(identifier: locale)), zero)
                XCTAssertEqual(format(1, Locale(identifier: locale)), one)
                XCTAssertEqual(format(2, Locale(identifier: locale)), many)
            }
        }
    }

    func testUnsupportedSystemLanguagesKeepEnglishCounts() {
        for identifier in ["en", "fr_FR", "ja_JP", "ar", "ru_RU"] {
            let locale = Locale(identifier: identifier)
            XCTAssertEqual(LocalizedCount.spaces(1, locale: locale), "1 space")
            XCTAssertEqual(LocalizedCount.spaces(2, locale: locale), "2 spaces")
            XCTAssertEqual(LocalizedCount.accounts(1, locale: locale), "1 account")
            XCTAssertEqual(LocalizedCount.trackedAccounts(0, locale: locale), "0 accounts tracked")
            XCTAssertEqual(LocalizedCount.trackedAccounts(1, locale: locale), "1 account tracked")
        }
    }

    func testPercentFormatsPreserveEscapingAndValues() throws {
        let url = try XCTUnwrap(PackagedRuntimeResources.bundle.url(forResource: "Localizable",
            withExtension: "strings", subdirectory: nil, localization: "en"))
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        let key = "Last known usage: %lld%% from %@. Excluded from current status."
        XCTAssertEqual(String(format: try XCTUnwrap(table[key]), 42, "Codex"),
            "Last known usage: 42% from Codex. Excluded from current status.")
        XCTAssertNotNil(table["%lld%%"])
        XCTAssertNil(table["%lld%"])
    }

    func testCriticalJourneyLabelsAreAvailableInEnglish() throws {
        let url = try XCTUnwrap(PackagedRuntimeResources.bundle.url(forResource: "en", withExtension: "lproj"))
        let bundle = try XCTUnwrap(Bundle(url: url))
        for key in ["Cancel", "Continue", "Create", "Create & Open", "New Space", "Open Again",
                    "Save", "Sign-in required", "Current session", "Weekly · All models"] {
            XCTAssertEqual(bundle.localizedString(forKey: key, value: "MISSING", table: nil), key)
        }
    }
}
