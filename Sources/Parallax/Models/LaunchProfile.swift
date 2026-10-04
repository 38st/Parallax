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
    var firefoxProfile: IsolationPathOwnership
    var extensions: IsolationPathOwnership

    init(
        userData: IsolationPathOwnership = .explicit,
        codexHome: IsolationPathOwnership = .explicit,
        firefoxProfile: IsolationPathOwnership = .explicit,
        extensions: IsolationPathOwnership = .explicit
    ) {
        self.userData = userData
        self.codexHome = codexHome
        self.firefoxProfile = firefoxProfile
        self.extensions = extensions
    }

    private enum CodingKeys: String, CodingKey {
        case userData, codexHome, firefoxProfile, extensions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        userData = try values.decode(IsolationPathOwnership.self, forKey: .userData)
        codexHome = try values.decode(IsolationPathOwnership.self, forKey: .codexHome)
        firefoxProfile = try values.decodeIfPresent(IsolationPathOwnership.self, forKey: .firefoxProfile) ?? .explicit
        extensions = try values.decodeIfPresent(IsolationPathOwnership.self, forKey: .extensions) ?? .explicit
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(userData, forKey: .userData)
        try values.encode(codexHome, forKey: .codexHome)
        // Preserve the prior encoding when the new options have never been generated.
        if firefoxProfile != .explicit { try values.encode(firefoxProfile, forKey: .firefoxProfile) }
        if extensions != .explicit { try values.encode(extensions, forKey: .extensions) }
    }

    static let explicit = ProfileIsolationOwnership()
    static let legacyUnknown = ProfileIsolationOwnership(
        userData: .legacyUnknown,
        codexHome: .legacyUnknown
    )
}

struct ImportedLaunchConfigurationFingerprint:
    Codable,
    Hashable,
    Sendable
{
    let sha256: String
}

struct ImportedLaunchApproval: Codable, Hashable, Sendable {
    let configurationFingerprint: ImportedLaunchConfigurationFingerprint
    let approvedAt: Date

    func matches(
        _ fingerprint: ImportedLaunchConfigurationFingerprint
    ) -> Bool {
        configurationFingerprint == fingerprint
    }
}

enum LaunchConfigurationTrust: Hashable, Sendable, RawRepresentable {
    typealias RawValue = String

    case local
    case importedPendingReview
    case importedApproved(ImportedLaunchApproval)

    init?(rawValue: String) {
        switch rawValue {
        case "local":
            self = .local
        case "importedPendingReview":
            self = .importedPendingReview
        default:
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .local:
            "local"
        case .importedPendingReview:
            "importedPendingReview"
        case .importedApproved:
            "importedApproved"
        }
    }

    var isImported: Bool {
        switch self {
        case .local:
            false
        case .importedPendingReview, .importedApproved:
            true
        }
    }

    func invalidatingImportedApproval() -> LaunchConfigurationTrust {
        isImported ? .importedPendingReview : .local
    }
}

extension LaunchConfigurationTrust: Codable {
    private enum State: String, Codable {
        case local
        case importedPendingReview
        case importedApproved
    }

    private enum CodingKeys: String, CodingKey {
        case state
        case approval
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let rawValue = try? container.decode(String.self)
        {
            guard let trust = LaunchConfigurationTrust(rawValue: rawValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription:
                        "Unsupported launch configuration trust state."
                )
            }
            self = trust
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(State.self, forKey: .state)
        switch state {
        case .local:
            self = .local
        case .importedPendingReview:
            self = .importedPendingReview
        case .importedApproved:
            self = .importedApproved(
                try container.decode(
                    ImportedLaunchApproval.self,
                    forKey: .approval
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .local:
            var container = encoder.singleValueContainer()
            try container.encode(State.local.rawValue)
        case .importedPendingReview:
            var container = encoder.singleValueContainer()
            try container.encode(State.importedPendingReview.rawValue)
        case .importedApproved(let approval):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(State.importedApproved, forKey: .state)
            try container.encode(approval, forKey: .approval)
        }
    }
}

struct LaunchProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let storageID: UUID
    var name: String
    var argumentsText: String {
        didSet {
            if oldValue != argumentsText {
                for folder in PresetIsolationFolder.allCases {
                    let oldOption = folder.resolve(in: LaunchArgumentParser.parse(oldValue).words)
                    let newOption = folder.resolve(in: LaunchArgumentParser.parse(argumentsText).words)
                    if oldOption.values != newOption.values || oldOption.isPresent != newOption.isPresent {
                        isolationOwnership[keyPath: folder.ownershipKeyPath] = .explicit
                    }
                }
                invalidateImportedApproval()
            }
        }
    }
    var environmentText: String {
        didSet {
            if oldValue != environmentText {
                invalidateImportedApproval()
            }
        }
    }
    var notes: String
    var isolationOwnership: ProfileIsolationOwnership {
        didSet {
            if oldValue != isolationOwnership {
                invalidateImportedApproval()
            }
        }
    }
    var childEnvironmentPolicy: ChildEnvironmentPolicy {
        didSet {
            if oldValue != childEnvironmentPolicy {
                invalidateImportedApproval()
            }
        }
    }
    var sensitiveEnvironmentKeys: [String] {
        didSet {
            if oldValue != sensitiveEnvironmentKeys {
                invalidateImportedApproval()
            }
        }
    }
    var launchConfigurationTrust: LaunchConfigurationTrust
    var lastLaunchedAt: Date?
    var accountLink: SpaceAccountLink?

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
        lastLaunchedAt: Date? = nil,
        accountLink: SpaceAccountLink? = nil
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
        self.accountLink = accountLink
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
        case accountLink
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
        accountLink = try container.decodeIfPresent(SpaceAccountLink.self, forKey: .accountLink)
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
        try container.encodeIfPresent(accountLink, forKey: .accountLink)
    }

    var arguments: [String] {
        LaunchArgumentParser.parse(argumentsText).words
    }

    var environment: [String: String] {
        LaunchEnvironmentParser.parse(environmentText).effectiveValues
    }

    mutating func markLaunchConfigurationImported() {
        accountLink?.desktopConfirmation = nil
        accountLink?.trackingAccountID = nil
        launchConfigurationTrust = .importedPendingReview
    }

    mutating func approveImportedLaunch(
        using approval: ImportedLaunchApproval
    ) {
        guard launchConfigurationTrust.isImported else { return }
        launchConfigurationTrust = .importedApproved(approval)
    }

    func preservingIdentity(of persisted: LaunchProfile) -> LaunchProfile {
        let launchConfigurationUnchanged =
            argumentsText == persisted.argumentsText
            && environmentText == persisted.environmentText
            && isolationOwnership == persisted.isolationOwnership
            && childEnvironmentPolicy == persisted.childEnvironmentPolicy
            && sensitiveEnvironmentKeys == persisted.sensitiveEnvironmentKeys
        let preservedTrust: LaunchConfigurationTrust
        if !launchConfigurationUnchanged {
            preservedTrust = persisted.launchConfigurationTrust
                .invalidatingImportedApproval()
        } else if persisted.launchConfigurationTrust.isImported,
                  launchConfigurationTrust.isImported
        {
            // Imported trust may move between pending and an approval issued by
            // ImportedLaunchTrust. It may never be downgraded to local through
            // an ordinary editable profile value.
            preservedTrust = launchConfigurationTrust
        } else {
            preservedTrust = persisted.launchConfigurationTrust
        }
        return LaunchProfile(
            id: persisted.id,
            storageID: persisted.storageID,
            name: name,
            argumentsText: argumentsText,
            environmentText: environmentText,
            notes: notes,
            isolationOwnership: isolationOwnership,
            childEnvironmentPolicy: childEnvironmentPolicy,
            sensitiveEnvironmentKeys: sensitiveEnvironmentKeys,
            launchConfigurationTrust: preservedTrust,
            lastLaunchedAt: lastLaunchedAt,
            accountLink: accountLink
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
            launchConfigurationTrust:
                launchConfigurationTrust.invalidatingImportedApproval(),
            lastLaunchedAt: nil,
            accountLink: accountLink.map { SpaceAccountLink(expectedEmail: $0.expectedEmail, trackingAccountID: $0.trackingAccountID) }
        )
    }

    private mutating func invalidateImportedApproval() {
        launchConfigurationTrust =
            launchConfigurationTrust.invalidatingImportedApproval()
    }
}
