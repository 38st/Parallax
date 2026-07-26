import Foundation
import XCTest
@testable import Parallax

final class RuntimeResourceSmokeTests: XCTestCase {
    func testRuntimeResourceResolverLoadsEveryDeclaredRuntimeResource() {
        XCTAssertNoThrow(try PackagedRuntimeResources.verify())
    }

    func testTestBundleModuleLoadsDeclaredFixtureAtRuntime() throws {
        let fixtureURL = try XCTUnwrap(
            Bundle.module.url(
                forResource: "valid-v1-library",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let data = try Data(contentsOf: fixtureURL)

        XCTAssertFalse(data.isEmpty)
        XCTAssertNotNil(
            try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )
    }

    func testExecutableTargetDeclaresResourcesDirectory() throws {
        let manifest = try String(
            contentsOf: packageRootURL.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let executableStart = try XCTUnwrap(
            manifest.range(of: ".executableTarget(")
        )
        let testStart = try XCTUnwrap(
            manifest.range(
                of: ".testTarget(",
                range: executableStart.upperBound..<manifest.endIndex
            )
        )
        let executableDeclaration =
            manifest[executableStart.lowerBound..<testStart.lowerBound]
                .filter { !$0.isWhitespace }

        XCTAssertTrue(
            executableDeclaration.contains(#".process("Resources")"#)
        )
    }

    func testSourceAppIconIsACompleteICNSContainer() throws {
        let data = try Data(
            contentsOf: sourceResourcesURL.appendingPathComponent(
                "AppIcon.icns"
            )
        )
        let bytes = [UInt8](data)

        XCTAssertGreaterThanOrEqual(bytes.count, 8)
        XCTAssertEqual(String(bytes: bytes.prefix(4), encoding: .ascii), "icns")

        let declaredLength = bytes[4..<8].reduce(0) {
            ($0 << 8) | Int($1)
        }
        XCTAssertEqual(declaredLength, bytes.count)
    }

    func testLocalizationDictionariesDeclareMatchingPluralKeys() throws {
        let englishKeys = try localizationKeys(language: "en")
        let spanishKeys = try localizationKeys(language: "es")

        XCTAssertFalse(englishKeys.isEmpty)
        XCTAssertEqual(spanishKeys, englishKeys)
    }

    private var packageRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var sourceResourcesURL: URL {
        packageRootURL
            .appendingPathComponent("Sources")
            .appendingPathComponent("Parallax")
            .appendingPathComponent("Resources")
    }

    private func localizationKeys(
        language: String
    ) throws -> Set<String> {
        let url = sourceResourcesURL
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.stringsdict")
        let data = try Data(contentsOf: url)
        let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            format: nil
        )
        let dictionary = try XCTUnwrap(
            propertyList as? [String: Any]
        )
        return Set(dictionary.keys)
    }
}
