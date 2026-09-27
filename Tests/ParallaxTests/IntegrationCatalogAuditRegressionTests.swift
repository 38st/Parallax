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
                let informal = #"\b(elige|revisa|revísalo|revísalos|desmóntalo|actualiza|cierra|reduce|restablece|corrige|comprueba|vuelve|abre|guarda|selecciona|haz|pulsa|inténtalo|intenta|reinicia|asegúrate|mantén|quita|borra|consulta|prueba|cancela|añade|introduce|escribe|busca|inicia|verifica|úsalo|tú|tu|tus|ti|contigo|te|vos|vosotros|vosotras|vuestro|vuestra|vuestros|vuestras|os)\b|(?:^|[.!?;:]\s+|,\s+)(?:espera|acepta|cambia|elimina|confirma)\b"#
                for example in ["Vuelve a intentarlo.", "vuelve a intentarlo.", "Reinicia la app.", "Tu espacio", "Elige tus archivos."] {
                    XCTAssertNotNil(example.range(of: informal, options: [.regularExpression, .caseInsensitive]), example)
                }
                for (key, value) in catalog {
                    XCTAssertNil(value.range(of: informal, options: [.regularExpression, .caseInsensitive]), key)
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
