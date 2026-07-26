import Foundation

enum LegacyStorageNameProvenance: Hashable, Sendable {
    case missing
    case null
    case value(String)

    var value: String? {
        guard case let .value(value) = self else { return nil }
        return value
    }
}

struct LegacyLaunchProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var argumentsText: String
    var environmentText: String
    var notes: String
    let storageNameProvenance: LegacyStorageNameProvenance
    var lastLaunchedAt: Date?

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case argumentsText
        case environmentText
        case notes
        case storageName
        case lastLaunchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        argumentsText = try container.decode(String.self, forKey: .argumentsText)
        environmentText = try container.decode(String.self, forKey: .environmentText)
        notes = try container.decode(String.self, forKey: .notes)
        lastLaunchedAt = try container.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)

        if !container.contains(.storageName) {
            storageNameProvenance = .missing
        } else if try container.decodeNil(forKey: .storageName) {
            storageNameProvenance = .null
        } else {
            storageNameProvenance = .value(
                try container.decode(String.self, forKey: .storageName)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(argumentsText, forKey: .argumentsText)
        try container.encode(environmentText, forKey: .environmentText)
        try container.encode(notes, forKey: .notes)
        try container.encodeIfPresent(lastLaunchedAt, forKey: .lastLaunchedAt)

        switch storageNameProvenance {
        case .missing:
            break
        case .null:
            try container.encodeNil(forKey: .storageName)
        case let .value(value):
            try container.encode(value, forKey: .storageName)
        }
    }

    var storageName: String? {
        storageNameProvenance.value
    }

    var arguments: [String] {
        ShellWordsParser.parse(argumentsText)
    }

    var environment: [String: String] {
        environmentText
            .split(whereSeparator: \.isNewline)
            .reduce(into: [String: String]()) { result, line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return }
                guard let separator = trimmed.firstIndex(of: "=") else { return }

                let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
                let valueStart = trimmed.index(after: separator)
                let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    result[key] = value
                }
            }
    }
}

struct LegacyManagedApplication: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    var bundleIdentifier: String?
    var appPath: String
    var preset: AppPreset
    var baseStoragePath: String?
    var profiles: [LegacyLaunchProfile]

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
        profiles = try container.decode([LegacyLaunchProfile].self, forKey: .profiles)
    }
}

struct LegacyLibraryDocument: Codable, Hashable, Sendable {
    let version: Int
    var applications: [LegacyManagedApplication]
}

struct LegacyLibrary: Hashable, Sendable {
    enum Format: Hashable, Sendable {
        case versioned(Int)
        case rawApplicationArray
    }

    let format: Format
    let applications: [LegacyManagedApplication]
}

enum LibraryLoadResult: Hashable, Sendable {
    case current([ManagedApplication])
    case migrationRequired(LegacyLibrary)
}
