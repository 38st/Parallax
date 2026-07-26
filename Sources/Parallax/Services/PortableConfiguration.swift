import Foundation

enum PortableArtifactKind: String, Codable, Equatable, Sendable {
    case libraryMetadata
    case settingsAndTemplates
    case portableConfiguration
    case fullBackup
}

enum PortableContentKind: String, Codable, Equatable, Sendable {
    case libraryMetadata
    case settingsAndTemplates
    case profileDataInventory
    case managedProfileDataPayloads
    case externalProfileData
    case applicationBinaries
    case keychainReferenceTokens
    case keychainSecretValues
    case sensitiveLiteralValues
}

enum PortableArtifactWarning: String, Codable, Equatable, Sendable {
    case applicationPathsMayRequireRelocation
    case configuredStoragePathsMayRequireRelocation
    case keychainReferencesRequireSourceMacKeychain
    case externalProfileDataExcluded
    case profileDataInventoryNotFilesystemVerified
    case sensitiveLiteralsIncludedAfterExplicitConfirmation
}

enum PortableSensitiveLiteralHandling:
    String,
    Codable,
    Equatable,
    Sendable
{
    case omitted
    case redacted
    case includedAfterExplicitConfirmation
}

struct PortableContentDisclosure: Codable, Equatable, Sendable {
    let includedContent: [PortableContentKind]
    let excludedContent: [PortableContentKind]

    init(
        included: [PortableContentKind],
        excluded: [PortableContentKind]
    ) {
        includedContent = Self.canonical(included)
        excludedContent = Self.canonical(excluded)
    }

    func includes(_ content: PortableContentKind) -> Bool {
        includedContent.contains(content)
    }

    func excludes(_ content: PortableContentKind) -> Bool {
        excludedContent.contains(content)
    }

    private static func canonical(
        _ content: [PortableContentKind]
    ) -> [PortableContentKind] {
        Array(Set(content)).sorted { $0.rawValue < $1.rawValue }
    }
}

struct PortableArtifactHeader: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let schemaVersion: Int
    let kind: PortableArtifactKind
    let disclosure: PortableContentDisclosure
    let warnings: [PortableArtifactWarning]
    let sensitiveLiteralHandling: PortableSensitiveLiteralHandling
}

enum PortableAppearance: String, Codable, Equatable, Sendable {
    case system
    case light
    case dark

    init(_ appearance: AppAppearance) {
        switch appearance {
        case .system:
            self = .system
        case .light:
            self = .light
        case .dark:
            self = .dark
        }
    }

    var appAppearance: AppAppearance {
        switch self {
        case .system:
            .system
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

struct PortableProfileTemplate: Codable, Equatable, Sendable {
    let id: UUID
    let name: String
    let argumentsText: String
    let environmentText: String
    let notes: String

    init(_ template: ProfileTemplate) {
        id = template.id
        name = template.name
        argumentsText = template.argumentsText
        environmentText = template.environmentText
        notes = template.notes
    }

    init(
        id: UUID,
        name: String,
        argumentsText: String,
        environmentText: String,
        notes: String
    ) {
        self.id = id
        self.name = name
        self.argumentsText = argumentsText
        self.environmentText = environmentText
        self.notes = notes
    }

    var profileTemplate: ProfileTemplate {
        ProfileTemplate(
            id: id,
            name: name,
            argumentsText: argumentsText,
            environmentText: environmentText,
            notes: notes
        )
    }
}

struct PortableSettingsSnapshot: Codable, Equatable, Sendable {
    let profileTemplates: [PortableProfileTemplate]
    let defaultBaseStoragePath: String
    let confirmBeforeLaunch: Bool
    let appearance: PortableAppearance

    init(
        profileTemplates: [ProfileTemplate],
        defaultBaseStoragePath: String,
        confirmBeforeLaunch: Bool,
        appearance: AppAppearance
    ) {
        self.profileTemplates = profileTemplates.map(
            PortableProfileTemplate.init
        )
        self.defaultBaseStoragePath = defaultBaseStoragePath
        self.confirmBeforeLaunch = confirmBeforeLaunch
        self.appearance = PortableAppearance(appearance)
    }

    init(
        portableProfileTemplates: [PortableProfileTemplate],
        defaultBaseStoragePath: String,
        confirmBeforeLaunch: Bool,
        appearance: PortableAppearance
    ) {
        profileTemplates = portableProfileTemplates
        self.defaultBaseStoragePath = defaultBaseStoragePath
        self.confirmBeforeLaunch = confirmBeforeLaunch
        self.appearance = appearance
    }
}

struct PortableLibraryMetadataExport: Codable, Equatable, Sendable {
    let header: PortableArtifactHeader
    let library: LibraryDocument
}

struct PortableSettingsAndTemplatesExport: Codable, Equatable, Sendable {
    let header: PortableArtifactHeader
    let settings: PortableSettingsSnapshot
}

struct PortableConfigurationExport: Codable, Equatable, Sendable {
    let header: PortableArtifactHeader
    let library: LibraryDocument
    let settings: PortableSettingsSnapshot
}

enum PortableProfileDataKind: String, Codable, Equatable, Sendable {
    case profileRoot
    case userData
    case codexHome
}

enum PortableProfileDataSource: String, Codable, Equatable, Sendable {
    case managed
    case external
}

enum PortableProfileDataDisposition: String, Codable, Equatable, Sendable {
    case includedPayload
    case excludedExternal
}

struct PortableProfileDataInventoryEntry:
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    let applicationStorageID: UUID
    let profileStorageID: UUID
    let kind: PortableProfileDataKind
    let declaredPath: String
    let source: PortableProfileDataSource
    let disposition: PortableProfileDataDisposition
    let archiveRelativePath: String?

    static func managed(
        applicationStorageID: UUID,
        profileStorageID: UUID,
        kind: PortableProfileDataKind,
        declaredPath: String,
        archiveRelativePath: String
    ) -> PortableProfileDataInventoryEntry {
        PortableProfileDataInventoryEntry(
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID,
            kind: kind,
            declaredPath: declaredPath,
            source: .managed,
            disposition: .includedPayload,
            archiveRelativePath: archiveRelativePath
        )
    }

    static func external(
        applicationStorageID: UUID,
        profileStorageID: UUID,
        kind: PortableProfileDataKind,
        declaredPath: String
    ) -> PortableProfileDataInventoryEntry {
        PortableProfileDataInventoryEntry(
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID,
            kind: kind,
            declaredPath: declaredPath,
            source: .external,
            disposition: .excludedExternal,
            archiveRelativePath: nil
        )
    }
}

struct PortableFullBackupManifest: Codable, Equatable, Sendable {
    let header: PortableArtifactHeader
    let library: LibraryDocument
    let settings: PortableSettingsSnapshot
    let profileDataInventory: [PortableProfileDataInventoryEntry]
}

enum PortableConfigurationError: Error, Equatable, Sendable {
    case invalidEnvironment(owner: String)
    case invalidProfileDataInventory
    case unsupportedSchemaVersion(Int)
    case unexpectedArtifactKind
    case invalidDisclosure
}

/// Builds portable metadata values only. It deliberately has no filesystem or
/// Keychain dependency: full-backup paths are declarations for an archive
/// coordinator to validate and copy in a separate transactional operation.
struct PortableConfigurationService: Sendable {
    func makeLibraryMetadataExport(
        library: LibraryDocument,
        sensitiveLiteralPolicy: SensitiveLiteralExportPolicy
    ) throws -> PortableLibraryMetadataExport {
        PortableLibraryMetadataExport(
            header: header(
                kind: .libraryMetadata,
                policy: sensitiveLiteralPolicy
            ),
            library: try sanitizedLibrary(
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
            header: header(
                kind: .settingsAndTemplates,
                policy: sensitiveLiteralPolicy
            ),
            settings: try sanitizedSettings(
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
            header: header(
                kind: .portableConfiguration,
                policy: sensitiveLiteralPolicy
            ),
            library: try sanitizedLibrary(
                library,
                policy: sensitiveLiteralPolicy
            ),
            settings: try sanitizedSettings(
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
        try validate(profileDataInventory)
        return PortableFullBackupManifest(
            header: header(
                kind: .fullBackup,
                policy: sensitiveLiteralPolicy
            ),
            library: try sanitizedLibrary(
                library,
                policy: sensitiveLiteralPolicy
            ),
            settings: try sanitizedSettings(
                settings,
                policy: sensitiveLiteralPolicy
            ),
            profileDataInventory: profileDataInventory
        )
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
        let artifact = try decoder.decode(
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
        let artifact = try decoder.decode(
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
        let artifact = try decoder.decode(
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
        let artifact = try decoder.decode(
            PortableFullBackupManifest.self,
            from: data
        )
        try validate(artifact.header, expectedKind: .fullBackup)
        try validate(artifact.profileDataInventory)
        return artifact
    }

    private var decoder: JSONDecoder {
        JSONDecoder()
    }

    private func sanitizedLibrary(
        _ library: LibraryDocument,
        policy: SensitiveLiteralExportPolicy
    ) throws -> LibraryDocument {
        var applications = library.applications
        for applicationIndex in applications.indices {
            for profileIndex in applications[applicationIndex].profiles.indices {
                var profile =
                    applications[applicationIndex].profiles[profileIndex]
                profile.environmentText = try sanitizedEnvironmentText(
                    profile.environmentText,
                    explicitSensitiveKeys:
                        Set(profile.sensitiveEnvironmentKeys),
                    policy: policy,
                    owner:
                        "\(applications[applicationIndex].displayName) / \(profile.name)"
                )
                applications[applicationIndex].profiles[profileIndex] =
                    profile
            }
        }
        return LibraryDocument(
            revision: library.revision,
            applications: applications
        )
    }

    private func sanitizedSettings(
        _ settings: PortableSettingsSnapshot,
        policy: SensitiveLiteralExportPolicy
    ) throws -> PortableSettingsSnapshot {
        let templates = try settings.profileTemplates.map { template in
            PortableProfileTemplate(
                id: template.id,
                name: template.name,
                argumentsText: template.argumentsText,
                environmentText: try sanitizedEnvironmentText(
                    template.environmentText,
                    explicitSensitiveKeys: [],
                    policy: policy,
                    owner: "Template / \(template.name)"
                ),
                notes: template.notes
            )
        }
        return PortableSettingsSnapshot(
            portableProfileTemplates: templates,
            defaultBaseStoragePath: settings.defaultBaseStoragePath,
            confirmBeforeLaunch: settings.confirmBeforeLaunch,
            appearance: settings.appearance
        )
    }

    private func sanitizedEnvironmentText(
        _ text: String,
        explicitSensitiveKeys: Set<String>,
        policy: SensitiveLiteralExportPolicy,
        owner: String
    ) throws -> String {
        let parsed = LaunchEnvironmentParser.parse(text)
        guard !parsed.hasErrors else {
            throw PortableConfigurationError.invalidEnvironment(
                owner: owner
            )
        }
        let classifier = SensitiveEnvironmentKeyClassifier(
            explicitSensitiveKeys: explicitSensitiveKeys
        )
        var replacements: [(range: NSRange, text: String)] = []
        for entry in parsed.entries {
            guard case .set(let storedText) = entry.operation else {
                continue
            }
            if case .secretReference =
                StoredEnvironmentValue(storedText: storedText)
            {
                continue
            }
            guard classifier.isSensitive(entry.name) else {
                continue
            }
            switch policy {
            case .includeAfterExplicitConfirmation:
                continue
            case .redact:
                guard let valueRange = entry.valueRange else {
                    continue
                }
                replacements.append(
                    (
                        NSRange(
                            location: valueRange.start.utf16Offset,
                            length:
                                valueRange.end.utf16Offset
                                - valueRange.start.utf16Offset
                        ),
                        "<redacted>"
                    )
                )
            case .omit:
                replacements.append(
                    (
                        NSRange(
                            location: entry.range.start.utf16Offset,
                            length:
                                entry.range.end.utf16Offset
                                - entry.range.start.utf16Offset
                        ),
                        "# Omitted sensitive value: \(entry.name)"
                    )
                )
            }
        }

        let result = NSMutableString(string: text)
        for replacement in replacements.sorted(by: {
            $0.range.location > $1.range.location
        }) {
            result.replaceCharacters(
                in: replacement.range,
                with: replacement.text
            )
        }
        return result as String
    }

    private func header(
        kind: PortableArtifactKind,
        policy: SensitiveLiteralExportPolicy
    ) -> PortableArtifactHeader {
        let handling: PortableSensitiveLiteralHandling
        switch policy {
        case .omit:
            handling = .omitted
        case .redact:
            handling = .redacted
        case .includeAfterExplicitConfirmation:
            handling = .includedAfterExplicitConfirmation
        }

        var included: [PortableContentKind] = [
            .keychainReferenceTokens,
        ]
        var excluded: [PortableContentKind] = [
            .applicationBinaries,
            .keychainSecretValues,
        ]
        var warnings: [PortableArtifactWarning] = [
            .keychainReferencesRequireSourceMacKeychain,
        ]
        switch handling {
        case .omitted, .redacted:
            excluded.append(.sensitiveLiteralValues)
        case .includedAfterExplicitConfirmation:
            included.append(.sensitiveLiteralValues)
            warnings.append(
                .sensitiveLiteralsIncludedAfterExplicitConfirmation
            )
        }

        switch kind {
        case .libraryMetadata:
            included.append(.libraryMetadata)
            excluded += [
                .settingsAndTemplates,
                .profileDataInventory,
                .managedProfileDataPayloads,
                .externalProfileData,
            ]
            warnings += [
                .applicationPathsMayRequireRelocation,
                .configuredStoragePathsMayRequireRelocation,
            ]
        case .settingsAndTemplates:
            included.append(.settingsAndTemplates)
            excluded += [
                .libraryMetadata,
                .profileDataInventory,
                .managedProfileDataPayloads,
                .externalProfileData,
            ]
            warnings.append(.configuredStoragePathsMayRequireRelocation)
        case .portableConfiguration:
            included += [.libraryMetadata, .settingsAndTemplates]
            excluded += [
                .profileDataInventory,
                .managedProfileDataPayloads,
                .externalProfileData,
            ]
            warnings += [
                .applicationPathsMayRequireRelocation,
                .configuredStoragePathsMayRequireRelocation,
            ]
        case .fullBackup:
            included += [
                .libraryMetadata,
                .settingsAndTemplates,
                .profileDataInventory,
            ]
            excluded += [
                .managedProfileDataPayloads,
                .externalProfileData,
            ]
            warnings += [
                .applicationPathsMayRequireRelocation,
                .configuredStoragePathsMayRequireRelocation,
                .externalProfileDataExcluded,
                .profileDataInventoryNotFilesystemVerified,
            ]
        }

        return PortableArtifactHeader(
            schemaVersion: PortableArtifactHeader.currentVersion,
            kind: kind,
            disclosure: PortableContentDisclosure(
                included: included,
                excluded: excluded
            ),
            warnings: Array(Set(warnings)).sorted {
                $0.rawValue < $1.rawValue
            },
            sensitiveLiteralHandling: handling
        )
    }

    private func validate(
        _ header: PortableArtifactHeader,
        expectedKind: PortableArtifactKind
    ) throws {
        guard header.schemaVersion == PortableArtifactHeader.currentVersion
        else {
            throw PortableConfigurationError.unsupportedSchemaVersion(
                header.schemaVersion
            )
        }
        guard header.kind == expectedKind else {
            throw PortableConfigurationError.unexpectedArtifactKind
        }
        let included = Set(header.disclosure.includedContent)
        let excluded = Set(header.disclosure.excludedContent)
        guard included.isDisjoint(with: excluded) else {
            throw PortableConfigurationError.invalidDisclosure
        }
        let expected = self.header(
            kind: expectedKind,
            policy: policy(for: header.sensitiveLiteralHandling)
        )
        guard header == expected else {
            throw PortableConfigurationError.invalidDisclosure
        }
    }

    private func policy(
        for handling: PortableSensitiveLiteralHandling
    ) -> SensitiveLiteralExportPolicy {
        switch handling {
        case .omitted:
            .omit
        case .redacted:
            .redact
        case .includedAfterExplicitConfirmation:
            .includeAfterExplicitConfirmation
        }
    }

    private func validate(
        _ inventory: [PortableProfileDataInventoryEntry]
    ) throws {
        var archivePaths: Set<String> = []
        var entries: Set<PortableProfileDataInventoryEntry> = []
        for entry in inventory {
            guard
                isSafeAbsoluteDeclaredPath(entry.declaredPath),
                entries.insert(entry).inserted
            else {
                throw PortableConfigurationError.invalidProfileDataInventory
            }
            switch (entry.source, entry.disposition) {
            case (.managed, .includedPayload):
                guard
                    let archivePath = entry.archiveRelativePath,
                    isSafeArchiveRelativePath(archivePath),
                    archivePaths.insert(archivePath).inserted
                else {
                    throw PortableConfigurationError
                        .invalidProfileDataInventory
                }
            case (.external, .excludedExternal):
                guard entry.archiveRelativePath == nil else {
                    throw PortableConfigurationError
                        .invalidProfileDataInventory
                }
            default:
                throw PortableConfigurationError.invalidProfileDataInventory
            }
        }
    }

    private func isSafeAbsoluteDeclaredPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !containsControlCharacter(path) else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return !components.contains { $0 == "." || $0 == ".." }
    }

    private func isSafeArchiveRelativePath(_ path: String) -> Bool {
        guard
            !path.isEmpty,
            !path.hasPrefix("/"),
            !path.hasSuffix("/"),
            !path.contains("\\"),
            !containsControlCharacter(path)
        else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        return components.allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":")
        }
    }

    private func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0)
        }
    }
}
