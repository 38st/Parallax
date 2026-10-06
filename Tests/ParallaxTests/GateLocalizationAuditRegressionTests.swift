import Foundation
import XCTest
@testable import Parallax

final class GateLocalizationAuditRegressionTests: XCTestCase {
    func testRunningInstancesUseSingularAndPluralInEnglish() throws {
        for (language, singular, plural) in [
            ("en", "1 running instance", "2 running instances"),
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

    func testChecksAndRelocationCountsUseEnglishPluralForms() throws {
        let bundle = try localizationBundle("en")
        let locale = Locale(identifier: "en")
        XCTAssertEqual(
            String(localized: "\(1) of \(1) checks passing", bundle: bundle, locale: locale),
            "1 of 1 check passing"
        )
        XCTAssertEqual(
            String(localized: "\(1) of \(2) checks passing", bundle: bundle, locale: locale),
            "1 of 2 checks passing"
        )
        XCTAssertEqual(
            String(localized: "\(2) will be preserved", bundle: bundle, locale: locale),
            "2 will be preserved"
        )
        XCTAssertEqual(
            String(localized: "\(2) will be updated", bundle: bundle, locale: locale),
            "2 will be updated"
        )
    }

    func testProcessIdentifierUsesInt32CatalogKey() throws {
        let bundle = try localizationBundle("en")
        let processIdentifier: Int32 = 42
        XCTAssertEqual(
            String(
                localized: "Process \(processIdentifier) has no verifiable start identity.",
                bundle: bundle,
                locale: Locale(identifier: "en")
            ),
            "Process 42 has no verifiable start identity."
        )
    }

    private func localizationBundle(_ language: String) throws -> Bundle {
        let path = try XCTUnwrap(
            PackagedRuntimeResources.bundle.path(forResource: language, ofType: "lproj")
        )
        return try XCTUnwrap(Bundle(path: path))
    }
}
