import Foundation
import XCTest
@testable import Parallax

final class GateLocalizationAuditRegressionTests: XCTestCase {
    func testRunningInstancesUseSingularAndPluralInBothLanguages() throws {
        for (language, singular, plural) in [
            ("en", "1 running instance", "2 running instances"),
            ("es", "1 instancia en ejecución", "2 instancias en ejecución"),
        ] {
            let bundle = try localizationBundle(language)
            let locale = Locale(identifier: language)
            XCTAssertEqual(
                String(localized: "\(1) running instances", bundle: bundle, locale: locale),
                singular
            )
            XCTAssertEqual(
                String(localized: "\(2) running instances", bundle: bundle, locale: locale),
                plural
            )
            XCTAssertEqual(
                String(localized: "Parallax, \(1) running instances", bundle: bundle, locale: locale),
                "Parallax, \(singular)"
            )
        }
    }

    func testChecksAndRelocationCountsUseSpanishPluralForms() throws {
        let bundle = try localizationBundle("es")
        let locale = Locale(identifier: "es")
        XCTAssertEqual(
            String(localized: "\(1) of \(1) checks passing", bundle: bundle, locale: locale),
            "1 de 1 comprobación correcta"
        )
        XCTAssertEqual(
            String(localized: "\(1) of \(2) checks passing", bundle: bundle, locale: locale),
            "1 de 2 comprobaciones correctas"
        )
        XCTAssertEqual(
            String(localized: "\(2) will be preserved", bundle: bundle, locale: locale),
            "Se conservarán 2"
        )
        XCTAssertEqual(
            String(localized: "\(2) will be updated", bundle: bundle, locale: locale),
            "Se actualizarán 2"
        )
    }

    func testProcessIdentifierUsesInt32CatalogKey() throws {
        let bundle = try localizationBundle("es")
        let processIdentifier: Int32 = 42
        XCTAssertEqual(
            String(
                localized: "Process \(processIdentifier) has no verifiable start identity.",
                bundle: bundle,
                locale: Locale(identifier: "es")
            ),
            "El proceso 42 no tiene una identidad de inicio verificable."
        )
    }

    private func localizationBundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(
            PackagedRuntimeResources.bundle.path(forResource: language, ofType: "lproj")
        )
        return try XCTUnwrap(Bundle(path: path))
    }
}
