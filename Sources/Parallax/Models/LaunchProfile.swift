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

enum LaunchConfigurationTrust: String, Codable, Hashable, Sendable {
    case local
    case importedPendingReview
}

struct LaunchProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let storageID: UUID
    var name: String
    var argumentsText: String
    var environmentText: String
    var notes: String
    var isolationOwnership: ProfileIsolationOwnership
    var childEnvironmentPolicy: ChildEnvironmentPolicy
    var sensitiveEnvironmentKeys: [String]
    var launchConfigurationTrust: LaunchConfigurationTrust
    var lastLaunchedAt: Date?

    init(
        id: UUID = UUID(),
        storageID: UUID = UUID(),
        name: String,
        argumentsText: String = "",
        environmentText: String = "",
        notes: String = "",
        isolationOwnership: ProfileIsolationOwnership = .explicit,
        childEnvironmentPolicy: ChildEnvironmentPolicy = .safeDefault,
        sensitiveEnvironmentKeys: [String] = [],
        launchConfigurationTrust: LaunchConfigurationTrust = .local,
        lastLaunchedAt: Date? = nil
    ) {
        self.id = id
        self.storageID = storageID
        self.name = name
        self.argumentsText = argumentsText
        self.environmentText = environmentText
        self.notes = notes
        self.isolationOwnership = isolationOwnership
        self.childEnvironmentPolicy = childEnvironmentPolicy
        self.sensitiveEnvironmentKeys = Array(
            Set(sensitiveEnvironmentKeys)
        ).sorted()
        self.launchConfigurationTrust = launchConfigurationTrust
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
        case childEnvironmentPolicy
        case sensitiveEnvironmentKeys
        case launchConfigurationTrust
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
        childEnvironmentPolicy = try container.decodeIfPresent(
            ChildEnvironmentPolicy.self,
            forKey: .childEnvironmentPolicy
        ) ?? .safeDefault
        sensitiveEnvironmentKeys = Array(
            Set(
                try container.decodeIfPresent(
                    [String].self,
                    forKey: .sensitiveEnvironmentKeys
                ) ?? []
            )
        ).sorted()
        launchConfigurationTrust = try container.decodeIfPresent(
            LaunchConfigurationTrust.self,
            forKey: .launchConfigurationTrust
        ) ?? .local
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
        try container.encode(
            childEnvironmentPolicy,
            forKey: .childEnvironmentPolicy
        )
        try container.encode(
            sensitiveEnvironmentKeys.sorted(),
            forKey: .sensitiveEnvironmentKeys
        )
        try container.encode(
            launchConfigurationTrust,
            forKey: .launchConfigurationTrust
        )
        try container.encodeIfPresent(lastLaunchedAt, forKey: .lastLaunchedAt)
    }

    var arguments: [String] {
        LaunchArgumentParser.parse(argumentsText).words
    }

    var environment: [String: String] {
        LaunchEnvironmentParser.parse(environmentText).effectiveValues
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
            childEnvironmentPolicy: childEnvironmentPolicy,
            sensitiveEnvironmentKeys: sensitiveEnvironmentKeys,
            launchConfigurationTrust: launchConfigurationTrust,
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
            childEnvironmentPolicy: childEnvironmentPolicy,
            sensitiveEnvironmentKeys: sensitiveEnvironmentKeys,
            launchConfigurationTrust: launchConfigurationTrust,
            lastLaunchedAt: lastLaunchedAt
        )
    }
}
