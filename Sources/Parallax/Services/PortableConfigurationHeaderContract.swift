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

enum PortableArtifactHeaderContract {
    static func header(
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

    static func validate(
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

    private static func policy(
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
}

extension PortableConfigurationService {
    func validate(
        _ header: PortableArtifactHeader,
        expectedKind: PortableArtifactKind
    ) throws {
        try PortableArtifactHeaderContract.validate(
            header,
            expectedKind: expectedKind
        )
    }
}
