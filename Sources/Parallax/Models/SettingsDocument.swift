import Foundation

struct SettingsRevision:
    RawRepresentable,
    Codable,
    Hashable,
    Sendable,
    Comparable
{
    static let zero = SettingsRevision(rawValue: 0)

    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UInt64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (
        lhs: SettingsRevision,
        rhs: SettingsRevision
    ) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct SettingsDocument: Encodable, Equatable, Sendable {
    static let currentSchemaVersion: UInt64 = 1

    struct Template: Encodable, Equatable, Sendable {
        let id: String
        let name: String
        let argumentsText: String
        let environmentText: String
        let notes: String
    }

    struct VisualIdentity: Encodable, Equatable, Sendable {
        let profileID: String
        let symbol: String
        let color: String
    }

    let schemaVersion: UInt64
    let revision: SettingsRevision
    let profileTemplates: [Template]
    let defaultBaseStoragePath: String
    let confirmBeforeLaunch: Bool
    let automaticallyRecoverCrashedApps: Bool
    let appearance: String
    let profileVisualIdentities: [VisualIdentity]

    init(
        schemaVersion: UInt64 = Self.currentSchemaVersion,
        revision: SettingsRevision,
        profileTemplates: [Template],
        defaultBaseStoragePath: String,
        confirmBeforeLaunch: Bool,
        automaticallyRecoverCrashedApps: Bool,
        appearance: String,
        profileVisualIdentities: [VisualIdentity]
    ) {
        self.schemaVersion = schemaVersion
        self.revision = revision
        self.profileTemplates = profileTemplates
        self.defaultBaseStoragePath = defaultBaseStoragePath
        self.confirmBeforeLaunch = confirmBeforeLaunch
        self.automaticallyRecoverCrashedApps =
            automaticallyRecoverCrashedApps
        self.appearance = appearance
        self.profileVisualIdentities = profileVisualIdentities
    }
}
