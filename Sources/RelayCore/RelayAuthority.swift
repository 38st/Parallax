import Foundation

public enum RelayFileSystemAuthority: String, Codable, CaseIterable, Sendable {
    case readOnly
    case workspaceWrite
}

public enum RelayExecutionAuthority: String, Codable, CaseIterable, Sendable {
    case none
    case diagnostic
    case test
}

public enum RelayNetworkAuthority: String, Codable, CaseIterable, Sendable {
    case none
    case webSearch
}

public enum RelayGitAuthority: String, Codable, CaseIterable, Sendable {
    case none
    case read
    case checkpoint
}

public enum RelayExternalWriteAuthority: String, Codable, CaseIterable,
    Sendable
{
    case none
    case draftPullRequest
}

public enum RelayCredentialAuthority: String, Codable, CaseIterable, Sendable {
    case none
    case selectedCodexHome
    case githubDelivery
}

public struct RelayAuthority: Hashable, Codable, Sendable {
    public let fileSystem: RelayFileSystemAuthority
    public let execution: RelayExecutionAuthority
    public let network: RelayNetworkAuthority
    public let git: RelayGitAuthority
    public let externalWrites: RelayExternalWriteAuthority
    public let credentials: RelayCredentialAuthority

    public init(
        fileSystem: RelayFileSystemAuthority,
        execution: RelayExecutionAuthority,
        network: RelayNetworkAuthority = .none,
        git: RelayGitAuthority,
        externalWrites: RelayExternalWriteAuthority = .none,
        credentials: RelayCredentialAuthority = .none
    ) {
        self.fileSystem = fileSystem
        self.execution = execution
        self.network = network
        self.git = git
        self.externalWrites = externalWrites
        self.credentials = credentials
    }

    public static let scout = RelayAuthority(
        fileSystem: .readOnly,
        execution: .diagnostic,
        git: .read
    )

    public static let implementer = RelayAuthority(
        fileSystem: .workspaceWrite,
        execution: .test,
        git: .read
    )

    public static let verifier = RelayAuthority(
        fileSystem: .workspaceWrite,
        execution: .test,
        git: .read
    )

    public static let reviewer = RelayAuthority(
        fileSystem: .readOnly,
        execution: .diagnostic,
        git: .read
    )
}
