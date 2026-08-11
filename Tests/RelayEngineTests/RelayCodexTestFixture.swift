import Darwin
import Foundation
import RelayCore
import RelayEngine

struct RelayCodexTestContextFixture {
    let root: URL
    let context: RelayCodexControlContext

    init(
        stage: RelayCodexStagePolicy = .implement,
        authority: RelayAuthority = .implementer
    ) throws {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "parallax-relay-codex-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: created,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        root = created.resolvingSymlinksInPath().standardizedFileURL

        var facts = stat()
        guard lstat(root.path, &facts) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        let fileIdentity = RelayFileIdentity(
            deviceID: UInt64(facts.st_dev),
            fileID: UInt64(facts.st_ino)
        )
        let taskID = RelayTaskID()
        let workspaceIdentity = RelayWorkspaceIdentity(
            taskID: taskID,
            repositoryRootPath: root.path,
            gitCommonDirectoryPath: root.path,
            repositoryFileIdentity: fileIdentity,
            gitCommonDirectoryFileIdentity: fileIdentity,
            baseCommit: RelayGitOID(
                rawValue: String(repeating: "a", count: 40)
            )!,
            headCommit: RelayGitOID(
                rawValue: String(repeating: "a", count: 40)
            )!,
            workspaceDigest: RelayDigest(
                rawValue: String(repeating: "b", count: 64)
            )!,
            taskReference: "detached/\(taskID.description)",
            isClean: true,
            preparedAt: RelayInstant(rawValue: 1)
        )
        context = try RelayCodexControlContext(
            taskID: taskID,
            stageID: RelayStageID(),
            attemptID: RelayAttemptID(),
            workspace: RelayCodexWorkspaceBinding(identity: workspaceIdentity),
            stage: stage,
            authority: authority
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
