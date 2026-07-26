import Foundation

struct ApplicationHealthInput: Equatable, Sendable {
    let applicationID: UUID
    let applicationURL: URL
    let expectedBundleIdentifier: String?
}

enum ProfileHealthPathRole: String, Equatable, Hashable, Sendable {
    case managedProfileRoot
    case managedUserData
    case managedCodexHome
    case externalUserData
    case externalCodexHome
}

enum ProfileHealthPathSource: Equatable, Sendable {
    case managedUserData
    case managedCodexHome
    case external(String)
}

struct ProfileIsolationHealthInput: Equatable, Sendable {
    let role: ProfileHealthPathRole
    let source: ProfileHealthPathSource
}

struct ProfileHealthInput: Equatable, Sendable {
    let applicationID: UUID
    var profileID: UUID
    let applicationStorageID: UUID
    var profileStorageID: UUID
    let configuredBaseRoot: String
    var isolationPaths: [ProfileIsolationHealthInput]
}

enum LaunchHealthIssueCode: String, Equatable, Sendable {
    case applicationPathNotAbsolute
    case applicationNotAppBundle
    case applicationMissing
    case applicationNotDirectory
    case applicationCanonicalizationFailed
    case missingInfoPlist
    case invalidInfoPlist
    case missingBundleIdentifier
    case bundleIdentifierMismatch
    case missingExecutableName
    case invalidExecutableName
    case executableMissing
    case executableNotRegularFile
    case executableNotRunnable
    case managedPathInvalid
    case externalPathInvalid
    case targetNotDirectory
    case noWritableAncestor
    case targetNotWritable
    case profileActive
    case canonicalPathCollision
    case fileIdentityCollision
}

struct LaunchHealthIssue: Equatable, Sendable {
    let code: LaunchHealthIssueCode
    let path: String?
    let relatedProfileIDs: Set<UUID>

    init(
        _ code: LaunchHealthIssueCode,
        path: String? = nil,
        relatedProfileIDs: Set<UUID> = []
    ) {
        self.code = code
        self.path = path
        self.relatedProfileIDs = relatedProfileIDs
    }
}

struct ApplicationHealthReport: Equatable, Sendable {
    let applicationID: UUID
    let requestedApplicationURL: URL
    let canonicalApplicationURL: URL?
    let bundleIdentifier: String?
    let executableURL: URL?
    let issues: [LaunchHealthIssue]

    var isHealthy: Bool {
        issues.isEmpty
    }
}

enum ProfileHealthPathState: String, Equatable, Sendable {
    case existingDirectory
    case missingCreatable
    case missingUnwritable
    case invalid
}

struct ProfileHealthPathReport: Equatable, Sendable {
    let role: ProfileHealthPathRole
    let requestedURL: URL
    let canonicalURL: URL?
    let state: ProfileHealthPathState
    let identity: FileSystemObjectIdentity?
    let writableURL: URL?
}

struct ProfileHealthReport: Equatable, Sendable {
    let applicationID: UUID
    let profileID: UUID
    let applicationStorageID: UUID
    let profileStorageID: UUID
    let isActive: Bool
    var paths: [ProfileHealthPathReport]
    var issues: [LaunchHealthIssue]

    var isHealthy: Bool {
        issues.isEmpty
    }
}

protocol ProfileHealthActivityProviding: Sendable {
    func isStorageActive(
        applicationStorageID: UUID,
        profileStorageID: UUID
    ) -> Bool
}

struct NoProfileHealthActivityProvider: ProfileHealthActivityProviding {
    func isStorageActive(
        applicationStorageID: UUID,
        profileStorageID: UUID
    ) -> Bool {
        false
    }
}

extension ProfileActivityRegistry: ProfileHealthActivityProviding {}
