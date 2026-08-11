import Darwin
import Foundation
import RelayCore
import XCTest
@testable import RelayEngine

final class RelayAuthorityCapabilityTests: XCTestCase {
    func testPolicyRejectsAmbientCredentialsAndMissingNoNetworkProof() throws {
        let fixture = try CapabilityFixture()
        let unsafeAuthority = RelayAuthority(
            fileSystem: .workspaceWrite,
            execution: .test,
            git: .read,
            credentials: .selectedCodexHome
        )

        XCTAssertThrowsError(
            try fixture.policy(authority: unsafeAuthority)
        ) { error in
            XCTAssertEqual(
                error as? RelayStageCapabilityPolicyError,
                .credentialsUnsupported
            )
        }

        let noNetworkAuthority = RelayAuthority(
            fileSystem: .workspaceWrite,
            execution: .test,
            network: .none,
            git: .read,
            credentials: .none
        )
        XCTAssertThrowsError(
            try fixture.policy(
                authority: noNetworkAuthority,
                requirements: RelaySandboxRequirements(
                    requiresFilesystemBoundary: true,
                    requiresNetworkDeny: false,
                    requiresProcessContainment: true
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? RelayStageCapabilityPolicyError,
                .networkDenyRequired
            )
        }
    }

    func testCapabilityBindsTaskStageAttemptWorkspaceAndInvocationCount() throws {
        let fixture = try CapabilityFixture()
        let policy = try fixture.policy()
        let issuer = RelayStageCapabilityIssuer()
        let handle = issuer.issue(policy)
        let sandbox = try fixture.sandboxAuthorization()

        let wrongStage = RelayStageExecutionContext(
            taskID: fixture.taskID,
            stageID: RelayStageID(),
            attemptID: fixture.attemptID,
            workspaceIdentity: fixture.workspace,
            workspaceDigest: fixture.workspaceDigest,
            executable: fixture.executable
        )
        assertFailure(
            issuer.authorizeExecution(
                handle: handle,
                context: wrongStage,
                sandbox: sandbox,
                now: RelayInstant(rawValue: 1)
            ),
            equals: .wrongStage
        )

        let context = fixture.context()
        guard case .success = issuer.authorizeExecution(
            handle: handle,
            context: context,
            sandbox: sandbox,
            now: RelayInstant(rawValue: 1)
        ) else {
            return XCTFail("The exact first invocation should authorize.")
        }
        assertFailure(
            issuer.authorizeExecution(
                handle: handle,
                context: context,
                sandbox: sandbox,
                now: RelayInstant(rawValue: 1)
            ),
            equals: .exhausted
        )
    }

    func testRevocationReachesAnAlreadyAuthorizedExecution() throws {
        let fixture = try CapabilityFixture()
        let issuer = RelayStageCapabilityIssuer()
        let handle = issuer.issue(try fixture.policy())
        let result = issuer.authorizeExecution(
            handle: handle,
            context: fixture.context(),
            sandbox: try fixture.sandboxAuthorization(),
            now: RelayInstant(rawValue: 1)
        )
        guard case .success(let authorization) = result else {
            return XCTFail("Expected exact authorization.")
        }

        XCTAssertFalse(authorization.revocation.isRevoked)
        issuer.revoke(handle)
        XCTAssertTrue(authorization.revocation.isRevoked)
        assertFailure(
            issuer.authorizeExecution(
                handle: handle,
                context: fixture.context(),
                sandbox: try fixture.sandboxAuthorization(),
                now: RelayInstant(rawValue: 1)
            ),
            equals: .revoked
        )
    }

    func testExpiredCapabilityFailsClosed() throws {
        let fixture = try CapabilityFixture()
        let issuer = RelayStageCapabilityIssuer()
        let handle = issuer.issue(
            try fixture.policy(expiresAt: RelayInstant(rawValue: 10))
        )

        assertFailure(
            issuer.authorizeExecution(
                handle: handle,
                context: fixture.context(),
                sandbox: try fixture.sandboxAuthorization(),
                now: RelayInstant(rawValue: 10)
            ),
            equals: .expired
        )
    }

    private func assertFailure(
        _ result: Result<
            RelayStageExecutionAuthorization,
            RelayStageCapabilityRejection
        >,
        equals expected: RelayStageCapabilityRejection,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .failure(let failure) = result else {
            return XCTFail(
                "Expected failure \(expected).",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(failure, expected, file: file, line: line)
    }
}

private final class CapabilityFixture {
    let taskID = RelayTaskID()
    let stageID = RelayStageID()
    let attemptID = RelayAttemptID()
    let workspaceDigest = RelayDigest(rawValue: String(repeating: "a", count: 64))!
    let root: URL
    let workspace: RelayWorkspaceIdentity
    let executable: RelayExecutableIdentity

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "relay-capability-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: git,
            withIntermediateDirectories: true
        )
        var rootStatus = stat()
        var gitStatus = stat()
        XCTAssertEqual(lstat(root.path, &rootStatus), 0)
        XCTAssertEqual(lstat(git.path, &gitStatus), 0)
        let oid = RelayGitOID(rawValue: String(repeating: "b", count: 40))!
        workspace = RelayWorkspaceIdentity(
            taskID: taskID,
            repositoryRootPath: root.path,
            gitCommonDirectoryPath: git.path,
            repositoryFileIdentity: RelayFileIdentity(
                deviceID: UInt64(rootStatus.st_dev),
                fileID: UInt64(rootStatus.st_ino)
            ),
            gitCommonDirectoryFileIdentity: RelayFileIdentity(
                deviceID: UInt64(gitStatus.st_dev),
                fileID: UInt64(gitStatus.st_ino)
            ),
            baseCommit: oid,
            headCommit: oid,
            workspaceDigest: workspaceDigest,
            taskReference: "refs/relay/test",
            isClean: true,
            preparedAt: RelayInstant(rawValue: 0)
        )
        executable = try RelayExecutableIdentity(
            inspecting: URL(fileURLWithPath: "/bin/sleep")
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func policy(
        authority: RelayAuthority = RelayAuthority(
            fileSystem: .workspaceWrite,
            execution: .test,
            network: .none,
            git: .read,
            credentials: .none
        ),
        requirements: RelaySandboxRequirements = .secureDefault,
        expiresAt: RelayInstant? = nil
    ) throws -> RelayStageCapabilityPolicy {
        try RelayStageCapabilityPolicy(
            taskID: taskID,
            stageID: stageID,
            attemptID: attemptID,
            workspaceIdentity: workspace,
            workspaceDigest: workspaceDigest,
            authority: authority,
            allowedExecutables: [executable],
            sandboxRequirements: requirements,
            commandBudget: RelayCommandBudget(wallTime: .seconds(2)),
            expiresAt: expiresAt
        )
    }

    func context() -> RelayStageExecutionContext {
        RelayStageExecutionContext(
            taskID: taskID,
            stageID: stageID,
            attemptID: attemptID,
            workspaceIdentity: workspace,
            workspaceDigest: workspaceDigest,
            executable: executable
        )
    }

    func sandboxAuthorization() throws -> RelaySandboxExecutionAuthorization {
        let report = RelaySandboxCapabilityReport(
            backendIdentifier: "test-secure",
            filesystemBoundary: .proven(mechanism: "fixture"),
            networkDeny: .proven(mechanism: "fixture"),
            processContainment: .proven(mechanism: "fixture"),
            executableIdentityPinning: .proven(mechanism: "fixture")
        )
        guard case .authorized(let authorization) =
            RelaySandboxValidator().validate(report)
        else {
            throw CocoaError(.featureUnsupported)
        }
        return authorization
    }
}
