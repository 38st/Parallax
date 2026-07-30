import Foundation
import XCTest
@testable import Parallax

final class LocalizationTests: XCTestCase {
    func testEnglishPluralCountsCoverZeroOneAndMany() {
        let locale = Locale(identifier: "en")

        XCTAssertEqual(LocalizedCount.profiles(0, locale: locale), "0 profiles")
        XCTAssertEqual(LocalizedCount.profiles(1, locale: locale), "1 profile")
        XCTAssertEqual(LocalizedCount.profiles(2, locale: locale), "2 profiles")
        XCTAssertEqual(LocalizedCount.spaces(0, locale: locale), "0 spaces")
        XCTAssertEqual(LocalizedCount.spaces(1, locale: locale), "1 space")
        XCTAssertEqual(LocalizedCount.spaces(2, locale: locale), "2 spaces")
        XCTAssertEqual(
            LocalizedCount.profileConfigurations(0, locale: locale),
            "0 profile configurations"
        )
        XCTAssertEqual(
            LocalizedCount.profileConfigurations(1, locale: locale),
            "1 profile configuration"
        )
        XCTAssertEqual(
            LocalizedCount.profileConfigurations(2, locale: locale),
            "2 profile configurations"
        )
        XCTAssertEqual(
            LocalizedCount.launchArguments(1, locale: locale),
            "1 launch argument"
        )
        XCTAssertEqual(
            LocalizedCount.environmentOperations(2, locale: locale),
            "2 environment operations"
        )
        XCTAssertEqual(
            LocalizedCount.applications(1, locale: locale),
            "1 application"
        )
    }

    func testSpanishLocaleUsesLocalizedPluralForms() {
        let locale = Locale(identifier: "es")

        XCTAssertEqual(LocalizedCount.profiles(0, locale: locale), "0 perfiles")
        XCTAssertEqual(LocalizedCount.profiles(1, locale: locale), "1 perfil")
        XCTAssertEqual(LocalizedCount.profiles(2, locale: locale), "2 perfiles")
        XCTAssertEqual(LocalizedCount.spaces(0, locale: locale), "0 espacios")
        XCTAssertEqual(LocalizedCount.spaces(1, locale: locale), "1 espacio")
        XCTAssertEqual(LocalizedCount.spaces(2, locale: locale), "2 espacios")
        XCTAssertEqual(
            LocalizedCount.profileConfigurations(1, locale: locale),
            "1 configuración de perfil"
        )
        XCTAssertEqual(
            LocalizedCount.profileConfigurations(2, locale: locale),
            "2 configuraciones de perfil"
        )
        XCTAssertEqual(
            LocalizedCount.applications(2, locale: locale),
            "2 aplicaciones"
        )
    }

    func testCriticalJourneyLabelsHaveSpanishTranslations() throws {
        let resourceURL = try XCTUnwrap(
            PackagedRuntimeResources.bundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: "es"
            )
        )
        let translations = try XCTUnwrap(
            NSDictionary(contentsOf: resourceURL)
                as? [String: String]
        )
        for key in [
            "Cancel",
            "Continue",
            "Create",
            "Create & Open",
            "Delete Space Template?",
            "Export Sanitized Support Bundle…",
            "New Space",
            "Open Again",
            "Recent Activity",
            "Save",
            "Spaces",
        ] {
            XCTAssertNotEqual(
                translations[key],
                key,
                "Missing Spanish translation for \(key)"
            )
        }
    }
}
