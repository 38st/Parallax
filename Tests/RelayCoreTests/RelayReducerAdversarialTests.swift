import RelayCore
import XCTest

final class RelayReducerAdversarialTests: XCTestCase {
    func testReviewerRejectionReturnsToOwnerAndPreservesFindingIdentity() throws {
        var state = try runningTwoStageTask()
        state = try approveFirstImplementation(in: state)
        let reviewID: RelayAttemptID = RelayCoreFixtures.id(101)
        state = try RelayCoreFixtures.scheduleAndRun(
            RelayCoreFixtures.attempt(
                id: reviewID,
                stageID: RelayCoreFixtures.reviewStageID,
                ordinal: 1,
                digest: RelayCoreFixtures.changedDigest
            ),
            in: state
        )
        let finding = blockingFinding(id: RelayCoreFixtures.id(102), attemptID: reviewID)
        state = try RelayReducer.reducing(state, command: .openFinding(finding))
        state = try RelayReducer.reducing(
            state,
            command: .rejectAttempt(
                reviewID,
                baton: RelayCoreFixtures.baton(
                    id: RelayCoreFixtures.id(103),
                    revision: 2,
                    from: RelayCoreFixtures.reviewStageID,
                    to: RelayCoreFixtures.implementStageID,
                    sourceDigest: RelayCoreFixtures.changedDigest,
                    resultDigest: RelayCoreFixtures.changedDigest,
                    findings: [finding.id]
                ),
                at: RelayCoreFixtures.later
            )
        )

        XCTAssertEqual(state.currentStageID, RelayCoreFixtures.implementStageID)
        XCTAssertEqual(state.finding(finding.id)?.status, .open)
        XCTAssertEqual(state.attempt(reviewID)?.status, .rejected)
        XCTAssertEqual(state.stage(RelayCoreFixtures.reviewStageID)?.rejectionCount, 1)
        XCTAssertEqual(state.stage(RelayCoreFixtures.implementStageID)?.status, .pending)
        XCTAssertEqual(state.stage(RelayCoreFixtures.reviewStageID)?.status, .pending)
    }

    func testRejectionRequiresARealBlockingFindingFromCurrentAttempt() throws {
        var state = try runningTwoStageTask()
        state = try approveFirstImplementation(in: state)
        let reviewID: RelayAttemptID = RelayCoreFixtures.id(104)
        state = try RelayCoreFixtures.scheduleAndRun(
            RelayCoreFixtures.attempt(
                id: reviewID,
                stageID: RelayCoreFixtures.reviewStageID,
                ordinal: 1,
                digest: RelayCoreFixtures.changedDigest
            ),
            in: state
        )

        XCTAssertThrowsError(
            try RelayReducer.reducing(
                state,
                command: .rejectAttempt(
                    reviewID,
                    baton: RelayCoreFixtures.baton(
                        id: RelayCoreFixtures.id(105),
                        revision: 2,
                        from: RelayCoreFixtures.reviewStageID,
                        to: RelayCoreFixtures.implementStageID,
                        sourceDigest: RelayCoreFixtures.changedDigest,
                        resultDigest: RelayCoreFixtures.changedDigest
                    ),
                    at: RelayCoreFixtures.later
                )
            )
        ) { XCTAssertEqual($0 as? RelayCoreError, .blockingFindingRequired) }
    }

    func testZeroRejectionBudgetFailsClosed() throws {
        let task = RelayCoreFixtures.task(stages: [
            RelayCoreFixtures.implementStage(),
            RelayCoreFixtures.reviewStage(maximumRejectionCycles: 0),
        ])
        var state = try RelayCoreFixtures.running(task: task)
        state = try approveFirstImplementation(in: state)
        let reviewID: RelayAttemptID = RelayCoreFixtures.id(106)
        state = try RelayCoreFixtures.scheduleAndRun(
            RelayCoreFixtures.attempt(
                id: reviewID,
                stageID: RelayCoreFixtures.reviewStageID,
                ordinal: 1,
                digest: RelayCoreFixtures.changedDigest
            ),
            in: state
        )
        let finding = blockingFinding(id: RelayCoreFixtures.id(107), attemptID: reviewID)
        state = try RelayReducer.reducing(state, command: .openFinding(finding))

        XCTAssertThrowsError(
            try RelayReducer.reducing(
                state,
                command: .rejectAttempt(
                    reviewID,
                    baton: RelayCoreFixtures.baton(
                        id: RelayCoreFixtures.id(108),
                        revision: 2,
                        from: RelayCoreFixtures.reviewStageID,
                        to: RelayCoreFixtures.implementStageID,
                        sourceDigest: RelayCoreFixtures.changedDigest,
                        resultDigest: RelayCoreFixtures.changedDigest,
                        findings: [finding.id]
                    ),
                    at: RelayCoreFixtures.later
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? RelayCoreError,
                .rejectionBudgetExhausted(RelayCoreFixtures.reviewStageID)
            )
        }
    }

    func testBatonRejectsUnknownAndDuplicateReferences() throws {
        var state = try RelayCoreFixtures.running()
        let attemptID: RelayAttemptID = RelayCoreFixtures.id(109)
        state = try RelayCoreFixtures.scheduleAndRun(
            RelayCoreFixtures.attempt(
                id: attemptID,
                stageID: RelayCoreFixtures.implementStageID,
                ordinal: 1,
                digest: RelayCoreFixtures.initialDigest
            ),
            in: state
        )
        let unknown: RelayEvidenceID = RelayCoreFixtures.id(110)
        let baton = RelayCoreFixtures.baton(
            id: RelayCoreFixtures.id(111),
            revision: 1,
            from: RelayCoreFixtures.implementStageID,
            to: RelayCoreFixtures.verifyStageID,
            sourceDigest: RelayCoreFixtures.initialDigest,
            resultDigest: RelayCoreFixtures.changedDigest,
            evidence: [unknown, unknown]
        )

        XCTAssertThrowsError(
            try RelayReducer.reducing(
                state,
                command: .approveAttempt(
                    attemptID,
                    resultCommit: RelayCoreFixtures.initialCommit,
                    resultWorkspaceDigest: RelayCoreFixtures.changedDigest,
                    baton: baton,
                    at: RelayCoreFixtures.later
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? RelayCoreError,
                .invalidBaton("Baton references are duplicated.")
            )
        }
    }

    func testArtifactPathMustBeRelativeContainedAndNonempty() throws {
        var state = try RelayCoreFixtures.running()
        let digest = RelayCoreFixtures.journalDigest
        let unsafe = RelayArtifact(
            id: RelayCoreFixtures.id(112),
            taskID: RelayCoreFixtures.taskID,
            kind: .report,
            classification: .local,
            digest: digest,
            byteCount: 10,
            mediaType: "text/plain",
            relativePath: "../secret",
            createdAt: RelayCoreFixtures.later
        )

        XCTAssertThrowsError(
            try RelayReducer.reducing(state, command: .recordArtifact(unsafe))
        )
        let safe = RelayArtifact(
            id: RelayCoreFixtures.id(113),
            taskID: RelayCoreFixtures.taskID,
            kind: .report,
            classification: .localSensitive,
            digest: digest,
            byteCount: 10,
            mediaType: "text/plain",
            relativePath: "objects/report.txt",
            createdAt: RelayCoreFixtures.later
        )
        state = try RelayReducer.reducing(state, command: .recordArtifact(safe))
        XCTAssertEqual(state.artifacts, [safe])
    }

    func testFindingWaiverRequiresGrantedDecisionScopedToExactFinding() throws {
        var state = try runningTwoStageTask()
        let attemptID: RelayAttemptID = RelayCoreFixtures.id(114)
        state = try RelayCoreFixtures.scheduleAndRun(
            RelayCoreFixtures.attempt(
                id: attemptID,
                stageID: RelayCoreFixtures.implementStageID,
                ordinal: 1,
                digest: RelayCoreFixtures.initialDigest
            ),
            in: state
        )
        let finding = blockingFinding(
            id: RelayCoreFixtures.id(115),
            attemptID: attemptID,
            stageID: RelayCoreFixtures.implementStageID
        )
        state = try RelayReducer.reducing(state, command: .openFinding(finding))
        let decision = RelayDecision(
            id: RelayCoreFixtures.id(116),
            taskID: RelayCoreFixtures.taskID,
            kind: .waiveFinding,
            scope: finding.id.description,
            requestedAt: RelayCoreFixtures.later
        )
        state = try RelayReducer.reducing(state, command: .requestDecision(decision))

        XCTAssertThrowsError(
            try RelayReducer.reducing(
                state,
                command: .waiveFinding(
                    finding.id,
                    decisionID: decision.id,
                    at: RelayCoreFixtures.later
                )
            )
        )
        state = try RelayReducer.reducing(
            state,
            command: .recordDecision(
                decision.id,
                status: .granted,
                rationale: "Accepted by the user.",
                at: RelayCoreFixtures.later
            )
        )
        state = try RelayReducer.reducing(
            state,
            command: .waiveFinding(
                finding.id,
                decisionID: decision.id,
                at: RelayCoreFixtures.later
            )
        )
        XCTAssertEqual(state.finding(finding.id)?.status, .waived)
    }

    func testDeliveryApprovalIsBoundToExactCurrentGitHead() throws {
        var state = RelayProjection(
            task: RelayCoreFixtures.task(),
            status: .localReady,
            taskHeadCommit: RelayCoreFixtures.initialCommit,
            currentWorkspaceDigest: RelayCoreFixtures.changedDigest,
            decisions: [
                RelayDecision(
                    id: RelayCoreFixtures.id(117),
                    taskID: RelayCoreFixtures.taskID,
                    kind: .publishDraftPullRequest,
                    scope: "wrong-head",
                    status: .granted,
                    requestedAt: RelayCoreFixtures.instant,
                    decidedAt: RelayCoreFixtures.later,
                    rationale: "Publish"
                )
            ]
        )
        XCTAssertThrowsError(try RelayReducer.reducing(state, command: .beginDelivery))

        state.decisions[0] = RelayDecision(
            id: state.decisions[0].id,
            taskID: RelayCoreFixtures.taskID,
            kind: .publishDraftPullRequest,
            scope: RelayCoreFixtures.initialCommit.rawValue,
            status: .granted,
            requestedAt: RelayCoreFixtures.instant,
            decidedAt: RelayCoreFixtures.later,
            rationale: "Publish"
        )
        XCTAssertEqual(
            try RelayReducer.reducing(state, command: .beginDelivery).status,
            .delivering
        )
    }
}

private extension RelayReducerAdversarialTests {
    func runningTwoStageTask() throws -> RelayProjection {
        try RelayCoreFixtures.running(
            task: RelayCoreFixtures.task(stages: [
                RelayCoreFixtures.implementStage(),
                RelayCoreFixtures.reviewStage(),
            ])
        )
    }

    func approveFirstImplementation(in input: RelayProjection) throws -> RelayProjection {
        var state = input
        let attemptID: RelayAttemptID = RelayCoreFixtures.id(100)
        state = try RelayCoreFixtures.scheduleAndRun(
            RelayCoreFixtures.attempt(
                id: attemptID,
                stageID: RelayCoreFixtures.implementStageID,
                ordinal: 1,
                digest: RelayCoreFixtures.initialDigest
            ),
            in: state
        )
        return try RelayReducer.reducing(
            state,
            command: .approveAttempt(
                attemptID,
                resultCommit: RelayCoreFixtures.initialCommit,
                resultWorkspaceDigest: RelayCoreFixtures.changedDigest,
                baton: RelayCoreFixtures.baton(
                    id: RelayCoreFixtures.id(99),
                    revision: 1,
                    from: RelayCoreFixtures.implementStageID,
                    to: RelayCoreFixtures.reviewStageID,
                    sourceDigest: RelayCoreFixtures.initialDigest,
                    resultDigest: RelayCoreFixtures.changedDigest
                ),
                at: RelayCoreFixtures.later
            )
        )
    }

    func blockingFinding(
        id: RelayFindingID,
        attemptID: RelayAttemptID,
        stageID: RelayStageID = RelayCoreFixtures.reviewStageID
    ) -> RelayFinding {
        RelayFinding(
            id: id,
            taskID: RelayCoreFixtures.taskID,
            stageID: stageID,
            attemptID: attemptID,
            severity: .p1,
            title: "Stale verification",
            detail: "The evidence does not bind the current workspace snapshot.",
            acceptanceCriteria: ["Verify the exact digest."],
            openedAt: RelayCoreFixtures.later
        )
    }
}
