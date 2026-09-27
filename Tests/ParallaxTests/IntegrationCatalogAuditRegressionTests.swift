import Foundation
import XCTest
@testable import Parallax

final class IntegrationCatalogAuditRegressionTests: XCTestCase {
    func testMergedCatalogsHaveUniqueKeysNoBlankLinesAndNoRetiredKeys() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for language in ["en", "es"] {
            let url = root.appendingPathComponent("Sources/Parallax/Resources/\(language).lproj/Localizable.strings")
            let text = try String(contentsOf: url)
            let catalog = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(text.utf8), format: nil) as? [String: String])
            if language == "es" {
                let informal = #"\b(Elige|elige|Revisa|revisa|Revísalo|Revísalos|Desmóntalo|Actualiza|Cierra|reduce|restablece|corrige|Comprueba|vuelve|te pertenezca)\b"#
                for (key, value) in catalog {
                    XCTAssertNil(value.range(of: informal, options: .regularExpression), key)
                }
            }
            let lines = text.dropLast().components(separatedBy: "\n")
            XCTAssertFalse(lines.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            XCTAssertEqual(lines.filter { $0.hasPrefix("\"") }.count, catalog.count)
            for retired in ["%@ Account %lld", "%lld %@", "%lld%% used", "Session", "Weekly"] {
                XCTAssertNil(catalog[retired], retired)
            }
        }
    }
}
