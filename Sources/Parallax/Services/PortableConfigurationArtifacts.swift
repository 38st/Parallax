import Foundation

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

struct PortableFullBackupManifest: Codable, Equatable, Sendable {
    let header: PortableArtifactHeader
    let library: LibraryDocument
    let settings: PortableSettingsSnapshot
    let profileDataInventory: [PortableProfileDataInventoryEntry]
}
