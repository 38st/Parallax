import RelayCore
import XCTest

final class RelayReadyGateTests: XCTestCase {
    func testExactAdmissionGateAcceptsACompleteFrozenTask() throws {
        let state = try RelayCoreFixtures.admitted()

        XCTAssertEqual(RelayReadyGate.evaluate(state).blockers, [])
        XCTAssertEqual(
            try RelayReducer.reducing(state, command: .declareReady).status,
            .ready
        )
    }

    func testGateReturnsEveryIndependentWorkspaceBlocker() throws {
        let malformedWorkspace = RelayWorkspaceIdentity(
            taskID: RelayCoreFixtures.taskID,
            repositoryRootPath: "relative/repository",
            gitCommonDirectoryPath: "relative/git",
            repositoryFileIdentity: RelayFileIdentity(deviceID: 1, fileID: 2),
            gitCommonDirectoryFileIdentity: RelayFileIdentity(deviceID: 1, fileID: 3),
            baseCommit: RelayCoreFixtures.initialCommit,
            headCommit: RelayCoreFixtures.initialCommit,
            workspaceDigest: RelayCoreFixtures.initialDigest,
            taskReference: " ",
            isClean: false,
            preparedAt: RelayCoreFixtures.instant
        )
        var state = try RelayCoreFixtures.admitted()
        state.workspace = malformedWorkspace
        let blockers = RelayReadyGate.evaluate(state).blockers

        XCTAssertTrue(blockers.contains(.repositoryPathNotAbsolute))
        XCTAssertTrue(blockers.contains(.gitCommonDirectoryPathNotAbsolute))
        XCTAssertTrue(blockers.contains(.workspaceNotClean))
        XCTAssertTrue(blockers.contains(.taskReferenceMissing))
        XCTAssertTrue(blockers.contains(.workspaceProvisioningIntentMismatch))
    }

    func testGateRejectsSnapshotDigestThatDoesNotMatchProjection() throws {
        var state = try RelayCoreFixtures.admitted()
        state.currentWorkspaceDigest = RelayCoreFixtures.otherDigest

        XCTAssertEqual(
            RelayReadyGate.evaluate(state).blockers,
            [.workspaceDigestMismatch]
        )
        XCTAssertThrowsError(try RelayReducer.reducing(state, command: .declareReady)) {
            XCTAssertEqual(
                $0 as? RelayCoreError,
                .readyBlocked([.workspaceDigestMismatch])
            )
        }
    }

    func testDuplicateStagesAndForwardRejectionTargetAreRejected() throws {
        let duplicate = RelayStageDefinition(
            id: RelayCoreFixtures.implementStageID,
            name: "Duplicate",
            role: .reviewer,
            authority: .reviewer,
            rejectionStageID: RelayCoreFixtures.reviewStageID
        )
        let task = RelayCoreFixtures.task(
            stages: [duplicate, RelayCoreFixtures.implementStage()]
        )
        let state = try RelayCoreFixtures.admitted(task: task)
        let blockers = RelayReadyGate.evaluate(state).blockers

        XCTAssertTrue(blockers.contains(.duplicateStageID(RelayCoreFixtures.implementStageID)))
        XCTAssertTrue(blockers.contains(.invalidRejectionTarget(duplicate.id)))
    }

    func testReviewerCannotRequestWriteOrCheckpointAuthority() throws {
        let unsafeReview = RelayStageDefinition(
            id: RelayCoreFixtures.reviewStageID,
            name: "Unsafe review",
            role: .reviewer,
            authority: RelayAuthority(
                fileSystem: .workspaceWrite,
                execution: .test,
                git: .checkpoint
            )
        )
        let state = try RelayCoreFixtures.admitted(
            task: RelayCoreFixtures.task(stages: [unsafeReview])
        )

        XCTAssertTrue(
            RelayReadyGate.evaluate(state).blockers
                .contains(.invalidAuthority(unsafeReview.id))
        )
    }

    func testReadyTransitionCannotBeRepeated() throws {
        var state = try RelayCoreFixtures.admitted()
        state = try RelayReducer.reducing(state, command: .declareReady)

        XCTAssertThrowsError(try RelayReducer.reducing(state, command: .declareReady))
    }

    func testWorkspaceIdentityIsImmutable() throws {
        let state = try RelayCoreFixtures.admitted()

        XCTAssertThrowsError(
            try RelayReducer.reducing(
                state,
                command: .recordWorkspacePrepared(RelayCoreFixtures.workspace())
            )
        )
    }
}
