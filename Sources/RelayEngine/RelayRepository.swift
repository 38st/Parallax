import CryptoKit
import Darwin
import Foundation
import RelayCore

public enum RelayRepositoryCustodyError: Error, Equatable, Sendable {
    case invalidSelection(String)
    case repositoryUnavailable
    case repositoryBare
    case repositoryNotClean
    case repositoryOperationInProgress(String)
    case repositoryFilterExecutionConfigured
    case repositoryChangedDuringInspection
    case invalidGitOutput
    case unexpectedGitDiagnostic
    case invalidObjectID
    case unsafePath(String)
    case wrongFileType(String)
    case git(RelayGitCommandError)
}

public struct RelayRepositoryAdmission: Equatable, Sendable {
    public let repositoryRootURL: URL
    public let gitDirectoryURL: URL
    public let gitCommonDirectoryURL: URL
    public let repositoryFileIdentity: RelayFileIdentity
    public let gitCommonDirectoryFileIdentity: RelayFileIdentity
    public let baselineCommit: RelayGitOID

    public init(
        repositoryRootURL: URL,
        gitDirectoryURL: URL,
        gitCommonDirectoryURL: URL,
        repositoryFileIdentity: RelayFileIdentity,
        gitCommonDirectoryFileIdentity: RelayFileIdentity,
        baselineCommit: RelayGitOID
    ) {
        self.repositoryRootURL = repositoryRootURL
        self.gitDirectoryURL = gitDirectoryURL
        self.gitCommonDirectoryURL = gitCommonDirectoryURL
        self.repositoryFileIdentity = repositoryFileIdentity
        self.gitCommonDirectoryFileIdentity = gitCommonDirectoryFileIdentity
        self.baselineCommit = baselineCommit
    }
}

public struct RelayRepositoryPreflightPolicy: Equatable, Sendable {
    public let maximumPathBytes: Int
    public let maximumStatusBytes: Int

    public init(
        maximumPathBytes: Int = 16 * 1_024,
        maximumStatusBytes: Int = 4 * 1_024 * 1_024
    ) {
        self.maximumPathBytes = maximumPathBytes
        self.maximumStatusBytes = maximumStatusBytes
    }
}

public struct RelayRepositoryCustodian: Sendable {
    private let git: any RelayGitCommandRunning
    private let policy: RelayRepositoryPreflightPolicy

    public init(
        policy: RelayRepositoryPreflightPolicy = .init()
    ) {
        git = RelaySystemGitRunner()
        self.policy = policy
    }

    init(
        git: any RelayGitCommandRunning,
        policy: RelayRepositoryPreflightPolicy = .init()
    ) {
        self.git = git
        self.policy = policy
    }

    public func preflight(
        repositoryURL selection: URL
    ) throws -> RelayRepositoryAdmission {
        guard
            policy.maximumPathBytes > 0,
            policy.maximumStatusBytes >= 0,
            selection.isFileURL,
            selection.path.utf8.count <= policy.maximumPathBytes
        else {
            throw RelayRepositoryCustodyError.invalidSelection(selection.path)
        }
        let selected = try RelayRepositoryFileFacts.canonicalDirectory(
            selection
        )
        let root = try absoluteGitPath(
            arguments: ["rev-parse", "--show-toplevel"],
            workingDirectory: selected
        )
        let gitDirectory = try absoluteGitPath(
            arguments: [
                "rev-parse", "--path-format=absolute", "--git-dir",
            ],
            workingDirectory: root
        )
        let commonDirectory = try absoluteGitPath(
            arguments: [
                "rev-parse", "--path-format=absolute", "--git-common-dir",
            ],
            workingDirectory: root
        )

        guard try text(
            ["rev-parse", "--is-bare-repository"],
            at: root,
            limit: 16
        ) == "false" else {
            throw RelayRepositoryCustodyError.repositoryBare
        }

        let initialRepositoryIdentity = try RelayRepositoryFileFacts.identity(
            ofDirectory: root
        )
        let initialCommonIdentity = try RelayRepositoryFileFacts.identity(
            ofDirectory: commonDirectory
        )
        let initialHead = try head(at: root)
        let initialStatus = try status(at: root)
        guard initialStatus.isEmpty else {
            throw RelayRepositoryCustodyError.repositoryNotClean
        }
        try rejectInProgressOperations(at: root)
        try rejectConfiguredContentFilters(at: root)

        let finalStatus = try status(at: root)
        let finalHead = try head(at: root)
        let finalRepositoryIdentity = try RelayRepositoryFileFacts.identity(
            ofDirectory: root
        )
        let finalCommonIdentity = try RelayRepositoryFileFacts.identity(
            ofDirectory: commonDirectory
        )
        guard
            finalStatus == initialStatus,
            finalHead == initialHead,
            finalRepositoryIdentity == initialRepositoryIdentity,
            finalCommonIdentity == initialCommonIdentity
        else {
            throw RelayRepositoryCustodyError.repositoryChangedDuringInspection
        }

        return RelayRepositoryAdmission(
            repositoryRootURL: root,
            gitDirectoryURL: gitDirectory,
            gitCommonDirectoryURL: commonDirectory,
            repositoryFileIdentity: initialRepositoryIdentity,
            gitCommonDirectoryFileIdentity: initialCommonIdentity,
            baselineCommit: initialHead
        )
    }

    private func status(at root: URL) throws -> Data {
        try output(
            [
                "status", "--porcelain=v2", "-z", "--untracked-files=all",
            ],
            at: root,
            limit: policy.maximumStatusBytes
        )
    }

    private func head(at root: URL) throws -> RelayGitOID {
        let value = try text(
            ["rev-parse", "--verify", "HEAD^{commit}"],
            at: root,
            limit: 128
        )
        guard let identifier = RelayGitOID(rawValue: value) else {
            throw RelayRepositoryCustodyError.invalidObjectID
        }
        return identifier
    }

    private func rejectInProgressOperations(at root: URL) throws {
        let markers = [
            "MERGE_HEAD",
            "CHERRY_PICK_HEAD",
            "REVERT_HEAD",
            "rebase-merge",
            "rebase-apply",
            "sequencer",
        ]
        for marker in markers {
            let path = try text(
                ["rev-parse", "--git-path", marker],
                at: root,
                limit: policy.maximumPathBytes
            )
            let url = URL(
                fileURLWithPath: path,
                relativeTo: root
            ).standardizedFileURL
            var facts = stat()
            if lstat(url.path, &facts) == 0 {
                throw RelayRepositoryCustodyError
                    .repositoryOperationInProgress(marker)
            }
            guard errno == ENOENT else {
                throw RelayRepositoryCustodyError.repositoryUnavailable
            }
        }
    }

    private func rejectConfiguredContentFilters(at root: URL) throws {
        let result: RelayGitCommandResult
        do {
            result = try git.run(
                arguments: [
                    "config", "--local", "--null", "--get-regexp",
                    #"^filter\..*\.(clean|smudge|process|required)$"#,
                ],
                workingDirectory: root,
                standardOutputLimit: 1_024 * 1_024,
                acceptedExitStatuses: [0, 1]
            )
        } catch let error as RelayGitCommandError {
            throw RelayRepositoryCustodyError.git(error)
        }
        guard result.standardError.isEmpty else {
            throw RelayRepositoryCustodyError.unexpectedGitDiagnostic
        }
        guard result.standardOutput.isEmpty else {
            throw RelayRepositoryCustodyError
                .repositoryFilterExecutionConfigured
        }
    }

    private func absoluteGitPath(
        arguments: [String],
        workingDirectory: URL
    ) throws -> URL {
        let value = try text(
            arguments,
            at: workingDirectory,
            limit: policy.maximumPathBytes
        )
        let candidate = URL(
            fileURLWithPath: value,
            relativeTo: workingDirectory
        )
        return try RelayRepositoryFileFacts.canonicalDirectory(candidate)
    }

    private func text(
        _ arguments: [String],
        at root: URL,
        limit: Int
    ) throws -> String {
        let bytes = try output(arguments, at: root, limit: limit)
        guard
            !bytes.contains(0),
            let value = String(data: bytes, encoding: .utf8)
        else {
            throw RelayRepositoryCustodyError.invalidGitOutput
        }
        let result = value.trimmingCharacters(in: .newlines)
        guard !result.isEmpty else {
            throw RelayRepositoryCustodyError.invalidGitOutput
        }
        return result
    }

    private func output(
        _ arguments: [String],
        at root: URL,
        limit: Int
    ) throws -> Data {
        do {
            let result = try git.run(
                arguments: arguments,
                workingDirectory: root,
                standardOutputLimit: limit
            )
            guard result.standardError.isEmpty else {
                throw RelayRepositoryCustodyError.unexpectedGitDiagnostic
            }
            return result.standardOutput
        } catch let error as RelayRepositoryCustodyError {
            throw error
        } catch let error as RelayGitCommandError {
            throw RelayRepositoryCustodyError.git(error)
        }
    }
}

enum RelayRepositoryFileFacts {
    static func canonicalDirectory(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else {
            throw RelayRepositoryCustodyError.unsafePath(url.path)
        }
        guard let resolved = realpath(url.path, nil) else {
            throw RelayRepositoryCustodyError.repositoryUnavailable
        }
        defer { free(resolved) }
        let canonical = URL(fileURLWithPath: String(cString: resolved))
        _ = try identity(ofDirectory: canonical)
        return canonical
    }

    static func identity(ofDirectory url: URL) throws -> RelayFileIdentity {
        var facts = stat()
        guard lstat(url.path, &facts) == 0 else {
            throw RelayRepositoryCustodyError.repositoryUnavailable
        }
        guard facts.st_mode & S_IFMT == S_IFDIR else {
            throw RelayRepositoryCustodyError.wrongFileType(url.path)
        }
        return RelayFileIdentity(
            deviceID: UInt64(facts.st_dev),
            fileID: UInt64(facts.st_ino)
        )
    }

    static func sha256(_ data: Data) -> RelayDigest {
        let encoded = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        return RelayDigest(rawValue: encoded)!
    }
}
