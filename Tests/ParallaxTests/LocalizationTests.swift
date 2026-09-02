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

    func testAccountCountsUseLocalizedPluralForms() {
        let english = Locale(identifier: "en")
        let spanish = Locale(identifier: "es")

        XCTAssertEqual(LocalizedCount.accounts(1, locale: english), "1 account")
        XCTAssertEqual(LocalizedCount.accounts(2, locale: english), "2 accounts")
        XCTAssertEqual(
            LocalizedCount.trackedAccounts(1, locale: english),
            "1 account tracked"
        )
        XCTAssertEqual(
            LocalizedCount.trackedAccounts(0, locale: english),
            "0 accounts tracked"
        )
        XCTAssertEqual(LocalizedCount.accounts(1, locale: spanish), "1 cuenta")
        XCTAssertEqual(LocalizedCount.accounts(3, locale: spanish), "3 cuentas")
        XCTAssertEqual(
            LocalizedCount.trackedAccounts(1, locale: spanish),
            "1 cuenta rastreada"
        )
    }

    func testFormatStringPluralKeysResolveThroughStringsdict() throws {
        let english = Locale(identifier: "en")
        let spanish = Locale(identifier: "es")
        let englishBundle = try lprojBundle("en")
        let spanishBundle = try lprojBundle("es")

        XCTAssertEqual(
            String(localized: "\(1) identities", bundle: englishBundle, locale: english),
            "1 identity"
        )
        XCTAssertEqual(
            String(localized: "\(4) identities", bundle: englishBundle, locale: english),
            "4 identities"
        )
        XCTAssertEqual(
            String(localized: "\(1) identities", bundle: spanishBundle, locale: spanish),
            "1 identidad"
        )
        XCTAssertEqual(
            String(
                localized: "\(2) connected · \(1) apps",
                bundle: englishBundle,
                locale: english
            ),
            "2 connected · 1 app"
        )
        XCTAssertEqual(
            String(
                localized: "\(1) connected · \(2) apps",
                bundle: spanishBundle,
                locale: spanish
            ),
            "1 conectada · 2 apps"
        )
        XCTAssertEqual(
            String(localized: "\(2) active", bundle: spanishBundle, locale: spanish),
            "2 activas"
        )
    }

    func testPercentKeysAreEscapedInBothTables() throws {
        let escapedKeys = [
            "%lld%%",
            "Last known usage: %lld%% from %@. Excluded from current status.",
        ]
        let unescapedKeys = [
            "%lld%",
            "Last known usage: %lld% from %@. Excluded from current status.",
        ]
        for localization in ["en", "es"] {
            let translations = try stringsTable(localization)
            for key in escapedKeys {
                XCTAssertNotNil(
                    translations[key],
                    "Missing \(localization) entry for \(key)"
                )
                XCTAssertTrue(
                    translations[key]?.contains("%%") == true,
                    "\(localization) value for \(key) must keep the escaped percent"
                )
            }
            for key in unescapedKeys {
                XCTAssertNil(
                    translations[key],
                    "\(localization) still carries the unescaped key \(key)"
                )
            }
        }
        XCTAssertEqual(
            String(format: try XCTUnwrap(stringsTable("es")[escapedKeys[1]]), 42, "Codex"),
            "Último uso conocido: 42% de Codex. Excluido del estado actual."
        )
    }

    func testCriticalJourneyLabelsHaveSpanishTranslations() throws {
        let translations = try stringsTable("es")
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
            "Stale",
            "Refreshing",
            "Refresh needed",
            "Sign-in required",
            "Current session",
            "Weekly · All models",
        ] {
            XCTAssertNotEqual(
                translations[key],
                key,
                "Missing Spanish translation for \(key)"
            )
        }
        XCTAssertEqual(translations["Stale"], "Desactualizado")
        XCTAssertEqual(translations["Refreshing"], "Actualizando")
        XCTAssertEqual(translations["Attempted %@"], "Último intento: %@")
        XCTAssertEqual(translations["Refresh needed"], "Actualización necesaria")
    }

    private func stringsTable(_ localization: String) throws -> [String: String] {
        let resourceURL = try XCTUnwrap(
            PackagedRuntimeResources.bundle.url(
                forResource: "Localizable",
                withExtension: "strings",
                subdirectory: nil,
                localization: localization
            )
        )
        return try XCTUnwrap(
            NSDictionary(contentsOf: resourceURL) as? [String: String]
        )
    }

    private func lprojBundle(_ localization: String) throws -> Bundle {
        let path = try XCTUnwrap(
            PackagedRuntimeResources.bundle.path(
                forResource: localization,
                ofType: "lproj"
            )
        )
        return try XCTUnwrap(Bundle(path: path))
    }
}
