import Foundation

enum IsolationPathOwnership: String, Codable, Hashable, Sendable {
    /// Parallax owns the value and may rewrite it when managed storage moves.
    case generated
    /// The user or an import owns the value; relocation must preserve it exactly.
    case explicit
    /// Older documents did not persist provenance. Relocation may classify an
    /// exact match for the prior generated path, but preserves every other value.
    case legacyUnknown
}

struct ProfileIsolationOwnership: Codable, Hashable, Sendable {
    var userData: IsolationPathOwnership
    var codexHome: IsolationPathOwnership

    init(
        userData: IsolationPathOwnership = .explicit,
        codexHome: IsolationPathOwnership = .explicit
    ) {
        self.userData = userData
        self.codexHome = codexHome
    }

    static let explicit = ProfileIsolationOwnership()
    static let legacyUnknown = ProfileIsolationOwnership(
        userData: .legacyUnknown,
        codexHome: .legacyUnknown
    )
}

struct LaunchProfile: Identifiable, Codable, Hashable {
    let id: UUID
    let storageID: UUID
    var name: String
    var argumentsText: String
    var environmentText: String
    var notes: String
    var isolationOwnership: ProfileIsolationOwnership
    var lastLaunchedAt: Date?

    init(
        id: UUID = UUID(),
        storageID: UUID = UUID(),
        name: String,
        argumentsText: String = "",
        environmentText: String = "",
        notes: String = "",
        isolationOwnership: ProfileIsolationOwnership = .legacyUnknown,
        lastLaunchedAt: Date? = nil
    ) {
        self.id = id
        self.storageID = storageID
        self.name = name
        self.argumentsText = argumentsText
        self.environmentText = environmentText
        self.notes = notes
        self.isolationOwnership = isolationOwnership
        self.lastLaunchedAt = lastLaunchedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case storageID
        case name
        case argumentsText
        case environmentText
        case notes
        case isolationOwnership
        case lastLaunchedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        storageID = try container.decode(UUID.self, forKey: .storageID)
        name = try container.decode(String.self, forKey: .name)
        argumentsText = try container.decode(String.self, forKey: .argumentsText)
        environmentText = try container.decode(String.self, forKey: .environmentText)
        notes = try container.decode(String.self, forKey: .notes)
        isolationOwnership = try container.decodeIfPresent(
            ProfileIsolationOwnership.self,
            forKey: .isolationOwnership
        ) ?? .legacyUnknown
        lastLaunchedAt = try container.decodeIfPresent(Date.self, forKey: .lastLaunchedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id.uuidString.lowercased(), forKey: .id)
        try container.encode(storageID.uuidString.lowercased(), forKey: .storageID)
        try container.encode(name, forKey: .name)
        try container.encode(argumentsText, forKey: .argumentsText)
        try container.encode(environmentText, forKey: .environmentText)
        try container.encode(notes, forKey: .notes)
        try container.encode(isolationOwnership, forKey: .isolationOwnership)
        try container.encodeIfPresent(lastLaunchedAt, forKey: .lastLaunchedAt)
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

    func preservingIdentity(of persisted: LaunchProfile) -> LaunchProfile {
        LaunchProfile(
            id: persisted.id,
            storageID: persisted.storageID,
            name: name,
            argumentsText: argumentsText,
            environmentText: environmentText,
            notes: notes,
            isolationOwnership: isolationOwnership,
            lastLaunchedAt: lastLaunchedAt
        )
    }

    func duplicatedWithFreshIdentity(name: String? = nil) -> LaunchProfile {
        LaunchProfile(
            name: name ?? self.name,
            argumentsText: argumentsText,
            environmentText: environmentText,
            notes: notes,
            isolationOwnership: isolationOwnership,
            lastLaunchedAt: lastLaunchedAt
        )
    }
}
