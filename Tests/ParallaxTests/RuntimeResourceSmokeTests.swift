import Foundation
import XCTest
@testable import Parallax

final class RuntimeResourceSmokeTests: XCTestCase {
    func testRuntimeResourceResolverLoadsEveryDeclaredRuntimeResource() {
        XCTAssertNoThrow(try PackagedRuntimeResources.verify())
    }

    private func copiedResources() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-English-\(UUID()).bundle")
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("en.lproj"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.english.\(UUID())", "CFBundleDevelopmentRegion": "en"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Info.plist"))
        for (name, ext, folder) in [("AppIcon", "icns", ""), ("Localizable", "strings", "en.lproj/"),
                                     ("Localizable", "stringsdict", "en.lproj/")] {
            let source = try XCTUnwrap(PackagedRuntimeResources.bundle.url(forResource: name, withExtension: ext))
            try Data(contentsOf: source).write(to: root.appendingPathComponent(folder + name + "." + ext))
        }
        return root
    }

    func testEveryRequiredRuntimeResourceRejectsMissingAndEmptyFiles() throws {
        for name in ["AppIcon.icns", "en.lproj/Localizable.strings", "en.lproj/Localizable.stringsdict"] {
            for empty in [false, true] {
                let root = try copiedResources()
                let url = root.appendingPathComponent(name)
                if empty { try Data().write(to: url) }
                else { try FileManager.default.removeItem(at: url) }
                let bundle = try XCTUnwrap(Bundle(url: root))
                XCTAssertThrowsError(try PackagedRuntimeResources.verify(bundle: bundle), "\(name), empty=\(empty)") {
                    XCTAssertEqual($0 as? PackagedRuntimeResourceError, empty ? .unreadable(name) : .missing(name))
                }
            }
        }
    }

    func testRuntimeRejectsAdditionalLanguageResources() throws {
        let root = try copiedResources()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("fr.lproj"), withIntermediateDirectories: false)
        let bundle = try XCTUnwrap(Bundle(url: root))
        XCTAssertThrowsError(try PackagedRuntimeResources.verify(bundle: bundle)) {
            XCTAssertEqual($0 as? PackagedRuntimeResourceError, .unsupportedLanguage("fr"))
        }
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

    func testOnlyEnglishResourcesAreShipped() throws {
        let englishKeys = try localizationKeys(language: "en")

        XCTAssertFalse(englishKeys.isEmpty)
        let catalogs = try FileManager.default.contentsOfDirectory(at: sourceResourcesURL,
            includingPropertiesForKeys: nil).filter { $0.pathExtension == "lproj" }.map(\.lastPathComponent)
        XCTAssertEqual(catalogs, ["en.lproj"])
        XCTAssertEqual(Set(PackagedRuntimeResources.bundle.localizations), ["en"])
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
