import Foundation

enum PortableConfigurationError: Error, Equatable, Sendable, LocalizedError {
    case inputTooLarge
    case invalidArguments(owner: String)
    case invalidEnvironment(owner: String)
    case invalidArtifactPayload
    case invalidProfileDataInventory
    case unsupportedSchemaVersion(Int)
    case unexpectedArtifactKind
    case invalidDisclosure

    var errorDescription: String? {
        switch self {
        case .inputTooLarge:
            String(
                localized:
                    "The portable configuration exceeds the supported import size limit."
            )
        case .invalidArguments(let owner):
            String(
                localized:
                    "The portable configuration contains invalid launch arguments for \(owner)."
            )
        case .invalidEnvironment(let owner):
            String(
                localized:
                    "The portable configuration contains an invalid environment for \(owner)."
            )
        case .invalidArtifactPayload:
            String(
                localized:
                    "The portable configuration payload is missing or malformed."
            )
        case .invalidProfileDataInventory:
            String(
                localized:
                    "The portable configuration contains an invalid profile data inventory."
            )
        case .unsupportedSchemaVersion:
            String(
                localized:
                    "The portable configuration uses an unsupported schema version."
            )
        case .unexpectedArtifactKind:
            String(
                localized:
                    "This portable configuration type cannot be imported as library metadata."
            )
        case .invalidDisclosure:
            String(
                localized:
                    "The portable configuration content disclosure is invalid."
            )
        }
    }
}

/// Builds portable metadata values only. It deliberately has no filesystem or
/// Keychain dependency: full-backup paths are declarations for an archive
/// coordinator to validate and copy in a separate transactional operation.
extension PortableConfigurationService {
    func makeLibraryMetadataExport(
        library: LibraryDocument,
        sensitiveLiteralPolicy: SensitiveLiteralExportPolicy
    ) throws -> PortableLibraryMetadataExport {
        PortableLibraryMetadataExport(
            header: PortableArtifactHeaderContract.header(
                kind: .libraryMetadata,
                policy: sensitiveLiteralPolicy
            ),
            library: try PortableConfigurationSanitizerAdapter.library(
                library,
                policy: sensitiveLiteralPolicy
            )
        )
    }

    func makeSettingsAndTemplatesExport(
        settings: PortableSettingsSnapshot,
        sensitiveLiteralPolicy: SensitiveLiteralExportPolicy
    ) throws -> PortableSettingsAndTemplatesExport {
        PortableSettingsAndTemplatesExport(
            header: PortableArtifactHeaderContract.header(
                kind: .settingsAndTemplates,
                policy: sensitiveLiteralPolicy
            ),
            settings: try PortableConfigurationSanitizerAdapter.settings(
                settings,
                policy: sensitiveLiteralPolicy
            )
        )
    }

    func makePortableConfigurationExport(
        library: LibraryDocument,
        settings: PortableSettingsSnapshot,
        sensitiveLiteralPolicy: SensitiveLiteralExportPolicy
    ) throws -> PortableConfigurationExport {
        PortableConfigurationExport(
            header: PortableArtifactHeaderContract.header(
                kind: .portableConfiguration,
                policy: sensitiveLiteralPolicy
            ),
            library: try PortableConfigurationSanitizerAdapter.library(
                library,
                policy: sensitiveLiteralPolicy
            ),
            settings: try PortableConfigurationSanitizerAdapter.settings(
                settings,
                policy: sensitiveLiteralPolicy
            )
        )
    }

    func makeFullBackupManifest(
        library: LibraryDocument,
        settings: PortableSettingsSnapshot,
        profileDataInventory: [PortableProfileDataInventoryEntry],
        sensitiveLiteralPolicy: SensitiveLiteralExportPolicy
    ) throws -> PortableFullBackupManifest {
        try PortableProfileDataInventoryValidator.validate(
            profileDataInventory
        )
        return PortableFullBackupManifest(
            header: PortableArtifactHeaderContract.header(
                kind: .fullBackup,
                policy: sensitiveLiteralPolicy
            ),
            library: try PortableConfigurationSanitizerAdapter.library(
                library,
                policy: sensitiveLiteralPolicy
            ),
            settings: try PortableConfigurationSanitizerAdapter.settings(
                settings,
                policy: sensitiveLiteralPolicy
            ),
            profileDataInventory: profileDataInventory
        )
    }
}
