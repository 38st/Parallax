import Foundation

struct ManagedPathError: LocalizedError, Equatable {
    enum Code: String, Sendable {
        case emptyBaseRoot
        case relativeBaseRoot
        case nonFileBaseRoot
        case dotPathComponent
        case dotDotPathComponent
        case invalidBaseRoot
        case baseRootNotDirectory
        case ancestorNotDirectory
        case targetNotDirectory
        case baseRootUnavailable
        case outsideManagedRoot
        case rootIdentityChanged
        case invalidStorageComponent
        case reservedStorageComponent
        case invalidExternalPath
        case externalPathNotDirectory
    }

    let code: Code
    let path: String?

    init(_ code: Code, path: String? = nil) {
        self.code = code
        self.path = path
    }

    var errorDescription: String? {
        switch code {
        case .emptyBaseRoot:
            String(localized: "Choose an absolute folder for managed profile storage.")
        case .relativeBaseRoot:
            String(localized: "The managed profile storage folder must be an absolute path.")
        case .nonFileBaseRoot:
            String(localized: "The managed profile storage location must be a local or mounted file URL.")
        case .dotPathComponent:
            String(localized: "The managed profile storage path cannot contain a “.” component.")
        case .dotDotPathComponent:
            String(localized: "The managed profile storage path cannot contain a “..” component.")
        case .invalidBaseRoot:
            String(localized: "The managed profile storage path is invalid.")
        case .baseRootNotDirectory:
            String(localized: "The configured managed profile storage path is a file, not a folder.")
        case .ancestorNotDirectory:
            String(localized: "A parent of the managed profile storage path is a file, not a folder.")
        case .targetNotDirectory:
            String(localized: "The managed profile data target is a file, not a folder.")
        case .baseRootUnavailable:
            String(localized: "The managed profile storage volume is unavailable. Reconnect it before continuing.")
        case .outsideManagedRoot:
            String(localized: "The managed profile path resolves outside its approved storage folder.")
        case .rootIdentityChanged:
            String(localized: "The managed profile storage folder changed after it was inspected. Try the operation again.")
        case .invalidStorageComponent:
            String(localized: "The storage identifier is invalid.")
        case .reservedStorageComponent:
            String(localized: "The storage identifier uses a reserved Parallax directory name.")
        case .invalidExternalPath:
            String(localized: "The external isolation folder must be an absolute file path.")
        case .externalPathNotDirectory:
            String(localized: "The external isolation path is a file, not a folder.")
        }
    }
}

struct ManagedStorageComponent: Sendable, Hashable {
    static let reservedNamespaceNames = [
        ".parallax",
        "Applications",
        "Profiles",
        "Archives",
        "UserData",
        "CodexHome",
        "Transactions",
    ]

    let rawValue: String

    init(validating rawValue: String) throws {
        let normalized = rawValue
            .precomposedStringWithCompatibilityMapping
            .lowercased()
        let reserved = Set(
            Self.reservedNamespaceNames.map {
                $0.precomposedStringWithCompatibilityMapping.lowercased()
            }
        )
        if reserved.contains(normalized) {
            throw ManagedPathError(.reservedStorageComponent, path: rawValue)
        }

        guard
            rawValue.count == 36,
            rawValue == rawValue.lowercased(),
            let uuid = UUID(uuidString: rawValue),
            uuid.uuidString.lowercased() == rawValue
        else {
            throw ManagedPathError(.invalidStorageComponent, path: rawValue)
        }
        self.rawValue = rawValue
    }

    init(uuid: UUID) {
        rawValue = uuid.uuidString.lowercased()
    }
}

struct ManagedPathValidationContext: Sendable, Equatable {
    let configuredBaseRootURL: URL
    let canonicalBaseRootURL: URL
    let identityAnchorURL: URL
    let identityAnchor: FileSystemObjectIdentity
}

protocol ManagedMutationPath: Sendable {
    var url: URL { get }
    var validationContext: ManagedPathValidationContext { get }
}

struct ManagedProfileRootPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ManagedApplicationRootPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ManagedApplicationArchiveRootPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ManagedUserDataPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ManagedCodexHomePath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ManagedClaudeConfigPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ManagedArchiveRootPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext

    func entry(
        timestamp: Date = Date(),
        nonce: UUID = UUID()
    ) -> ManagedArchiveEntryPath {
        let milliseconds = Int64((timestamp.timeIntervalSince1970 * 1_000).rounded())
        let name = "\(milliseconds)-\(nonce.uuidString.lowercased())"
        return ManagedArchiveEntryPath(
            url: url.appendingPathComponent(name, isDirectory: true),
            validationContext: validationContext
        )
    }
}

struct ManagedArchiveEntryPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ManagedStagingRootPath: ManagedMutationPath, Equatable {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

struct ExternalIsolationPath: Sendable, Equatable {
    /// The configured path retained for launch behavior and presentation.
    let requestedURL: URL
    /// The resolved path used for identity, collision, and trust evidence.
    let canonicalURL: URL

    /// Compatibility behavior: callers asking for `url` receive the requested
    /// path, not the canonical path. A future integration should replace this
    /// ambiguous convenience with an explicit requested/canonical choice.
    var url: URL { requestedURL }
}

struct ResolvedProfilePaths: Sendable, Equatable {
    let profileRoot: ManagedProfileRootPath
    let userData: ManagedUserDataPath
    let codexHome: ManagedCodexHomePath
    let claudeConfig: ManagedClaudeConfigPath
    let archiveRoot: ManagedArchiveRootPath

    private let namespaceRoot: URL
    private let validationContext: ManagedPathValidationContext

    init(
        profileRoot: ManagedProfileRootPath,
        userData: ManagedUserDataPath,
        codexHome: ManagedCodexHomePath,
        claudeConfig: ManagedClaudeConfigPath,
        archiveRoot: ManagedArchiveRootPath,
        namespaceRoot: URL,
        validationContext: ManagedPathValidationContext
    ) {
        self.profileRoot = profileRoot
        self.userData = userData
        self.codexHome = codexHome
        self.claudeConfig = claudeConfig
        self.archiveRoot = archiveRoot
        self.namespaceRoot = namespaceRoot
        self.validationContext = validationContext
    }

    func stagingRoot(transactionID: UUID) throws -> ManagedStagingRootPath {
        let component = ManagedStorageComponent(uuid: transactionID)
        return ManagedStagingRootPath(
            url: namespaceRoot
                .appendingPathComponent("Transactions", isDirectory: true)
                .appendingPathComponent(component.rawValue, isDirectory: true),
            validationContext: validationContext
        )
    }

    func archiveEntry(
        timestamp: Date = Date(),
        nonce: UUID = UUID()
    ) -> ManagedArchiveEntryPath {
        archiveRoot.entry(timestamp: timestamp, nonce: nonce)
    }
}

struct ResolvedApplicationStoragePaths: Sendable, Equatable {
    let applicationRoot: ManagedApplicationRootPath
    let applicationArchiveRoot: ManagedApplicationArchiveRootPath
    let canonicalBaseRootURL: URL

    private let namespaceRoot: URL
    private let validationContext: ManagedPathValidationContext

    init(
        applicationRoot: ManagedApplicationRootPath,
        applicationArchiveRoot: ManagedApplicationArchiveRootPath,
        canonicalBaseRootURL: URL,
        namespaceRoot: URL,
        validationContext: ManagedPathValidationContext
    ) {
        self.applicationRoot = applicationRoot
        self.applicationArchiveRoot = applicationArchiveRoot
        self.canonicalBaseRootURL = canonicalBaseRootURL
        self.namespaceRoot = namespaceRoot
        self.validationContext = validationContext
    }

    func stagingRoot(transactionID: UUID) -> ManagedStagingRootPath {
        ManagedStagingRootPath(
            url: namespaceRoot
                .appendingPathComponent("Transactions", isDirectory: true)
                .appendingPathComponent(
                    transactionID.uuidString.lowercased(),
                    isDirectory: true
                ),
            validationContext: validationContext
        )
    }
}
