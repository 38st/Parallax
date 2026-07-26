import Foundation
import XCTest
@testable import Parallax

final class PortableConfigurationTests: XCTestCase {
    private let service = PortableConfigurationService()

    func testLibraryMetadataRoundTripsWithTruthfulDisclosure() throws {
        let reference = EnvironmentSecretReference(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
        )
        let library = makeLibrary(
            environmentText: """
            NAME=Visible
            OPENAI_API_KEY=literal-secret
            KEYCHAIN_VALUE=\(reference.token)
            """
        )

        let artifact = try service.makeLibraryMetadataExport(
            library: library,
            sensitiveLiteralPolicy: .redact
        )
        let decoded = try service.decodeLibraryMetadataExport(
            from: service.encode(artifact)
        )

        XCTAssertEqual(decoded, artifact)
        XCTAssertEqual(decoded.header.kind, .libraryMetadata)
        XCTAssertTrue(
            decoded.header.disclosure.includes(.libraryMetadata)
        )
        XCTAssertTrue(
            decoded.header.disclosure.excludes(.settingsAndTemplates)
        )
        XCTAssertTrue(
            decoded.header.disclosure.excludes(.managedProfileDataPayloads)
        )
        XCTAssertTrue(
            decoded.header.disclosure.excludes(.keychainSecretValues)
        )
        XCTAssertTrue(
            decoded.header.warnings.contains(
                .applicationPathsMayRequireRelocation
            )
        )
        let environment = try XCTUnwrap(
            decoded.library.applications.first?.profiles.first?.environmentText
        )
        XCTAssertTrue(environment.contains("OPENAI_API_KEY=<redacted>"))
        XCTAssertFalse(environment.contains("literal-secret"))
        XCTAssertTrue(environment.contains(reference.token))
    }

    func testSensitiveLiteralPoliciesOmitRedactAndExplicitlyInclude() throws {
        let library = makeLibrary(
            environmentText: """
            PUBLIC_VALUE=visible
            CUSTOM_CREDENTIAL=private
            """
        )

        let omitted = try service.makeLibraryMetadataExport(
            library: library,
            sensitiveLiteralPolicy: .omit
        )
        let redacted = try service.makeLibraryMetadataExport(
            library: library,
            sensitiveLiteralPolicy: .redact
        )
        let included = try service.makeLibraryMetadataExport(
            library: library,
            sensitiveLiteralPolicy: .includeAfterExplicitConfirmation
        )

        let omittedText = try profileEnvironment(in: omitted.library)
        XCTAssertTrue(
            omittedText.contains(
                "# Omitted sensitive value: CUSTOM_CREDENTIAL"
            )
        )
        XCTAssertFalse(omittedText.contains("private"))
        XCTAssertEqual(
            omitted.header.sensitiveLiteralHandling,
            .omitted
        )

        let redactedText = try profileEnvironment(in: redacted.library)
        XCTAssertTrue(
            redactedText.contains("CUSTOM_CREDENTIAL=<redacted>")
        )
        XCTAssertFalse(redactedText.contains("private"))
        XCTAssertEqual(
            redacted.header.sensitiveLiteralHandling,
            .redacted
        )

        XCTAssertTrue(
            try profileEnvironment(in: included.library)
                .contains("CUSTOM_CREDENTIAL=private")
        )
        XCTAssertEqual(
            included.header.sensitiveLiteralHandling,
            .includedAfterExplicitConfirmation
        )
        XCTAssertTrue(
            included.header.warnings.contains(
                .sensitiveLiteralsIncludedAfterExplicitConfirmation
            )
        )
    }

    func testSettingsAndTemplatesExportRoundTripsIndependently() throws {
        let settings = PortableSettingsSnapshot(
            profileTemplates: [
                ProfileTemplate(
                    id: UUID(
                        uuidString:
                            "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
                    )!,
                    name: "Work",
                    argumentsText: "--new-window",
                    environmentText: """
                    REGION=us-east
                    NPM_TOKEN=template-secret
                    """,
                    notes: "Portable template"
                )
            ],
            defaultBaseStoragePath: "/Users/example/Profiles",
            confirmBeforeLaunch: true,
            appearance: .dark
        )

        let artifact = try service.makeSettingsAndTemplatesExport(
            settings: settings,
            sensitiveLiteralPolicy: .omit
        )
        let decoded = try service.decodeSettingsAndTemplatesExport(
            from: service.encode(artifact)
        )

        XCTAssertEqual(decoded, artifact)
        XCTAssertEqual(decoded.header.kind, .settingsAndTemplates)
        XCTAssertTrue(
            decoded.header.disclosure.includes(.settingsAndTemplates)
        )
        XCTAssertTrue(
            decoded.header.disclosure.excludes(.libraryMetadata)
        )
        XCTAssertFalse(
            decoded.settings.profileTemplates[0].environmentText
                .contains("template-secret")
        )
        XCTAssertEqual(
            decoded.settings.profileTemplates[0].profileTemplate,
            ProfileTemplate(
                id: settings.profileTemplates[0].id,
                name: "Work",
                argumentsText: "--new-window",
                environmentText:
                    decoded.settings.profileTemplates[0].environmentText,
                notes: "Portable template"
            )
        )
    }

    func testPortableConfigurationIncludesMetadataAndSettingsButNoProfileData()
        throws
    {
        let settings = makeSettings()
        let artifact = try service.makePortableConfigurationExport(
            library: makeLibrary(environmentText: "NAME=value"),
            settings: settings,
            sensitiveLiteralPolicy: .redact
        )
        let decoded = try service.decodePortableConfigurationExport(
            from: service.encode(artifact)
        )

        XCTAssertEqual(decoded, artifact)
        XCTAssertEqual(decoded.header.kind, .portableConfiguration)
        XCTAssertTrue(
            decoded.header.disclosure.includes(.libraryMetadata)
        )
        XCTAssertTrue(
            decoded.header.disclosure.includes(.settingsAndTemplates)
        )
        XCTAssertTrue(
            decoded.header.disclosure.excludes(.managedProfileDataPayloads)
        )
        XCTAssertTrue(
            decoded.header.disclosure.excludes(.externalProfileData)
        )
    }

    func testFullBackupManifestDistinguishesIncludedManagedDataFromExternalData()
        throws
    {
        let applicationStorageID = UUID()
        let profileStorageID = UUID()
        let missingManagedPath =
            "/not-read/managed/\(profileStorageID.uuidString)"
        let missingExternalPath =
            "/not-read/external/\(profileStorageID.uuidString)"
        let inventory = [
            PortableProfileDataInventoryEntry.managed(
                applicationStorageID: applicationStorageID,
                profileStorageID: profileStorageID,
                kind: .profileRoot,
                declaredPath: missingManagedPath,
                archiveRelativePath: "ProfileData/app/profile"
            ),
            PortableProfileDataInventoryEntry.external(
                applicationStorageID: applicationStorageID,
                profileStorageID: profileStorageID,
                kind: .codexHome,
                declaredPath: missingExternalPath
            ),
        ]

        let fullBackup = try service.makeFullBackupManifest(
            library: makeLibrary(environmentText: "NAME=value"),
            settings: makeSettings(),
            profileDataInventory: inventory,
            sensitiveLiteralPolicy: .redact
        )
        let decoded = try service.decodeFullBackupManifest(
            from: service.encode(fullBackup)
        )
        let metadata = try service.makeLibraryMetadataExport(
            library: fullBackup.library,
            sensitiveLiteralPolicy: .redact
        )

        XCTAssertEqual(decoded, fullBackup)
        XCTAssertEqual(decoded.header.kind, .fullBackup)
        XCTAssertTrue(
            decoded.header.disclosure.includes(.profileDataInventory)
        )
        XCTAssertTrue(
            decoded.header.disclosure.excludes(.managedProfileDataPayloads)
        )
        XCTAssertTrue(
            decoded.header.disclosure.excludes(.externalProfileData)
        )
        XCTAssertTrue(
            decoded.header.warnings.contains(
                .profileDataInventoryNotFilesystemVerified
            )
        )
        XCTAssertTrue(
            decoded.header.warnings.contains(.externalProfileDataExcluded)
        )
        XCTAssertEqual(
            decoded.profileDataInventory.map(\.declaredPath),
            [missingManagedPath, missingExternalPath]
        )
        XCTAssertFalse(
            metadata.header.disclosure.includes(.profileDataInventory)
        )
        XCTAssertTrue(
            metadata.header.disclosure.excludes(
                .managedProfileDataPayloads
            )
        )
    }

    func testSafeExportRejectsMalformedEnvironmentInsteadOfLeakingIt() {
        let library = makeLibrary(
            environmentText: "OPENAI_API_KEY=secret\u{0000}suffix"
        )

        XCTAssertThrowsError(
            try service.makeLibraryMetadataExport(
                library: library,
                sensitiveLiteralPolicy: .redact
            )
        ) { error in
            XCTAssertEqual(
                error as? PortableConfigurationError,
                .invalidEnvironment(owner: "Fixture / Profile")
            )
        }
    }

    func testFullBackupRejectsUnsafeArchiveInventoryWithoutReadingPaths() {
        let inventory = [
            PortableProfileDataInventoryEntry.managed(
                applicationStorageID: UUID(),
                profileStorageID: UUID(),
                kind: .userData,
                declaredPath: "/not-read/profile",
                archiveRelativePath: "../escape"
            )
        ]

        XCTAssertThrowsError(
            try service.makeFullBackupManifest(
                library: makeLibrary(environmentText: ""),
                settings: makeSettings(),
                profileDataInventory: inventory,
                sensitiveLiteralPolicy: .redact
            )
        ) { error in
            XCTAssertEqual(
                error as? PortableConfigurationError,
                .invalidProfileDataInventory
            )
        }
    }

    private func makeLibrary(environmentText: String) -> LibraryDocument {
        LibraryDocument(
            revision: LibraryRevision(rawValue: 7),
            applications: [
                ManagedApplication(
                    id: UUID(
                        uuidString:
                            "11111111-1111-1111-1111-111111111111"
                    )!,
                    storageID: UUID(
                        uuidString:
                            "22222222-2222-2222-2222-222222222222"
                    )!,
                    displayName: "Fixture",
                    bundleIdentifier: "com.example.fixture",
                    appPath: "/Applications/Fixture.app",
                    baseStoragePath: "/Users/example/Profiles",
                    profiles: [
                        LaunchProfile(
                            id: UUID(
                                uuidString:
                                    "33333333-3333-3333-3333-333333333333"
                            )!,
                            storageID: UUID(
                                uuidString:
                                    "44444444-4444-4444-4444-444444444444"
                            )!,
                            name: "Profile",
                            environmentText: environmentText,
                            sensitiveEnvironmentKeys: ["CUSTOM_CREDENTIAL"]
                        )
                    ]
                )
            ]
        )
    }

    private func makeSettings() -> PortableSettingsSnapshot {
        PortableSettingsSnapshot(
            profileTemplates: [
                ProfileTemplate(
                    name: "Default",
                    notes: "Template note"
                )
            ],
            defaultBaseStoragePath: "/Users/example/Profiles",
            confirmBeforeLaunch: true,
            appearance: .system
        )
    }

    private func profileEnvironment(
        in library: LibraryDocument
    ) throws -> String {
        try XCTUnwrap(
            library.applications.first?.profiles.first?.environmentText
        )
    }
}
