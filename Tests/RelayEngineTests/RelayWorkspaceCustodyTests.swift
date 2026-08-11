import CryptoKit
import Darwin
import Foundation
import RelayCore
@testable import RelayEngine
import XCTest

final class RelayWorkspaceCustodyTests: XCTestCase {
    func testProvisioningIntentBindsExactAbsentTargetBeforeMutation()
        throws
    {
        let fixture = try RelayWorkspaceFixture()
        defer { fixture.removeTestFixtureOnly() }
        let admission = try fixture.admission()
        let requestedAt = RelayInstant(rawValue: 123)

        let intent = try fixture.custodian.makeProvisioningIntent(
            taskID: fixture.taskID,
            repository: admission,
            requestedAt: requestedAt
        )

        XCTAssertEqual(intent.taskID, fixture.taskID)
        XCTAssertEqual(
            intent.sourceRepositoryRootPath,
            admission.repositoryRootURL.standardizedFileURL.path
        )
        XCTAssertEqual(
            intent.sourceRepositoryFileIdentity,
            admission.repositoryFileIdentity
        )
        XCTAssertEqual(intent.baselineCommit, admission.baselineCommit)
        let canonicalManagedRoot = try RelayRepositoryFileFacts
            .canonicalDirectory(fixture.managedRootURL)
        let durableManagedRoot = canonicalManagedRoot.standardizedFileURL
        XCTAssertEqual(intent.managedRootPath, durableManagedRoot.path)
        XCTAssertEqual(
            intent.targetWorkspacePath,
            durableManagedRoot.appendingPathComponent(
                fixture.taskID.description
            ).path
        )
        XCTAssertEqual(
            intent.expectedTaskReference,
            "detached/\(fixture.taskID.description)"
        )
        XCTAssertEqual(intent.requestedAt, requestedAt)
        let intentPaths = [
            intent.sourceRepositoryRootPath,
            intent.sourceGitDirectoryPath,
            intent.sourceGitCommonDirectoryPath,
            intent.managedRootPath,
            intent.targetWorkspacePath,
        ]
        for path in intentPaths {
            XCTAssertEqual(
                URL(fileURLWithPath: path).standardizedFileURL.path,
                path,
                "Intent path was not canonical: \(path)"
            )
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: intent.targetWorkspacePath)
        )
        XCTAssertEqual(try fixture.repository.status(), "")
    }

    func testReconcileAbsentIntentIsInspectOnly() throws {
        let fixture = try RelayWorkspaceFixture()
        defer { fixture.removeTestFixtureOnly() }
        let intent = try fixture.intent()

        let result = try fixture.custodian.reconcile(intent: intent)

        XCTAssertEqual(result, .notProvisioned(intent))
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: intent.targetWorkspacePath)
        )
        XCTAssertEqual(try fixture.repository.status(), "")
    }

    func testReconcileAdoptsOnlyExactPreparedWorkspace() throws {
        let fixture = try RelayWorkspaceFixture()
        defer { fixture.removeTestFixtureOnly() }
        let admission = try fixture.admission()
        let intent = try fixture.intent(repository: admission)
        let provisioned = try fixture.custodian.provision(
            intent: intent,
            repository: admission
        )

        let result = try fixture.custodian.reconcile(intent: intent)

        XCTAssertEqual(result, .prepared(provisioned))
        XCTAssertEqual(try fixture.repository.status(), "")
    }

    func testReconcilePreservesUnexpectedTargetAndFailsClosed() throws {
        let fixture = try RelayWorkspaceFixture()
        defer { fixture.removeTestFixtureOnly() }
        let intent = try fixture.intent()
        let target = URL(
            fileURLWithPath: intent.targetWorkspacePath,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        let sentinel = target.appendingPathComponent("do-not-delete.txt")
        try Data("preserve\n".utf8).write(to: sentinel)

        XCTAssertThrowsError(
            try fixture.custodian.reconcile(intent: intent)
        ) { error in
            XCTAssertEqual(
                error as? RelayWorkspaceCustodyFailure,
                .provisioningOutcomeAmbiguous
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("preserve\n".utf8)
        )
    }

    func testProvisionCreatesDetachedManagedWorktreeAndPreservesSource()
        throws
    {
        let fixture = try RelayWorkspaceFixture()
        defer { fixture.removeTestFixtureOnly() }
        let admission = try RelayRepositoryCustodian().preflight(
            repositoryURL: fixture.repository.repositoryURL
        )

        let intent = try fixture.intent(repository: admission)
        let custody = try fixture.custodian.provision(
            intent: intent,
            repository: admission
        )

        XCTAssertTrue(custody.identity.isClean)
        XCTAssertEqual(custody.identity.baseCommit, admission.baselineCommit)
        XCTAssertEqual(custody.identity.headCommit, admission.baselineCommit)
        XCTAssertEqual(
            custody.identity.repositoryRootPath,
            custody.workspaceURL.path
        )
        XCTAssertEqual(try fixture.repository.status(), "")
        XCTAssertEqual(
            try fixture.gitText(
                ["symbolic-ref", "-q", "HEAD"],
                at: custody.workspaceURL,
                acceptedStatus: [1]
            ),
            ""
        )
        XCTAssertEqual(
            try fixture.custodian.revealURL(for: custody),
            custody.workspaceURL
        )
        XCTAssertEqual(
            try RelayWorkspaceSnapshotter().capture(custody).digest,
            custody.identity.workspaceDigest
        )
    }

    func testSnapshotBindsTrackedBinaryDiffStatusAndUntrackedHashes()
        throws
    {
        let fixture = try RelayWorkspaceFixture()
        defer { fixture.removeTestFixtureOnly() }
        let custody = try fixture.provision()
        try Data("modified\n".utf8).write(
            to: custody.workspaceURL.appendingPathComponent("file.txt")
        )
        let binary = Data([0x00, 0x01, 0x02, 0xFF, 0x10])
        try binary.write(
            to: custody.workspaceURL.appendingPathComponent("new.bin")
        )

        let first = try RelayWorkspaceSnapshotter().capture(custody)
        let second = try RelayWorkspaceSnapshotter().capture(custody)

        XCTAssertEqual(first.digest, second.digest)
        XCTAssertEqual(first.headCommit, custody.identity.baseCommit)
        XCTAssertTrue(
            String(decoding: first.porcelainStatus, as: UTF8.self)
                .contains("new.bin")
        )
        XCTAssertTrue(
            String(decoding: first.trackedBinaryDiff, as: UTF8.self)
                .contains("file.txt")
        )
        XCTAssertEqual(first.untrackedFiles.count, 1)
        XCTAssertEqual(first.untrackedFiles[0].relativePath, "new.bin")
        XCTAssertEqual(
            first.untrackedFiles[0].contentDigest.rawValue,
            SHA256.hash(data: binary)
                .map { String(format: "%02x", $0) }
                .joined()
        )
        XCTAssertTrue(first.exportableBinaryPatch.count
            > first.trackedBinaryDiff.count)
    }

    func testSnapshotFailsClosedWhenUntrackedFileExceedsBound() throws {
        let fixture = try RelayWorkspaceFixture()
        defer { fixture.removeTestFixtureOnly() }
        let custody = try fixture.provision()
        try Data(repeating: 0x41, count: 17).write(
            to: custody.workspaceURL.appendingPathComponent("large.bin")
        )
        let snapshotter = RelayWorkspaceSnapshotter(
            policy: RelayWorkspaceSnapshotPolicy(
                maximumStatusBytes: 1_024,
                maximumTrackedPatchBytes: 1_024,
                maximumExportPatchBytes: 2_048,
                maximumUntrackedFiles: 4,
                maximumUntrackedFileBytes: 16,
                maximumTotalUntrackedBytes: 16,
                maximumPathBytes: 1_024
            )
        )

        XCTAssertThrowsError(try snapshotter.capture(custody)) { error in
            XCTAssertEqual(
                error as? RelayWorkspaceCustodyFailure,
                .untrackedFileTooLarge("large.bin")
            )
        }
    }

    func testSnapshotExportsEmptyUntrackedFileWithoutMutatingIndex() throws {
        let fixture = try RelayWorkspaceFixture()
        defer { fixture.removeTestFixtureOnly() }
        let custody = try fixture.provision()
        _ = FileManager.default.createFile(
            atPath: custody.workspaceURL
                .appendingPathComponent("empty.txt").path,
            contents: Data()
        )

        let snapshot = try RelayWorkspaceSnapshotter().capture(custody)

        XCTAssertEqual(snapshot.untrackedFiles.count, 1)
        XCTAssertEqual(snapshot.untrackedFiles[0].byteCount, 0)
        XCTAssertTrue(
            String(decoding: snapshot.exportableBinaryPatch, as: UTF8.self)
                .contains("new file mode 100644")
        )
        XCTAssertTrue(
            try fixture.gitText(
                ["status", "--porcelain=v1"],
                at: custody.workspaceURL
            ).contains("?? empty.txt")
        )
    }

    func testPatchExportIsExactExclusiveAndDoesNotRemoveWorkspace()
        throws
    {
        let fixture = try RelayWorkspaceFixture()
        defer { fixture.removeTestFixtureOnly() }
        let custody = try fixture.provision()
        try Data("modified\n".utf8).write(
            to: custody.workspaceURL.appendingPathComponent("file.txt")
        )
        try Data("new\n".utf8).write(
            to: custody.workspaceURL.appendingPathComponent("new.txt")
        )
        let snapshot = try RelayWorkspaceSnapshotter().capture(custody)
        let destination = fixture.temporaryURL.appendingPathComponent(
            "relay.patch"
        )

        let receipt = try RelayWorkspacePatchExporter().export(
            snapshot: snapshot,
            to: destination
        )

        XCTAssertEqual(
            try Data(contentsOf: destination),
            snapshot.exportableBinaryPatch
        )
        XCTAssertEqual(receipt.untrackedFileCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: custody.workspaceURL.path))
        _ = try RelaySystemGitRunner().run(
            arguments: ["apply", "--check", destination.path],
            workingDirectory: fixture.repository.repositoryURL,
            standardOutputLimit: 1_024,
            standardErrorLimit: 1_024
        )
        XCTAssertThrowsError(
            try RelayWorkspacePatchExporter().export(
                snapshot: snapshot,
                to: destination
            )
        ) { error in
            XCTAssertEqual(
                error as? RelayWorkspaceCustodyFailure,
                .exportDestinationExists
            )
        }
    }

    func testPreserveRecordsReasonWithoutMutatingWorkspace() throws {
        let fixture = try RelayWorkspaceFixture()
        defer { fixture.removeTestFixtureOnly() }
        let custody = try fixture.provision()

        let preservation = fixture.custodian.preserve(
            custody,
            reason: .awaitingUserDecision
        )

        XCTAssertEqual(preservation.workspace, custody)
        XCTAssertEqual(preservation.reason, .awaitingUserDecision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: custody.workspaceURL.path))
    }
}

private final class RelayWorkspaceFixture {
    let repository: RelayGitRepositoryFixture
    let temporaryURL: URL
    let managedRootURL: URL
    let taskID = RelayTaskID()
    let custodian: RelayWorkspaceCustodian

    init() throws {
        repository = try RelayGitRepositoryFixture()
        temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "relay-workspace-tests-\(UUID().uuidString)",
                isDirectory: true
            )
            .resolvingSymlinksInPath()
        managedRootURL = temporaryURL.appendingPathComponent(
            "RelayWorkspaces",
            isDirectory: true
        )
        custodian = RelayWorkspaceCustodian(
            managedRootURL: managedRootURL,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    func provision() throws -> RelayWorkspaceCustody {
        let admission = try admission()
        let intent = try intent(repository: admission)
        return try custodian.provision(
            intent: intent,
            repository: admission
        )
    }

    func admission() throws -> RelayRepositoryAdmission {
        try RelayRepositoryCustodian().preflight(
            repositoryURL: repository.repositoryURL
        )
    }

    func intent(
        repository admission: RelayRepositoryAdmission? = nil
    ) throws -> RelayWorkspaceProvisioningIntent {
        try custodian.makeProvisioningIntent(
            taskID: taskID,
            repository: admission ?? self.admission(),
            requestedAt: RelayInstant(rawValue: 123)
        )
    }

    func gitText(
        _ arguments: [String],
        at directory: URL,
        acceptedStatus: Set<Int32> = [0]
    ) throws -> String {
        let result = try RelaySystemGitRunner().run(
            arguments: arguments,
            workingDirectory: directory,
            standardOutputLimit: 1_024,
            acceptedExitStatuses: acceptedStatus
        )
        return String(decoding: result.standardOutput, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func removeTestFixtureOnly() {
        repository.preserveThenRemoveTestFixture()
        try? FileManager.default.removeItem(at: temporaryURL)
    }
}
