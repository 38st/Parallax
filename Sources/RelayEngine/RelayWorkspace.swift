import CryptoKit
import Darwin
import Foundation
import RelayCore

public enum RelayWorkspaceCustodyFailure: Error, Equatable, Sendable {
    case invalidManagedRoot
    case unsafeManagedRoot
    case workspaceAlreadyExists
    case provisioningIntentInvalid
    case provisioningOutcomeAmbiguous
    case repositoryAdmissionChanged
    case workspaceProvisioningFailed(RelayGitCommandError)
    case workspaceVerificationFailed
    case workspacePathChanged(expected: String, actual: String)
    case workspaceIdentityChanged
    case workspaceChangedDuringSnapshot
    case workspaceStatusInvalid
    case pathInvalid(String)
    case untrackedFileCountExceeded(Int)
    case untrackedFileTooLarge(String)
    case untrackedContentLimitExceeded
    case patchLimitExceeded
    case untrackedFileUnsupported(String)
    case fileChangedDuringRead(String)
    case fileReadFailed(String)
    case patchUnavailable(String)
    case exportDestinationExists
    case exportFailed
    case git(RelayGitCommandError)
}

public struct RelayWorkspaceCustody: Equatable, Sendable {
    public let identity: RelayWorkspaceIdentity
    public let sourceRepository: RelayRepositoryAdmission
    public let workspaceURL: URL
    public let workspaceFileIdentity: RelayFileIdentity

    public init(
        identity: RelayWorkspaceIdentity,
        sourceRepository: RelayRepositoryAdmission,
        workspaceURL: URL,
        workspaceFileIdentity: RelayFileIdentity
    ) {
        self.identity = identity
        self.sourceRepository = sourceRepository
        self.workspaceURL = workspaceURL
        self.workspaceFileIdentity = workspaceFileIdentity
    }
}

public enum RelayWorkspaceProvisioningReconciliation: Equatable, Sendable {
    case notProvisioned(RelayWorkspaceProvisioningIntent)
    case prepared(RelayWorkspaceCustody)
}

public enum RelayWorkspacePreservationReason: String, Sendable, Equatable,
    Codable
{
    case active
    case interrupted
    case verificationFailed
    case containsUncommittedWork
    case awaitingUserDecision
    case completed
}

public struct RelayWorkspacePreservation: Sendable, Equatable {
    public let workspace: RelayWorkspaceCustody
    public let reason: RelayWorkspacePreservationReason
    public let preservedAt: RelayInstant

    public init(
        workspace: RelayWorkspaceCustody,
        reason: RelayWorkspacePreservationReason,
        preservedAt: RelayInstant
    ) {
        self.workspace = workspace
        self.reason = reason
        self.preservedAt = preservedAt
    }
}

public struct RelayWorkspaceCustodian: Sendable {
    private let managedRootURL: URL
    private let git: any RelayGitCommandRunning
    private let repositoryCustodian: RelayRepositoryCustodian
    private let now: @Sendable () -> Date

    public init(
        managedRootURL: URL,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.managedRootURL = managedRootURL
        let runner = RelaySystemGitRunner()
        git = runner
        repositoryCustodian = RelayRepositoryCustodian()
        self.now = now
    }

    init(
        managedRootURL: URL,
        git: any RelayGitCommandRunning,
        repositoryCustodian: RelayRepositoryCustodian,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.managedRootURL = managedRootURL
        self.git = git
        self.repositoryCustodian = repositoryCustodian
        self.now = now
    }

    public func makeProvisioningIntent(
        taskID: RelayTaskID,
        repository admission: RelayRepositoryAdmission,
        requestedAt: RelayInstant
    ) throws -> RelayWorkspaceProvisioningIntent {
        let managedRoot = try prepareManagedRoot()
        let workspaceURL = managedRoot.appendingPathComponent(
            taskID.description,
            isDirectory: true
        )
        var existing = stat()
        if lstat(workspaceURL.path, &existing) == 0 {
            throw RelayWorkspaceCustodyFailure.workspaceAlreadyExists
        }
        guard errno == ENOENT else {
            throw RelayWorkspaceCustodyFailure.unsafeManagedRoot
        }

        let refreshed = try repositoryCustodian.preflight(
            repositoryURL: admission.repositoryRootURL
        )
        guard refreshed == admission else {
            throw RelayWorkspaceCustodyFailure.repositoryAdmissionChanged
        }

        return RelayWorkspaceProvisioningIntent(
            id: RelayWorkspaceProvisioningIntentID(),
            taskID: taskID,
            sourceRepositoryRootPath: Self.durablePath(
                admission.repositoryRootURL
            ),
            sourceRepositoryFileIdentity:
                admission.repositoryFileIdentity,
            sourceGitDirectoryPath: Self.durablePath(
                admission.gitDirectoryURL
            ),
            sourceGitCommonDirectoryPath:
                Self.durablePath(admission.gitCommonDirectoryURL),
            sourceGitCommonDirectoryFileIdentity:
                admission.gitCommonDirectoryFileIdentity,
            baselineCommit: admission.baselineCommit,
            managedRootPath: Self.durablePath(managedRoot),
            managedRootFileIdentity: try RelayRepositoryFileFacts.identity(
                ofDirectory: managedRoot
            ),
            targetWorkspacePath: Self.durableChildPath(
                parent: Self.durablePath(managedRoot),
                component: taskID.description
            ),
            expectedTaskReference: "detached/\(taskID.description)",
            expectedInitialWorkspaceDigest: Self.initialWorkspaceDigest(
                for: admission.baselineCommit
            ),
            requestedAt: requestedAt
        )
    }

    public func provision(
        intent: RelayWorkspaceProvisioningIntent,
        repository admission: RelayRepositoryAdmission
    ) throws -> RelayWorkspaceCustody {
        let request = try validate(intent: intent, repository: admission)
        var existing = stat()
        if lstat(request.workspaceURL.path, &existing) == 0 {
            throw RelayWorkspaceCustodyFailure.workspaceAlreadyExists
        }
        guard errno == ENOENT else {
            throw RelayWorkspaceCustodyFailure.provisioningOutcomeAmbiguous
        }

        do {
            let result = try git.run(
                arguments: [
                    "worktree", "add", "--detach", request.workspaceURL.path,
                    admission.baselineCommit.rawValue,
                ],
                workingDirectory: admission.repositoryRootURL,
                standardOutputLimit: 1_024 * 1_024,
                standardErrorLimit: 1_024 * 1_024,
                timeout: 120,
                acceptedExitStatuses: [0]
            )
            guard result.standardOutput.count + result.standardError.count
                    <= 2 * 1_024 * 1_024
            else {
                throw RelayWorkspaceCustodyFailure
                    .workspaceVerificationFailed
            }
        } catch let error as RelayWorkspaceCustodyFailure {
            throw error
        } catch let error as RelayGitCommandError {
            throw RelayWorkspaceCustodyFailure
                .workspaceProvisioningFailed(error)
        }

        return try verifyPreparedWorkspace(
            at: request.workspaceURL,
            intent: intent,
            repository: admission
        )
    }

    /// Inspects a durable request after an unknown provisioning outcome.
    /// This never creates, removes, repairs, or unregisters a worktree.
    public func reconcile(
        intent: RelayWorkspaceProvisioningIntent
    ) throws -> RelayWorkspaceProvisioningReconciliation {
        guard intent.sourceRepositoryRootPath.hasPrefix("/") else {
            throw RelayWorkspaceCustodyFailure.provisioningIntentInvalid
        }
        let admission = try repositoryCustodian.preflight(
            repositoryURL: URL(
                fileURLWithPath: intent.sourceRepositoryRootPath,
                isDirectory: true
            )
        )
        let request = try validate(intent: intent, repository: admission)
        var existing = stat()
        if lstat(request.workspaceURL.path, &existing) == -1 {
            guard errno == ENOENT else {
                throw RelayWorkspaceCustodyFailure
                    .provisioningOutcomeAmbiguous
            }
            return .notProvisioned(intent)
        }
        guard existing.st_mode & S_IFMT == S_IFDIR else {
            throw RelayWorkspaceCustodyFailure.provisioningOutcomeAmbiguous
        }
        do {
            return .prepared(
                try verifyPreparedWorkspace(
                    at: request.workspaceURL,
                    intent: intent,
                    repository: admission
                )
            )
        } catch {
            // An existing but non-exact target is never repaired or removed.
            throw RelayWorkspaceCustodyFailure.provisioningOutcomeAmbiguous
        }
    }

    private func validate(
        intent: RelayWorkspaceProvisioningIntent,
        repository admission: RelayRepositoryAdmission
    ) throws -> (managedRoot: URL, workspaceURL: URL) {
        let managedRoot = try inspectManagedRoot()
        let workspaceURL = URL(
            fileURLWithPath: intent.targetWorkspacePath,
            isDirectory: true
        )
        let refreshed = try repositoryCustodian.preflight(
            repositoryURL: admission.repositoryRootURL
        )
        guard
            refreshed == admission,
            intent.sourceRepositoryRootPath
                == Self.durablePath(admission.repositoryRootURL),
            intent.sourceRepositoryFileIdentity
                == admission.repositoryFileIdentity,
            intent.sourceGitDirectoryPath
                == Self.durablePath(admission.gitDirectoryURL),
            intent.sourceGitCommonDirectoryPath
                == Self.durablePath(admission.gitCommonDirectoryURL),
            intent.sourceGitCommonDirectoryFileIdentity
                == admission.gitCommonDirectoryFileIdentity,
            intent.baselineCommit == admission.baselineCommit,
            intent.managedRootPath == Self.durablePath(managedRoot),
            intent.managedRootFileIdentity
                == (try RelayRepositoryFileFacts.identity(
                    ofDirectory: managedRoot
                )),
            intent.targetWorkspacePath == workspaceURL.path,
            intent.targetWorkspacePath
                == Self.durableChildPath(
                    parent: intent.managedRootPath,
                    component: intent.taskID.description
                ),
            intent.expectedTaskReference
                == "detached/\(intent.taskID.description)",
            intent.expectedInitialWorkspaceDigest
                == Self.initialWorkspaceDigest(
                    for: admission.baselineCommit
                )
        else {
            throw RelayWorkspaceCustodyFailure.provisioningIntentInvalid
        }
        return (managedRoot, workspaceURL)
    }

    private func verifyPreparedWorkspace(
        at workspaceURL: URL,
        intent: RelayWorkspaceProvisioningIntent,
        repository admission: RelayRepositoryAdmission
    ) throws -> RelayWorkspaceCustody {

        var workspaceFacts = stat()
        guard
            lstat(workspaceURL.path, &workspaceFacts) == 0,
            workspaceFacts.st_mode & S_IFMT == S_IFDIR
        else {
            throw RelayWorkspaceCustodyFailure.workspaceVerificationFailed
        }
        let canonicalWorkspace: URL
        do {
            canonicalWorkspace = try RelayRepositoryFileFacts
                .canonicalDirectory(workspaceURL)
        } catch {
            throw RelayWorkspaceCustodyFailure.workspaceVerificationFailed
        }
        let resolvedManagedRoot = try RelayRepositoryFileFacts
            .canonicalDirectory(URL(
                fileURLWithPath: intent.managedRootPath,
                isDirectory: true
            ))
        guard canonicalWorkspace.lastPathComponent == intent.taskID.description,
              canonicalWorkspace.deletingLastPathComponent().path
                == resolvedManagedRoot.path,
              Self.durablePath(canonicalWorkspace)
                == intent.targetWorkspacePath,
              try RelayRepositoryFileFacts.identity(
                ofDirectory: resolvedManagedRoot
              ) == intent.managedRootFileIdentity
        else {
            throw RelayWorkspaceCustodyFailure.workspacePathChanged(
                expected: resolvedManagedRoot
                    .appendingPathComponent(intent.taskID.description).path,
                actual: canonicalWorkspace.path
            )
        }
        let workspaceAdmission = try repositoryCustodian.preflight(
            repositoryURL: canonicalWorkspace
        )
        guard
            workspaceAdmission.baselineCommit == admission.baselineCommit,
            workspaceAdmission.gitCommonDirectoryURL
                == admission.gitCommonDirectoryURL,
            workspaceAdmission.gitCommonDirectoryFileIdentity
                == admission.gitCommonDirectoryFileIdentity
        else {
            throw RelayWorkspaceCustodyFailure.workspaceVerificationFailed
        }

        let symbolicHead = try git.run(
            arguments: ["symbolic-ref", "-q", "HEAD"],
            workingDirectory: canonicalWorkspace,
            standardOutputLimit: 1_024,
            standardErrorLimit: 1_024,
            timeout: 10,
            acceptedExitStatuses: [1]
        )
        guard symbolicHead.standardOutput.isEmpty,
              symbolicHead.standardError.isEmpty
        else {
            throw RelayWorkspaceCustodyFailure.workspaceVerificationFailed
        }

        let sourceAfter = try repositoryCustodian.preflight(
            repositoryURL: admission.repositoryRootURL
        )
        guard sourceAfter == admission else {
            throw RelayWorkspaceCustodyFailure.repositoryAdmissionChanged
        }
        guard
            try RelayRepositoryFileFacts.identity(
                ofDirectory: resolvedManagedRoot
            ) == intent.managedRootFileIdentity,
            try RelayRepositoryFileFacts.identity(
                ofDirectory: canonicalWorkspace
            ) == workspaceAdmission.repositoryFileIdentity
        else {
            throw RelayWorkspaceCustodyFailure.workspaceVerificationFailed
        }

        let initialWorkspaceDigest = Self.initialWorkspaceDigest(
            for: admission.baselineCommit
        )
        guard initialWorkspaceDigest
                == intent.expectedInitialWorkspaceDigest
        else {
            throw RelayWorkspaceCustodyFailure.workspaceVerificationFailed
        }
        let identity = RelayWorkspaceIdentity(
            taskID: intent.taskID,
            repositoryRootPath: intent.targetWorkspacePath,
            gitCommonDirectoryPath:
                intent.sourceGitCommonDirectoryPath,
            repositoryFileIdentity:
                workspaceAdmission.repositoryFileIdentity,
            gitCommonDirectoryFileIdentity:
                admission.gitCommonDirectoryFileIdentity,
            baseCommit: admission.baselineCommit,
            headCommit: admission.baselineCommit,
            workspaceDigest: initialWorkspaceDigest,
            taskReference: intent.expectedTaskReference,
            isClean: true,
            preparedAt: RelayInstant(date: now())
        )
        return RelayWorkspaceCustody(
            identity: identity,
            sourceRepository: admission,
            workspaceURL: URL(
                fileURLWithPath: intent.targetWorkspacePath,
                isDirectory: true
            ),
            workspaceFileIdentity:
                workspaceAdmission.repositoryFileIdentity
        )
    }

    private static func initialWorkspaceDigest(
        for commit: RelayGitOID
    ) -> RelayDigest {
        RelayWorkspaceSnapshotDigest.compute(
            head: commit,
            status: Data(),
            trackedPatch: Data(),
            untracked: []
        )
    }

    private static func durablePath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private static func durableChildPath(
        parent: String,
        component: String
    ) -> String {
        URL(fileURLWithPath: parent)
            .appendingPathComponent(component, isDirectory: true)
            .standardizedFileURL.path
    }

    public func preserve(
        _ workspace: RelayWorkspaceCustody,
        reason: RelayWorkspacePreservationReason
    ) -> RelayWorkspacePreservation {
        RelayWorkspacePreservation(
            workspace: workspace,
            reason: reason,
            preservedAt: RelayInstant(date: now())
        )
    }

    /// Returns the exact managed URL for presentation to a platform reveal
    /// adapter. Custody deliberately exposes no remove/prune operation.
    public func revealURL(
        for workspace: RelayWorkspaceCustody
    ) throws -> URL {
        guard
            try RelayRepositoryFileFacts.identity(
                ofDirectory: workspace.workspaceURL
            ) == workspace.workspaceFileIdentity
        else {
            throw RelayWorkspaceCustodyFailure.workspaceIdentityChanged
        }
        return workspace.workspaceURL
    }

    private func prepareManagedRoot() throws -> URL {
        guard
            managedRootURL.isFileURL,
            managedRootURL.path.hasPrefix("/"),
            managedRootURL.lastPathComponent == "RelayWorkspaces"
        else {
            throw RelayWorkspaceCustodyFailure.invalidManagedRoot
        }
        var facts = stat()
        if lstat(managedRootURL.path, &facts) == -1 {
            guard errno == ENOENT else {
                throw RelayWorkspaceCustodyFailure.unsafeManagedRoot
            }
            do {
                try FileManager.default.createDirectory(
                    at: managedRootURL,
                    withIntermediateDirectories: true,
                    attributes: [
                        .posixPermissions: NSNumber(value: Int16(0o700))
                    ]
                )
            } catch {
                throw RelayWorkspaceCustodyFailure.unsafeManagedRoot
            }
        }
        return try inspectManagedRoot()
    }

    private func inspectManagedRoot() throws -> URL {
        guard
            managedRootURL.isFileURL,
            managedRootURL.path.hasPrefix("/"),
            managedRootURL.lastPathComponent == "RelayWorkspaces"
        else {
            throw RelayWorkspaceCustodyFailure.invalidManagedRoot
        }
        var facts = stat()
        guard
            lstat(managedRootURL.path, &facts) == 0,
            facts.st_mode & S_IFMT == S_IFDIR,
            facts.st_uid == getuid(),
            facts.st_mode & 0o077 == 0
        else {
            throw RelayWorkspaceCustodyFailure.unsafeManagedRoot
        }
        let canonical: URL
        do {
            canonical = try RelayRepositoryFileFacts
                .canonicalDirectory(managedRootURL)
        } catch {
            throw RelayWorkspaceCustodyFailure.unsafeManagedRoot
        }
        // The leaf was verified with lstat and is not a symlink. Canonical
        // system ancestors such as macOS /var -> /private/var are accepted;
        // every managed child is derived from this canonical URL.
        return canonical
    }
}

public enum RelayUntrackedFileKind: String, Codable, Equatable, Sendable {
    case regular
    case symbolicLink
}

public struct RelayUntrackedFileSnapshot: Equatable, Sendable {
    public let relativePath: String
    public let kind: RelayUntrackedFileKind
    public let byteCount: UInt64
    public let contentDigest: RelayDigest
    public let binaryPatch: Data

    public init(
        relativePath: String,
        kind: RelayUntrackedFileKind,
        byteCount: UInt64,
        contentDigest: RelayDigest,
        binaryPatch: Data
    ) {
        self.relativePath = relativePath
        self.kind = kind
        self.byteCount = byteCount
        self.contentDigest = contentDigest
        self.binaryPatch = binaryPatch
    }
}

public struct RelayWorkspaceSnapshot: Equatable, Sendable {
    public let workspaceIdentity: RelayWorkspaceIdentity
    public let headCommit: RelayGitOID
    public let porcelainStatus: Data
    public let trackedBinaryDiff: Data
    public let untrackedFiles: [RelayUntrackedFileSnapshot]
    public let exportableBinaryPatch: Data
    public let digest: RelayDigest
    public let capturedAt: RelayInstant

    public init(
        workspaceIdentity: RelayWorkspaceIdentity,
        headCommit: RelayGitOID,
        porcelainStatus: Data,
        trackedBinaryDiff: Data,
        untrackedFiles: [RelayUntrackedFileSnapshot],
        exportableBinaryPatch: Data,
        digest: RelayDigest,
        capturedAt: RelayInstant
    ) {
        self.workspaceIdentity = workspaceIdentity
        self.headCommit = headCommit
        self.porcelainStatus = porcelainStatus
        self.trackedBinaryDiff = trackedBinaryDiff
        self.untrackedFiles = untrackedFiles
        self.exportableBinaryPatch = exportableBinaryPatch
        self.digest = digest
        self.capturedAt = capturedAt
    }
}

public struct RelayWorkspaceSnapshotPolicy: Equatable, Sendable {
    public let maximumStatusBytes: Int
    public let maximumTrackedPatchBytes: Int
    public let maximumExportPatchBytes: Int
    public let maximumUntrackedFiles: Int
    public let maximumUntrackedFileBytes: Int
    public let maximumTotalUntrackedBytes: Int
    public let maximumPathBytes: Int

    public init(
        maximumStatusBytes: Int = 4 * 1_024 * 1_024,
        maximumTrackedPatchBytes: Int = 64 * 1_024 * 1_024,
        maximumExportPatchBytes: Int = 128 * 1_024 * 1_024,
        maximumUntrackedFiles: Int = 1_024,
        maximumUntrackedFileBytes: Int = 16 * 1_024 * 1_024,
        maximumTotalUntrackedBytes: Int = 64 * 1_024 * 1_024,
        maximumPathBytes: Int = 16 * 1_024
    ) {
        self.maximumStatusBytes = maximumStatusBytes
        self.maximumTrackedPatchBytes = maximumTrackedPatchBytes
        self.maximumExportPatchBytes = maximumExportPatchBytes
        self.maximumUntrackedFiles = maximumUntrackedFiles
        self.maximumUntrackedFileBytes = maximumUntrackedFileBytes
        self.maximumTotalUntrackedBytes = maximumTotalUntrackedBytes
        self.maximumPathBytes = maximumPathBytes
    }
}

public struct RelayWorkspaceSnapshotter: Sendable {
    private let git: any RelayGitCommandRunning
    private let policy: RelayWorkspaceSnapshotPolicy
    private let now: @Sendable () -> Date

    public init(
        policy: RelayWorkspaceSnapshotPolicy = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        git = RelaySystemGitRunner()
        self.policy = policy
        self.now = now
    }

    init(
        git: any RelayGitCommandRunning,
        policy: RelayWorkspaceSnapshotPolicy = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.git = git
        self.policy = policy
        self.now = now
    }

    public func capture(
        _ custody: RelayWorkspaceCustody
    ) throws -> RelayWorkspaceSnapshot {
        try verify(custody)
        let first = try material(custody)
        let second = try material(custody)
        try verify(custody)
        guard first == second else {
            throw RelayWorkspaceCustodyFailure
                .workspaceChangedDuringSnapshot
        }
        let digest = RelayWorkspaceSnapshotDigest.compute(
            head: first.head,
            status: first.status,
            trackedPatch: first.trackedPatch,
            untracked: first.untracked
        )
        return RelayWorkspaceSnapshot(
            workspaceIdentity: custody.identity,
            headCommit: first.head,
            porcelainStatus: first.status,
            trackedBinaryDiff: first.trackedPatch,
            untrackedFiles: first.untracked,
            exportableBinaryPatch: first.exportPatch,
            digest: digest,
            capturedAt: RelayInstant(date: now())
        )
    }

    private func verify(_ custody: RelayWorkspaceCustody) throws {
        guard
            try RelayRepositoryFileFacts.identity(
                ofDirectory: custody.workspaceURL
            ) == custody.workspaceFileIdentity,
            try RelayRepositoryFileFacts.identity(
                ofDirectory: custody.sourceRepository.gitCommonDirectoryURL
            ) == custody.sourceRepository.gitCommonDirectoryFileIdentity
        else {
            throw RelayWorkspaceCustodyFailure.workspaceIdentityChanged
        }
        let common = try text(
            ["rev-parse", "--path-format=absolute", "--git-common-dir"],
            at: custody.workspaceURL,
            limit: policy.maximumPathBytes
        )
        let canonicalCommon = try RelayRepositoryFileFacts
            .canonicalDirectory(URL(fileURLWithPath: common))
        guard try RelayRepositoryFileFacts.identity(
            ofDirectory: canonicalCommon
        ) == custody.sourceRepository.gitCommonDirectoryFileIdentity
        else {
            throw RelayWorkspaceCustodyFailure.workspaceIdentityChanged
        }
    }

    private func material(
        _ custody: RelayWorkspaceCustody
    ) throws -> RelayWorkspaceMaterial {
        let headText = try text(
            ["rev-parse", "--verify", "HEAD^{commit}"],
            at: custody.workspaceURL,
            limit: 128
        )
        guard let head = RelayGitOID(rawValue: headText) else {
            throw RelayWorkspaceCustodyFailure.workspaceVerificationFailed
        }
        let status = try output(
            [
                "status", "--porcelain=v2", "-z", "--untracked-files=all",
            ],
            at: custody.workspaceURL,
            limit: policy.maximumStatusBytes
        )
        let tracked = try output(
            [
                "diff", "--binary", "--no-ext-diff", "--no-textconv",
                "HEAD", "--",
            ],
            at: custody.workspaceURL,
            limit: policy.maximumTrackedPatchBytes
        )
        let paths = try untrackedPaths(status)
        guard paths.count <= policy.maximumUntrackedFiles else {
            throw RelayWorkspaceCustodyFailure
                .untrackedFileCountExceeded(paths.count)
        }
        var totalUntracked = 0
        var totalPatch = tracked.count
        var untracked: [RelayUntrackedFileSnapshot] = []
        for path in paths.sorted() {
            let content = try RelayWorkspaceFileReader.read(
                relativePath: path,
                beneath: custody.workspaceURL,
                maximumBytes: policy.maximumUntrackedFileBytes,
                maximumPathBytes: policy.maximumPathBytes
            )
            totalUntracked += content.data.count
            guard totalUntracked <= policy.maximumTotalUntrackedBytes else {
                throw RelayWorkspaceCustodyFailure
                    .untrackedContentLimitExceeded
            }
            let patch = try untrackedPatch(
                relativePath: path,
                content: content,
                at: custody.workspaceURL
            )
            guard !patch.isEmpty else {
                throw RelayWorkspaceCustodyFailure.patchUnavailable(path)
            }
            totalPatch += patch.count
            guard totalPatch <= policy.maximumExportPatchBytes else {
                throw RelayWorkspaceCustodyFailure.patchLimitExceeded
            }
            untracked.append(
                RelayUntrackedFileSnapshot(
                    relativePath: path,
                    kind: content.kind,
                    byteCount: UInt64(content.data.count),
                    contentDigest:
                        RelayRepositoryFileFacts.sha256(content.data),
                    binaryPatch: patch
                )
            )
        }
        var exportPatch = tracked
        for entry in untracked {
            if !exportPatch.isEmpty,
               exportPatch.last != 0x0A,
               entry.binaryPatch.first != 0x0A
            {
                exportPatch.append(0x0A)
            }
            exportPatch.append(entry.binaryPatch)
        }
        return RelayWorkspaceMaterial(
            head: head,
            status: status,
            trackedPatch: tracked,
            untracked: untracked,
            exportPatch: exportPatch
        )
    }

    private func untrackedPaths(_ status: Data) throws -> [String] {
        let records = status.split(separator: 0, omittingEmptySubsequences: true)
        var paths: [String] = []
        var skipRenameOrigin = false
        for record in records {
            if skipRenameOrigin {
                skipRenameOrigin = false
                continue
            }
            guard let string = String(data: Data(record), encoding: .utf8) else {
                throw RelayWorkspaceCustodyFailure.workspaceStatusInvalid
            }
            if string.hasPrefix("2 ") {
                skipRenameOrigin = true
            }
            guard string.hasPrefix("? ") else { continue }
            let path = String(string.dropFirst(2))
            guard !path.isEmpty else {
                throw RelayWorkspaceCustodyFailure.workspaceStatusInvalid
            }
            paths.append(path)
        }
        return paths
    }

    private func untrackedPatch(
        relativePath: String,
        content: RelayWorkspaceFileContent,
        at root: URL
    ) throws -> Data {
        do {
            let result = try git.run(
                arguments: [
                    "diff", "--no-index", "--binary", "--no-ext-diff",
                    "--no-textconv", "--", "/dev/null", relativePath,
                ],
                workingDirectory: root,
                standardOutputLimit: policy.maximumExportPatchBytes,
                standardErrorLimit: 64 * 1_024,
                acceptedExitStatuses: [0, 1]
            )
            guard result.standardError.isEmpty else {
                throw RelayWorkspaceCustodyFailure.patchUnavailable(
                    relativePath
                )
            }
            if !result.standardOutput.isEmpty {
                return result.standardOutput
            }
            guard content.kind == .regular, content.data.isEmpty else {
                throw RelayWorkspaceCustodyFailure.patchUnavailable(
                    relativePath
                )
            }
            return try emptyFilePatch(relativePath: relativePath, at: root)
        } catch let error as RelayWorkspaceCustodyFailure {
            throw error
        } catch let error as RelayGitCommandError {
            throw RelayWorkspaceCustodyFailure.git(error)
        }
    }

    private func emptyFilePatch(
        relativePath: String,
        at root: URL
    ) throws -> Data {
        let safe = CharacterSet(
            charactersIn:
                "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/"
        )
        guard relativePath.unicodeScalars.allSatisfy(safe.contains) else {
            throw RelayWorkspaceCustodyFailure.patchUnavailable(relativePath)
        }
        let emptyOID = try text(
            ["hash-object", "--no-filters", "/dev/null"],
            at: root,
            limit: 128
        )
        guard RelayGitOID(rawValue: emptyOID) != nil else {
            throw RelayWorkspaceCustodyFailure.patchUnavailable(relativePath)
        }
        return Data(
            "diff --git a/\(relativePath) b/\(relativePath)\nnew file mode 100644\nindex 0000000..\(emptyOID)\n"
                .utf8
        )
    }

    private func text(
        _ arguments: [String],
        at root: URL,
        limit: Int
    ) throws -> String {
        let bytes = try output(arguments, at: root, limit: limit)
        guard
            !bytes.contains(0),
            let text = String(data: bytes, encoding: .utf8)
        else {
            throw RelayWorkspaceCustodyFailure.workspaceVerificationFailed
        }
        return text.trimmingCharacters(in: .newlines)
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
                throw RelayWorkspaceCustodyFailure
                    .workspaceVerificationFailed
            }
            return result.standardOutput
        } catch let error as RelayWorkspaceCustodyFailure {
            throw error
        } catch let error as RelayGitCommandError {
            throw RelayWorkspaceCustodyFailure.git(error)
        }
    }

}

private enum RelayWorkspaceSnapshotDigest {
    static func compute(
        head: RelayGitOID,
        status: Data,
        trackedPatch: Data,
        untracked: [RelayUntrackedFileSnapshot]
    ) -> RelayDigest {
        var builder = RelayWorkspaceDigestBuilder()
        builder.append(Data("relay-workspace-snapshot-v1".utf8))
        builder.append(Data(head.rawValue.utf8))
        builder.append(status)
        builder.append(trackedPatch)
        for file in untracked {
            builder.append(Data(file.relativePath.utf8))
            builder.append(Data(file.kind.rawValue.utf8))
            builder.append(Data(String(file.byteCount).utf8))
            builder.append(Data(file.contentDigest.rawValue.utf8))
            builder.append(file.binaryPatch)
        }
        return builder.digest
    }
}

private struct RelayWorkspaceMaterial: Equatable {
    let head: RelayGitOID
    let status: Data
    let trackedPatch: Data
    let untracked: [RelayUntrackedFileSnapshot]
    let exportPatch: Data
}

private struct RelayWorkspaceFileContent {
    let kind: RelayUntrackedFileKind
    let data: Data
}

private enum RelayWorkspaceFileReader {
    static func read(
        relativePath: String,
        beneath root: URL,
        maximumBytes: Int,
        maximumPathBytes: Int
    ) throws -> RelayWorkspaceFileContent {
        guard
            !relativePath.hasPrefix("/"),
            !relativePath.contains("\0"),
            relativePath.utf8.count <= maximumPathBytes
        else {
            throw RelayWorkspaceCustodyFailure.pathInvalid(relativePath)
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            throw RelayWorkspaceCustodyFailure.pathInvalid(relativePath)
        }
        let fileURL = root.appendingPathComponent(relativePath)
        let parent: URL
        let canonicalRoot: URL
        do {
            canonicalRoot = try RelayRepositoryFileFacts.canonicalDirectory(
                root
            )
            parent = try RelayRepositoryFileFacts.canonicalDirectory(
                fileURL.deletingLastPathComponent()
            )
        } catch {
            throw RelayWorkspaceCustodyFailure.pathInvalid(relativePath)
        }
        guard parent.path == canonicalRoot.path
                || parent.path.hasPrefix(canonicalRoot.path + "/")
        else {
            throw RelayWorkspaceCustodyFailure.pathInvalid(relativePath)
        }

        var facts = stat()
        guard lstat(fileURL.path, &facts) == 0 else {
            throw RelayWorkspaceCustodyFailure.fileReadFailed(relativePath)
        }
        switch facts.st_mode & S_IFMT {
        case S_IFREG:
            return RelayWorkspaceFileContent(
                kind: .regular,
                data: try readRegular(
                    fileURL,
                    initialFacts: facts,
                    maximumBytes: maximumBytes,
                    relativePath: relativePath
                )
            )
        case S_IFLNK:
            return RelayWorkspaceFileContent(
                kind: .symbolicLink,
                data: try readLink(
                    fileURL,
                    initialFacts: facts,
                    maximumBytes: maximumBytes,
                    relativePath: relativePath
                )
            )
        default:
            throw RelayWorkspaceCustodyFailure
                .untrackedFileUnsupported(relativePath)
        }
    }

    private static func readRegular(
        _ url: URL,
        initialFacts: stat,
        maximumBytes: Int,
        relativePath: String
    ) throws -> Data {
        guard initialFacts.st_size >= 0,
              initialFacts.st_size <= maximumBytes
        else {
            throw RelayWorkspaceCustodyFailure
                .untrackedFileTooLarge(relativePath)
        }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw RelayWorkspaceCustodyFailure.fileReadFailed(relativePath)
        }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_mode & S_IFMT == S_IFREG,
              before.st_dev == initialFacts.st_dev,
              before.st_ino == initialFacts.st_ino,
              before.st_size >= 0,
              before.st_size <= maximumBytes
        else {
            throw RelayWorkspaceCustodyFailure
                .fileChangedDuringRead(relativePath)
        }
        var result = Data()
        result.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        var interrupted = 0
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                interrupted = 0
                guard result.count + count <= maximumBytes else {
                    throw RelayWorkspaceCustodyFailure
                        .untrackedFileTooLarge(relativePath)
                }
                result.append(buffer, count: count)
                continue
            }
            if count == 0 { break }
            if errno == EINTR, interrupted < 64 {
                interrupted += 1
                continue
            }
            throw RelayWorkspaceCustodyFailure.fileReadFailed(relativePath)
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              stable(before, after),
              result.count == Int(after.st_size)
        else {
            throw RelayWorkspaceCustodyFailure
                .fileChangedDuringRead(relativePath)
        }
        return result
    }

    private static func readLink(
        _ url: URL,
        initialFacts: stat,
        maximumBytes: Int,
        relativePath: String
    ) throws -> Data {
        let capacity = min(maximumBytes + 1, 1_024 * 1_024)
        guard capacity > 0 else {
            throw RelayWorkspaceCustodyFailure
                .untrackedFileTooLarge(relativePath)
        }
        var buffer = [UInt8](repeating: 0, count: capacity)
        let count = Darwin.readlink(url.path, &buffer, buffer.count)
        guard count >= 0 else {
            throw RelayWorkspaceCustodyFailure.fileReadFailed(relativePath)
        }
        guard count < buffer.count, count <= maximumBytes else {
            throw RelayWorkspaceCustodyFailure
                .untrackedFileTooLarge(relativePath)
        }
        var after = stat()
        guard lstat(url.path, &after) == 0,
              stable(initialFacts, after)
        else {
            throw RelayWorkspaceCustodyFailure
                .fileChangedDuringRead(relativePath)
        }
        return Data(buffer.prefix(count))
    }

    private static func stable(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_mode == rhs.st_mode
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}

private struct RelayWorkspaceDigestBuilder {
    private var hasher = SHA256()

    mutating func append(_ data: Data) {
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) { bytes in
            hasher.update(data: Data(bytes))
        }
        hasher.update(data: data)
    }

    var digest: RelayDigest {
        let encoded = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
        return RelayDigest(rawValue: encoded)!
    }
}

public struct RelayWorkspacePatchExportReceipt: Equatable, Sendable {
    public let destinationURL: URL
    public let byteCount: UInt64
    public let contentDigest: RelayDigest
    public let untrackedFileCount: Int

    public init(
        destinationURL: URL,
        byteCount: UInt64,
        contentDigest: RelayDigest,
        untrackedFileCount: Int
    ) {
        self.destinationURL = destinationURL
        self.byteCount = byteCount
        self.contentDigest = contentDigest
        self.untrackedFileCount = untrackedFileCount
    }
}

public struct RelayWorkspacePatchExporter: Sendable {
    public init() {}

    public func export(
        snapshot: RelayWorkspaceSnapshot,
        to destinationURL: URL
    ) throws -> RelayWorkspacePatchExportReceipt {
        guard destinationURL.isFileURL,
              destinationURL.path.hasPrefix("/")
        else {
            throw RelayWorkspaceCustodyFailure.exportFailed
        }
        let parent: URL
        do {
            parent = try RelayRepositoryFileFacts.canonicalDirectory(
                destinationURL.deletingLastPathComponent()
            )
        } catch {
            throw RelayWorkspaceCustodyFailure.exportFailed
        }
        let destination = parent.appendingPathComponent(
            destinationURL.lastPathComponent,
            isDirectory: false
        )
        let descriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw RelayWorkspaceCustodyFailure.exportDestinationExists
            }
            throw RelayWorkspaceCustodyFailure.exportFailed
        }
        defer {
            _ = Darwin.close(descriptor)
        }
        do {
            try writeAll(snapshot.exportableBinaryPatch, to: descriptor)
            guard fsync(descriptor) == 0 else {
                throw RelayWorkspaceCustodyFailure.exportFailed
            }
        } catch {
            // Preserve a partial export. Darwin cannot unlink by exact opened
            // descriptor identity, so name-based cleanup could delete a
            // replacement installed after creation.
            throw RelayWorkspaceCustodyFailure.exportFailed
        }
        return RelayWorkspacePatchExportReceipt(
            destinationURL: destination,
            byteCount: UInt64(snapshot.exportableBinaryPatch.count),
            contentDigest: RelayRepositoryFileFacts.sha256(
                snapshot.exportableBinaryPatch
            ),
            untrackedFileCount: snapshot.untrackedFiles.count
        )
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            var interrupted = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if written > 0 {
                    interrupted = 0
                    offset += written
                    continue
                }
                if written == -1, errno == EINTR, interrupted < 64 {
                    interrupted += 1
                    continue
                }
                throw RelayWorkspaceCustodyFailure.exportFailed
            }
        }
    }
}
