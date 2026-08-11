import Foundation
import XCTest
@testable import Parallax

final class LibraryImportArtifactDecoderTests: XCTestCase {
    func testByteLimitRejectsBeforeArtifactClassificationOrTypedDecode()
        throws
    {
        let limits = LibraryImportLimits(maximumBytes: 32)
        let decoder = LibraryImportArtifactDecoder(limits: limits)
        let oversizedPortablePrefix = Data(
            """
            {"header":{"kind":"libraryMetadata"},"padding":"\(String(repeating: "x", count: 64))"}
            """.utf8
        )

        let result = try decoder.decode(oversizedPortablePrefix)

        XCTAssertNil(result.kind)
        XCTAssertEqual(result.validation.issues.map(\.code), [.inputTooLarge])
        XCTAssertNil(result.validation.document)
    }

    func testPortableHeaderContractErrorsAreNotReinterpretedAsPlainLibraryIssues()
        throws
    {
        let service = PortableConfigurationService()
        let valid = try service.makeLibraryMetadataExport(
            library: validLibrary(),
            sensitiveLiteralPolicy: .redact
        )
        let invalidDisclosure = PortableLibraryMetadataExport(
            header: PortableArtifactHeader(
                schemaVersion: valid.header.schemaVersion,
                kind: valid.header.kind,
                disclosure: PortableContentDisclosure(
                    included: [.libraryMetadata],
                    excluded: [.libraryMetadata]
                ),
                warnings: valid.header.warnings,
                sensitiveLiteralHandling:
                    valid.header.sensitiveLiteralHandling
            ),
            library: valid.library
        )

        XCTAssertThrowsError(
            try LibraryImportArtifactDecoder().decode(
                service.encode(invalidDisclosure)
            )
        ) { error in
            XCTAssertEqual(
                error as? PortableConfigurationError,
                .invalidDisclosure
            )
        }

        let futureHeader = PortableLibraryMetadataExport(
            header: PortableArtifactHeader(
                schemaVersion: PortableArtifactHeader.currentVersion + 1,
                kind: valid.header.kind,
                disclosure: valid.header.disclosure,
                warnings: valid.header.warnings,
                sensitiveLiteralHandling:
                    valid.header.sensitiveLiteralHandling
            ),
            library: valid.library
        )
        XCTAssertThrowsError(
            try LibraryImportArtifactDecoder().decode(
                service.encode(futureHeader)
            )
        ) { error in
            XCTAssertEqual(
                error as? PortableConfigurationError,
                .unsupportedSchemaVersion(
                    PortableArtifactHeader.currentVersion + 1
                )
            )
        }
    }

    func testNestedPortableLibraryUsesExistingStructuralValidation()
        throws
    {
        let service = PortableConfigurationService()
        let invalidLibrary = LibraryDocument(
            applications: [
                ManagedApplication(
                    displayName: "Unsafe",
                    appPath: "relative/Unsafe.app",
                    profiles: [LaunchProfile(name: "Profile")]
                )
            ]
        )
        let artifact = try service.makeLibraryMetadataExport(
            library: invalidLibrary,
            sensitiveLiteralPolicy: .redact
        )

        let decoded = try LibraryImportArtifactDecoder().decode(
            service.encode(artifact)
        )

        XCTAssertEqual(decoded.kind, .portableLibraryMetadata)
        XCTAssertFalse(decoded.validation.isValid)
        XCTAssertTrue(
            decoded.validation.issues.contains {
                $0.code == .invalidApplicationPath
                    && $0.path == "$.applications[0].appPath"
            }
        )
        XCTAssertNil(decoded.validation.document)
    }

    func testAcceptedImportFormatsClassifyWithoutChangingDocuments()
        throws
    {
        let service = PortableConfigurationService()
        let library = validLibrary()
        let plainData = try JSONEncoder().encode(library)
        let metadataData = try service.encode(
            service.makeLibraryMetadataExport(
                library: library,
                sensitiveLiteralPolicy: .redact
            )
        )
        let portableData = try service.encode(
            service.makePortableConfigurationExport(
                library: library,
                settings: PortableSettingsSnapshot(
                    profileTemplates: [],
                    defaultBaseStoragePath: "/Managed",
                    confirmBeforeLaunch: true,
                    appearance: .system
                ),
                sensitiveLiteralPolicy: .redact
            )
        )
        let decoder = LibraryImportArtifactDecoder()

        let plain = try decoder.decode(plainData)
        let metadata = try decoder.decode(metadataData)
        let portable = try decoder.decode(portableData)

        XCTAssertEqual(plain.kind, .libraryDocument)
        XCTAssertEqual(metadata.kind, .portableLibraryMetadata)
        XCTAssertEqual(portable.kind, .portableConfiguration)
        XCTAssertEqual(plain.validation.document, library)
        XCTAssertEqual(metadata.validation.document, library)
        XCTAssertEqual(portable.validation.document, library)
    }

    func testPortableServiceRejectsOversizedMalformedDataBeforeDecoding() {
        let service = PortableConfigurationService(
            maximumEncodedArtifactBytes: 8
        )

        XCTAssertThrowsError(
            try service.decodeLibraryMetadataExport(
                from: Data("not-json-over-limit".utf8)
            )
        ) { error in
            XCTAssertEqual(
                error as? PortableConfigurationError,
                .inputTooLarge
            )
        }
    }

    private func validLibrary() -> LibraryDocument {
        LibraryDocument(
            applications: [
                ManagedApplication(
                    displayName: "Fixture",
                    appPath: "/Applications/Fixture.app",
                    profiles: [LaunchProfile(name: "Profile")]
                )
            ]
        )
    }
}
