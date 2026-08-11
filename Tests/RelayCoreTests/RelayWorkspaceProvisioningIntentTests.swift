import RelayCore
import XCTest

final class RelayWorkspaceProvisioningIntentTests: XCTestCase {
    func testPreparedWorkspaceIsIllegalWithoutDurableIntent() throws {
        let created = try RelayReducer.reducing(
            .empty,
            command: .createTask(RelayCoreFixtures.task())
        )

        XCTAssertThrowsError(
            try RelayReducer.reducing(
                created,
                command: .recordWorkspacePrepared(RelayCoreFixtures.workspace())
            )
        ) {
            XCTAssertEqual(
                $0 as? RelayCoreError,
                .invalidValue("Workspace provisioning was not durably requested.")
            )
        }
    }

    func testIntentIsImmutableAndMustPrecedeProvisioningOutcome() throws {
        var state = try RelayReducer.reducing(
            .empty,
            command: .createTask(RelayCoreFixtures.task())
        )
        let intent = RelayCoreFixtures.provisioningIntent()
        state = try RelayReducer.reducing(
            state,
            command: .requestWorkspaceProvisioning(intent)
        )
        XCTAssertEqual(state.workspaceProvisioningIntent, intent)
        XCTAssertNil(state.workspace)

        XCTAssertThrowsError(
            try RelayReducer.reducing(
                state,
                command: .requestWorkspaceProvisioning(intent)
            )
        )
        state = try RelayReducer.reducing(
            state,
            command: .recordWorkspacePrepared(RelayCoreFixtures.workspace())
        )
        XCTAssertEqual(state.workspace, RelayCoreFixtures.workspace())
    }

    func testIntentRejectsWrongTaskNoncanonicalPathsAndUnexpectedTarget() throws {
        let created = try RelayReducer.reducing(
            .empty,
            command: .createTask(RelayCoreFixtures.task())
        )
        let wrongTask: RelayTaskID = RelayCoreFixtures.id(700)
        let cases = [
            intent(taskID: wrongTask),
            intent(sourceRoot: "relative/source"),
            intent(sourceRoot: "/tmp/source/../source-repository"),
            intent(managedRoot: "/"),
            intent(target: "/tmp/relay-managed/sibling"),
            intent(target: "/tmp/relay-managed/../escape"),
            intent(reference: "detached/wrong"),
        ]

        for value in cases {
            XCTAssertThrowsError(
                try RelayReducer.reducing(
                    created,
                    command: .requestWorkspaceProvisioning(value)
                ),
                "Unexpectedly accepted \(value)"
            )
        }
    }

    func testPreparedOutcomeMustMatchEveryAvailableIntentFact() throws {
        var requested = try RelayReducer.reducing(
            .empty,
            command: .createTask(RelayCoreFixtures.task())
        )
        requested = try RelayReducer.reducing(
            requested,
            command: .requestWorkspaceProvisioning(
                RelayCoreFixtures.provisioningIntent()
            )
        )
        let mismatches = [
            workspace(root: "/tmp/relay-managed/sibling"),
            workspace(commonPath: "/tmp/other/.git"),
            workspace(commonIdentity: RelayFileIdentity(deviceID: 9, fileID: 9)),
            workspace(base: RelayGitOID(rawValue: String(repeating: "b", count: 40))!),
            workspace(head: RelayGitOID(rawValue: String(repeating: "b", count: 40))!),
            workspace(digest: RelayCoreFixtures.otherDigest),
            workspace(reference: "detached/wrong"),
            workspace(clean: false),
        ]

        for value in mismatches {
            XCTAssertThrowsError(
                try RelayReducer.reducing(
                    requested,
                    command: .recordWorkspacePrepared(value)
                ),
                "Unexpectedly adopted mismatched workspace \(value)"
            )
        }
    }

    func testReadyGateRevalidatesIntentAgainstTamperedProjection() throws {
        var state = try RelayCoreFixtures.admitted()
        state.workspaceProvisioningIntent = intent(
            target: "/tmp/relay-managed/sibling"
        )

        XCTAssertTrue(
            RelayReadyGate.evaluate(state).blockers
                .contains(.workspaceProvisioningIntentMismatch)
        )

        state.workspaceProvisioningIntent = nil
        let blockers = RelayReadyGate.evaluate(state).blockers
        XCTAssertTrue(blockers.contains(.workspaceProvisioningIntentMissing))
    }

    func testIntentCanonicalEncodingRoundTripsDeterministically() throws {
        let intent = RelayCoreFixtures.provisioningIntent()
        let first = try RelayCanonicalEncoding.encode(intent)
        let second = try RelayCanonicalEncoding.encode(intent)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            try JSONDecoder().decode(
                RelayWorkspaceProvisioningIntent.self,
                from: first
            ),
            intent
        )
    }
}

private extension RelayWorkspaceProvisioningIntentTests {
    func intent(
        taskID: RelayTaskID = RelayCoreFixtures.taskID,
        sourceRoot: String = "/tmp/source-repository",
        managedRoot: String = "/tmp/relay-managed",
        target: String? = nil,
        reference: String? = nil
    ) -> RelayWorkspaceProvisioningIntent {
        RelayWorkspaceProvisioningIntent(
            id: RelayCoreFixtures.intentID,
            taskID: taskID,
            sourceRepositoryRootPath: sourceRoot,
            sourceRepositoryFileIdentity: RelayFileIdentity(deviceID: 1, fileID: 9),
            sourceGitDirectoryPath: "/tmp/source-repository/.git",
            sourceGitCommonDirectoryPath: "/tmp/source-repository/.git",
            sourceGitCommonDirectoryFileIdentity: RelayFileIdentity(
                deviceID: 1,
                fileID: 3
            ),
            baselineCommit: RelayCoreFixtures.initialCommit,
            managedRootPath: managedRoot,
            managedRootFileIdentity: RelayFileIdentity(deviceID: 1, fileID: 8),
            targetWorkspacePath: target
                ?? "\(managedRoot)/\(taskID.description)",
            expectedTaskReference: reference ?? "detached/\(taskID.description)",
            expectedInitialWorkspaceDigest: RelayCoreFixtures.initialDigest,
            requestedAt: RelayCoreFixtures.instant
        )
    }

    func workspace(
        root: String? = nil,
        commonPath: String? = nil,
        commonIdentity: RelayFileIdentity? = nil,
        base: RelayGitOID? = nil,
        head: RelayGitOID? = nil,
        digest: RelayDigest? = nil,
        reference: String? = nil,
        clean: Bool = true
    ) -> RelayWorkspaceIdentity {
        RelayWorkspaceIdentity(
            taskID: RelayCoreFixtures.taskID,
            repositoryRootPath: root
                ?? "/tmp/relay-managed/\(RelayCoreFixtures.taskID.description)",
            gitCommonDirectoryPath: commonPath ?? "/tmp/source-repository/.git",
            repositoryFileIdentity: RelayFileIdentity(deviceID: 1, fileID: 2),
            gitCommonDirectoryFileIdentity: commonIdentity
                ?? RelayFileIdentity(deviceID: 1, fileID: 3),
            baseCommit: base ?? RelayCoreFixtures.initialCommit,
            headCommit: head ?? RelayCoreFixtures.initialCommit,
            workspaceDigest: digest ?? RelayCoreFixtures.initialDigest,
            taskReference: reference
                ?? "detached/\(RelayCoreFixtures.taskID.description)",
            isClean: clean,
            preparedAt: RelayCoreFixtures.instant
        )
    }
}
