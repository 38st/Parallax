import Foundation
import XCTest

final class PackagedResourcesAuditRegressionTests: XCTestCase {
    func testModuleBundleAccessIsConfinedToPackagedRuntimeResources() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Parallax")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: source, includingPropertiesForKeys: nil))
        let allowed = source.appendingPathComponent("Support/PackagedRuntimeResources.swift")
        for case let url as URL in enumerator where url.pathExtension == "swift" && url != allowed {
            let contents = try String(contentsOf: url, encoding: .utf8)
            // Also catch inferred access (`return .module` or `bundle: Bundle = .module`).
            XCTAssertNil(contents.range(of: #"\.\s*module\b"#, options: .regularExpression), url.path)
        }
    }
}
