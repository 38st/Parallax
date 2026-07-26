import Foundation

struct ManagedApplication: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let storageID: UUID
    var displayName: String
    var bundleIdentifier: String?
    var appPath: String
    var preset: AppPreset
    var baseStoragePath: String?
    var profiles: [LaunchProfile]

    init(
        id: UUID = UUID(),
        storageID: UUID = UUID(),
        displayName: String,
        bundleIdentifier: String? = nil,
        appPath: String,
        preset: AppPreset = .automatic,
        baseStoragePath: String? = nil,
        profiles: [LaunchProfile] = []
    ) {
        self.id = id
        self.storageID = storageID
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.preset = preset
        self.baseStoragePath = baseStoragePath
        self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case storageID
        case displayName
        case bundleIdentifier
        case appPath
        case preset
        case baseStoragePath
        case profiles
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        storageID = try container.decode(UUID.self, forKey: .storageID)
        displayName = try container.decode(String.self, forKey: .displayName)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        appPath = try container.decode(String.self, forKey: .appPath)
        preset = try container.decodeIfPresent(AppPreset.self, forKey: .preset) ?? .automatic
        baseStoragePath = try container.decodeIfPresent(String.self, forKey: .baseStoragePath)
        profiles = try container.decode([LaunchProfile].self, forKey: .profiles)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(storageID.uuidString.lowercased(), forKey: .storageID)
        try container.encode(displayName, forKey: .displayName)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encode(appPath, forKey: .appPath)
        try container.encode(preset, forKey: .preset)
        try container.encodeIfPresent(baseStoragePath, forKey: .baseStoragePath)
        try container.encode(profiles, forKey: .profiles)
    }

    func preservingIdentity(of persisted: ManagedApplication) -> ManagedApplication {
        ManagedApplication(
            id: persisted.id,
            storageID: persisted.storageID,
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            appPath: appPath,
            preset: preset,
            baseStoragePath: baseStoragePath,
            profiles: profiles
        )
    }

    func duplicatedWithFreshIdentity() -> ManagedApplication {
        ManagedApplication(
            displayName: displayName,
            bundleIdentifier: bundleIdentifier,
            appPath: appPath,
            preset: preset,
            baseStoragePath: baseStoragePath,
            profiles: profiles.map { $0.duplicatedWithFreshIdentity() }
        )
    }
}
