import Foundation

struct ManagedApplication: Identifiable, Codable, Hashable {
    var id: UUID
    var displayName: String
    var bundleIdentifier: String?
    var appPath: String
    var preset: AppPreset
    var baseStoragePath: String?
    var profiles: [LaunchProfile]

    init(
        id: UUID = UUID(),
        displayName: String,
        bundleIdentifier: String? = nil,
        appPath: String,
        preset: AppPreset = .automatic,
        baseStoragePath: String? = nil,
        profiles: [LaunchProfile] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.bundleIdentifier = bundleIdentifier
        self.appPath = appPath
        self.preset = preset
        self.baseStoragePath = baseStoragePath
        self.profiles = profiles
    }

    private enum CodingKeys: String, CodingKey {
        case id
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
        displayName = try container.decode(String.self, forKey: .displayName)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        appPath = try container.decode(String.self, forKey: .appPath)
        preset = try container.decodeIfPresent(AppPreset.self, forKey: .preset) ?? .automatic
        baseStoragePath = try container.decodeIfPresent(String.self, forKey: .baseStoragePath)
        profiles = try container.decode([LaunchProfile].self, forKey: .profiles)
    }
}
