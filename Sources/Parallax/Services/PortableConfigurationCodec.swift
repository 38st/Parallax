import Foundation

struct PortableConfigurationService: Sendable {
    private let maximumEncodedArtifactBytes: Int

    init(
        maximumEncodedArtifactBytes: Int = LibraryImportLimits().maximumBytes
    ) {
        self.maximumEncodedArtifactBytes = maximumEncodedArtifactBytes
    }

    func encode<Artifact: Encodable>(
        _ artifact: Artifact
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(artifact)
    }

    func decodeLibraryMetadataExport(
        from data: Data
    ) throws -> PortableLibraryMetadataExport {
        let artifact = try decode(
            PortableLibraryMetadataExport.self,
            from: data
        )
        try validate(
            artifact.header,
            expectedKind: .libraryMetadata
        )
        return artifact
    }

    func decodeSettingsAndTemplatesExport(
        from data: Data
    ) throws -> PortableSettingsAndTemplatesExport {
        let artifact = try decode(
            PortableSettingsAndTemplatesExport.self,
            from: data
        )
        try validate(
            artifact.header,
            expectedKind: .settingsAndTemplates
        )
        return artifact
    }

    func decodePortableConfigurationExport(
        from data: Data
    ) throws -> PortableConfigurationExport {
        let artifact = try decode(
            PortableConfigurationExport.self,
            from: data
        )
        try validate(
            artifact.header,
            expectedKind: .portableConfiguration
        )
        return artifact
    }

    func decodeFullBackupManifest(
        from data: Data
    ) throws -> PortableFullBackupManifest {
        let artifact = try decode(
            PortableFullBackupManifest.self,
            from: data
        )
        try validate(artifact.header, expectedKind: .fullBackup)
        try PortableProfileDataInventoryValidator.validate(
            artifact.profileDataInventory
        )
        return artifact
    }

    private func decode<Artifact: Decodable>(
        _ type: Artifact.Type,
        from data: Data
    ) throws -> Artifact {
        guard data.count <= maximumEncodedArtifactBytes else {
            throw PortableConfigurationError.inputTooLarge
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
