import RelayCore
import XCTest

final class RelayReducerFlowTests: XCTestCase {
    func testHappyPathRequiresChangedSnapshotVerificationAndIndependentReview() throws {
        let state = try completeRelay(resultDigest: RelayCoreFixtures.changedDigest)
        let gate = RelayLocalReadyGate.evaluate(state)

        XCTAssertTrue(gate.isReady, "Unexpected blockers: \(gate.blockers)")
        let ready = try RelayReducer.reducing(state, command: .markLocalReady)
        XCTAssertEqual(ready.status, .localReady)
        XCTAssertEqual(ready.currentWorkspaceDigest, RelayCoreFixtures.changedDigest)
        XCTAssertNil(ready.activeAttemptID)
    }

    func testUnchangedWorkspaceCannotBecomeLocalReady() throws {
        let state = try completeRelay(resultDigest: RelayCoreFixtures.initialDigest)

        XCTAssertTrue(
            RelayLocalReadyGate.evaluate(state).blockers.contains(.workspaceUnchanged)
        )
        XCTAssertThrowsError(
            try RelayReducer.reducing(state, command: .markLocalReady)
        )
    }

    func testSameGitHeadCannotHideStaleVerificationBytes() throws {
        var state = try afterImplementation()
        let attemptID: RelayAttemptID = RelayCoreFixtures.id(31)
        let attempt = RelayCoreFixtures.attempt(
            id: attemptID,
            stageID: RelayCoreFixtures.verifyStageID,
            ordinal: 1,
            digest: RelayCoreFixtures.changedDigest
        )
        state = try RelayCoreFixtures.scheduleAndRun(attempt, in: state)
        let staleEvidence = RelayCoreFixtures.evidence(
            id: RelayCoreFixtures.id(32),
            attemptID: attemptID,
            stageID: RelayCoreFixtures.verifyStageID,
            kind: .verification,
            digest: RelayCoreFixtures.initialDigest
        )
        state = try RelayReducer.reducing(
            state,
            command: .recordEvidence(staleEvidence)
        )
        let baton = RelayCoreFixtures.baton(
            id: RelayCoreFixtures.id(33),
            revision: 2,
            from: RelayCoreFixtures.verifyStageID,
            to: RelayCoreFixtures.reviewStageID,
            sourceDigest: RelayCoreFixtures.changedDigest,
            resultDigest: RelayCoreFixtures.changedDigest,
            evidence: [staleEvidence.id]
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
        ) { error in
            XCTAssertEqual(
                error as? RelayCoreError,
                .invalidValue("Required Relay-verified evidence is missing.")
            )
        }
    }

    func testVerifierCannotMutateWorkspaceWhileApproving() throws {
        var state = try afterImplementation()
        let attemptID: RelayAttemptID = RelayCoreFixtures.id(34)
        let attempt = RelayCoreFixtures.attempt(
            id: attemptID,
            stageID: RelayCoreFixtures.verifyStageID,
            ordinal: 1,
            digest: RelayCoreFixtures.changedDigest
        )
        state = try RelayCoreFixtures.scheduleAndRun(attempt, in: state)
        let evidence = RelayCoreFixtures.evidence(
            id: RelayCoreFixtures.id(35),
            attemptID: attemptID,
            stageID: RelayCoreFixtures.verifyStageID,
            kind: .verification,
            digest: RelayCoreFixtures.otherDigest
        )
        state = try RelayReducer.reducing(state, command: .recordEvidence(evidence))
        let baton = RelayCoreFixtures.baton(
            id: RelayCoreFixtures.id(36),
            revision: 2,
            from: RelayCoreFixtures.verifyStageID,
            to: RelayCoreFixtures.reviewStageID,
            sourceDigest: RelayCoreFixtures.changedDigest,
            resultDigest: RelayCoreFixtures.otherDigest,
            evidence: [evidence.id]
        )

        XCTAssertThrowsError(
            try RelayReducer.reducing(
                state,
                command: .approveAttempt(
                    attemptID,
                    resultCommit: RelayCoreFixtures.initialCommit,
                    resultWorkspaceDigest: RelayCoreFixtures.otherDigest,
                    baton: baton,
                    at: RelayCoreFixtures.later
                )
            )
        )
    }

    func testAgentClaimCannotSatisfyStageEvidence() throws {
        var state = try afterImplementation()
        let attemptID: RelayAttemptID = RelayCoreFixtures.id(37)
        let attempt = RelayCoreFixtures.attempt(
            id: attemptID,
            stageID: RelayCoreFixtures.verifyStageID,
            ordinal: 1,
            digest: RelayCoreFixtures.changedDigest
        )
        state = try RelayCoreFixtures.scheduleAndRun(attempt, in: state)
        let claim = RelayCoreFixtures.evidence(
            id: RelayCoreFixtures.id(38),
            attemptID: attemptID,
            stageID: RelayCoreFixtures.verifyStageID,
            kind: .verification,
            digest: RelayCoreFixtures.changedDigest,
            trust: .agentClaimed
        )
        state = try RelayReducer.reducing(state, command: .recordEvidence(claim))

        XCTAssertThrowsError(
            try RelayReducer.reducing(
                state,
                command: .approveAttempt(
                    attemptID,
                    resultCommit: RelayCoreFixtures.initialCommit,
                    resultWorkspaceDigest: RelayCoreFixtures.changedDigest,
                    baton: RelayCoreFixtures.baton(
                        id: RelayCoreFixtures.id(39),
                        revision: 2,
                        from: RelayCoreFixtures.verifyStageID,
                        to: RelayCoreFixtures.reviewStageID,
                        sourceDigest: RelayCoreFixtures.changedDigest,
                        resultDigest: RelayCoreFixtures.changedDigest,
                        evidence: [claim.id]
                    ),
                    at: RelayCoreFixtures.later
                )
            )
        )
    }

    func testLocalGateRechecksEvidenceInsteadOfTrustingStageStatus() throws {
        var state = try completeRelay(resultDigest: RelayCoreFixtures.changedDigest)
        state.evidence.removeAll { $0.kind == .independentReview }

        XCTAssertTrue(
            RelayLocalReadyGate.evaluate(state).blockers
                .contains(.exactIndependentReviewMissing)
        )
    }

    func testLocalGateRejectsAnyOpenFindingPendingDecisionAndHiddenInFlightAttempt() throws {
        var state = try completeRelay(resultDigest: RelayCoreFixtures.changedDigest)
        let reviewAttempt = try XCTUnwrap(
            state.attempts.last { $0.stageID == RelayCoreFixtures.reviewStageID }
        )
        let finding = RelayFinding(
            id: RelayCoreFixtures.id(46),
            taskID: RelayCoreFixtures.taskID,
            stageID: RelayCoreFixtures.reviewStageID,
            attemptID: reviewAttempt.id,
            severity: .p3,
            title: "Minor unresolved issue",
            detail: "Even nonblocking findings must be dispositioned before readiness.",
            acceptanceCriteria: ["Resolve or explicitly waive it."],
            openedAt: RelayCoreFixtures.later
        )
        state.findings.append(finding)
        state.decisions.append(
            RelayDecision(
                id: RelayCoreFixtures.id(47),
                taskID: RelayCoreFixtures.taskID,
                kind: .continueAfterBudget,
                scope: "attempt-budget",
                requestedAt: RelayCoreFixtures.later
            )
        )
        state.attempts[state.attempts.count - 1].status = .running

        let blockers = RelayLocalReadyGate.evaluate(state).blockers
        XCTAssertTrue(blockers.contains(.openBlockingFinding(finding.id)))
        XCTAssertTrue(blockers.contains(.pendingDecision(state.decisions.last!.id)))
        XCTAssertTrue(blockers.contains(.inFlightAttempt(reviewAttempt.id)))
    }

    func testLocalGateRequiresAnImplementationAttemptThatProducedCurrentBytes() throws {
        var state = try completeRelay(resultDigest: RelayCoreFixtures.changedDigest)
        state.attempts.removeAll { $0.stageID == RelayCoreFixtures.implementStageID }

        XCTAssertTrue(
            RelayLocalReadyGate.evaluate(state).blockers
                .contains(.exactImplementationDeltaMissing)
        )
    }

    func testLocalGateRequiresCoverageForEveryAcceptanceCriterion() throws {
        var state = try completeRelay(resultDigest: RelayCoreFixtures.changedDigest)
        let existing = try XCTUnwrap(state.task)
        let secondID: RelayAcceptanceCriterionID = RelayCoreFixtures.id(820)
        let second = RelayAcceptanceCriterion(
            id: secondID,
            statement: "The regression path is independently covered.",
            requiredEvidenceKinds: [.verification, .independentReview]
        )
        state.task = RelayTaskDefinition(
            schemaVersion: existing.schemaVersion,
            id: existing.id,
            title: existing.title,
            objective: existing.objective,
            acceptanceCriteria: existing.acceptanceCriteria + [second],
            stages: existing.stages,
            completionPolicy: existing.completionPolicy,
            createdAt: existing.createdAt
        )

        let blockers = RelayLocalReadyGate.evaluate(state).blockers
        XCTAssertTrue(blockers.contains(.criterionEvidenceMissing(secondID, .verification)))
        XCTAssertTrue(
            blockers.contains(.criterionEvidenceMissing(secondID, .independentReview))
        )
    }

    func testCriterionCoverageFailsClosedForStaleClaimedAndFailedEvidence() throws {
        let complete = try completeRelay(resultDigest: RelayCoreFixtures.changedDigest)
        let verifyAttempt = try XCTUnwrap(
            complete.attempts.last { $0.stageID == RelayCoreFixtures.verifyStageID }
        )
        let reviewAttempt = try XCTUnwrap(
            complete.attempts.last { $0.stageID == RelayCoreFixtures.reviewStageID }
        )

        var stale = complete
        stale.evidence.removeAll { $0.kind == .verification }
        stale.evidence.append(
            RelayCoreFixtures.evidence(
                id: RelayCoreFixtures.id(821),
                attemptID: verifyAttempt.id,
                stageID: verifyAttempt.stageID,
                kind: .verification,
                digest: RelayCoreFixtures.initialDigest
            )
        )
        XCTAssertTrue(
            RelayLocalReadyGate.evaluate(stale).blockers.contains(
                .criterionEvidenceMissing(
                    RelayCoreFixtures.criterionID,
                    .verification
                )
            )
        )

        var claimed = complete
        claimed.evidence.removeAll { $0.kind == .independentReview }
        claimed.evidence.append(
            RelayCoreFixtures.evidence(
                id: RelayCoreFixtures.id(822),
                attemptID: reviewAttempt.id,
                stageID: reviewAttempt.stageID,
                kind: .independentReview,
                digest: RelayCoreFixtures.changedDigest,
                trust: .agentClaimed
            )
        )
        XCTAssertTrue(
            RelayLocalReadyGate.evaluate(claimed).blockers.contains(
                .criterionEvidenceUnverified(
                    RelayCoreFixtures.criterionID,
                    .independentReview
                )
            )
        )

        var failed = complete
        failed.evidence.removeAll { $0.kind == .verification }
        failed.evidence.append(
            RelayCoreFixtures.evidence(
                id: RelayCoreFixtures.id(823),
                attemptID: verifyAttempt.id,
                stageID: verifyAttempt.stageID,
                kind: .verification,
                digest: RelayCoreFixtures.changedDigest,
                result: .failed
            )
        )
        XCTAssertTrue(
            RelayLocalReadyGate.evaluate(failed).blockers.contains(
                .criterionEvidenceFailed(
                    RelayCoreFixtures.criterionID,
                    .verification
                )
            )
        )
    }

    func testCompletionEvidenceMustBeRelayVerifiedOnCurrentDigest() throws {
        var state = try completeRelay(
            resultDigest: RelayCoreFixtures.changedDigest,
            completionEvidence: [.tests]
        )
        let reviewAttempt = try XCTUnwrap(
            state.attempts.last { $0.stageID == RelayCoreFixtures.reviewStageID }
        )
        state.evidence.append(
            RelayCoreFixtures.evidence(
                id: RelayCoreFixtures.id(40),
                attemptID: reviewAttempt.id,
                stageID: reviewAttempt.stageID,
                kind: .tests,
                digest: RelayCoreFixtures.changedDigest,
                trust: .agentClaimed
            )
        )

        XCTAssertTrue(
            RelayLocalReadyGate.evaluate(state).blockers
                .contains(.unverifiedEvidence(.tests))
        )
    }

    func testConcurrentAttemptAndStaleSourceDigestAreRejected() throws {
        var state = try RelayCoreFixtures.running()
        let first = RelayCoreFixtures.attempt(
            id: RelayCoreFixtures.id(41),
            stageID: RelayCoreFixtures.implementStageID,
            ordinal: 1,
            digest: RelayCoreFixtures.initialDigest
        )
        state = try RelayReducer.reducing(state, command: .scheduleAttempt(first))
        let concurrent = RelayCoreFixtures.attempt(
            id: RelayCoreFixtures.id(42),
            stageID: RelayCoreFixtures.implementStageID,
            ordinal: 2,
            digest: RelayCoreFixtures.initialDigest
        )
        XCTAssertThrowsError(
            try RelayReducer.reducing(state, command: .scheduleAttempt(concurrent))
        )

        var noActive = try RelayCoreFixtures.running()
        let stale = RelayCoreFixtures.attempt(
            id: RelayCoreFixtures.id(43),
            stageID: RelayCoreFixtures.implementStageID,
            ordinal: 1,
            digest: RelayCoreFixtures.otherDigest
        )
        XCTAssertThrowsError(
            try RelayReducer.reducing(noActive, command: .scheduleAttempt(stale))
        )
        noActive.currentWorkspaceDigest = RelayCoreFixtures.otherDigest
        XCTAssertNoThrow(
            try RelayReducer.reducing(noActive, command: .scheduleAttempt(stale))
        )
    }

    func testCancelledAttemptCannotApproveLater() throws {
        var state = try RelayCoreFixtures.running()
        let attempt = RelayCoreFixtures.attempt(
            id: RelayCoreFixtures.id(44),
            stageID: RelayCoreFixtures.implementStageID,
            ordinal: 1,
            digest: RelayCoreFixtures.initialDigest
        )
        state = try RelayCoreFixtures.scheduleAndRun(attempt, in: state)
        state = try RelayReducer.reducing(
            state,
            command: .requestCancellation(attempt.id, at: RelayCoreFixtures.later)
        )
        state = try RelayReducer.reducing(
            state,
            command: .finishCancellation(attempt.id, at: RelayCoreFixtures.later)
        )

        XCTAssertEqual(state.status, .waitingForUser)
        XCTAssertNil(state.activeAttemptID)
        XCTAssertThrowsError(
            try RelayReducer.reducing(
                state,
                command: .approveAttempt(
                    attempt.id,
                    resultCommit: RelayCoreFixtures.initialCommit,
                    resultWorkspaceDigest: RelayCoreFixtures.changedDigest,
                    baton: RelayCoreFixtures.baton(
                        id: RelayCoreFixtures.id(45),
                        revision: 1,
                        from: RelayCoreFixtures.implementStageID,
                        to: RelayCoreFixtures.verifyStageID,
                        sourceDigest: RelayCoreFixtures.initialDigest,
                        resultDigest: RelayCoreFixtures.changedDigest
                    ),
                    at: RelayCoreFixtures.later
                )
            )
        )
    }

    func testReplayIsDeterministicAndFailedBatchDoesNotMutateInput() throws {
        let task = RelayCoreFixtures.task()
        let events: [RelayEvent] = [
            .taskCreated(task),
            .workspaceProvisioningRequested(RelayCoreFixtures.provisioningIntent()),
            .workspacePrepared(RelayCoreFixtures.workspace()),
            .taskBecameReady,
            .taskStarted(at: RelayCoreFixtures.later),
        ]
        let first = try RelayReducer.replay(events)
        let second = try RelayReducer.replay(events)
        XCTAssertEqual(first, second)

        let before = first
        XCTAssertThrowsError(
            try RelayReducer.apply(
                [.taskWaiting(reason: "pause"), .taskBecameLocalReady],
                to: first
            )
        )
        XCTAssertEqual(first, before)
    }
}

private extension RelayReducerFlowTests {
    func afterImplementation(
        resultDigest: RelayDigest = RelayCoreFixtures.changedDigest,
        completionEvidence: [RelayEvidenceKind] = []
    ) throws -> RelayProjection {
        var state = try RelayCoreFixtures.running(
            task: RelayCoreFixtures.task(completionEvidence: completionEvidence)
        )
        let attemptID: RelayAttemptID = RelayCoreFixtures.id(10)
        let attempt = RelayCoreFixtures.attempt(
            id: attemptID,
            stageID: RelayCoreFixtures.implementStageID,
            ordinal: 1,
            digest: RelayCoreFixtures.initialDigest
        )
        state = try RelayCoreFixtures.scheduleAndRun(attempt, in: state)
        let baton = RelayCoreFixtures.baton(
            id: RelayCoreFixtures.id(11),
            revision: 1,
            from: RelayCoreFixtures.implementStageID,
            to: RelayCoreFixtures.verifyStageID,
            sourceDigest: RelayCoreFixtures.initialDigest,
            resultDigest: resultDigest
        )
        return try RelayReducer.reducing(
            state,
            command: .approveAttempt(
                attemptID,
                resultCommit: RelayCoreFixtures.initialCommit,
                resultWorkspaceDigest: resultDigest,
                baton: baton,
                at: RelayCoreFixtures.later
            )
        )
    }

    func completeRelay(
        resultDigest: RelayDigest,
        completionEvidence: [RelayEvidenceKind] = []
    ) throws -> RelayProjection {
        var state = try afterImplementation(
            resultDigest: resultDigest,
            completionEvidence: completionEvidence
        )

        let verifyID: RelayAttemptID = RelayCoreFixtures.id(12)
        state = try RelayCoreFixtures.scheduleAndRun(
            RelayCoreFixtures.attempt(
                id: verifyID,
                stageID: RelayCoreFixtures.verifyStageID,
                ordinal: 1,
                digest: resultDigest
            ),
            in: state
        )
        let verification = RelayCoreFixtures.evidence(
            id: RelayCoreFixtures.id(13),
            attemptID: verifyID,
            stageID: RelayCoreFixtures.verifyStageID,
            kind: .verification,
            digest: resultDigest
        )
        state = try RelayReducer.reducing(
            state,
            command: .recordEvidence(verification)
        )
        state = try RelayReducer.reducing(
            state,
            command: .approveAttempt(
                verifyID,
                resultCommit: RelayCoreFixtures.initialCommit,
                resultWorkspaceDigest: resultDigest,
                baton: RelayCoreFixtures.baton(
                    id: RelayCoreFixtures.id(14),
                    revision: 2,
                    from: RelayCoreFixtures.verifyStageID,
                    to: RelayCoreFixtures.reviewStageID,
                    sourceDigest: resultDigest,
                    resultDigest: resultDigest,
                    evidence: [verification.id]
                ),
                at: RelayCoreFixtures.later
            )
        )

        let reviewID: RelayAttemptID = RelayCoreFixtures.id(15)
        state = try RelayCoreFixtures.scheduleAndRun(
            RelayCoreFixtures.attempt(
                id: reviewID,
                stageID: RelayCoreFixtures.reviewStageID,
                ordinal: 1,
                digest: resultDigest
            ),
            in: state
        )
        let review = RelayCoreFixtures.evidence(
            id: RelayCoreFixtures.id(16),
            attemptID: reviewID,
            stageID: RelayCoreFixtures.reviewStageID,
            kind: .independentReview,
            digest: resultDigest
        )
        state = try RelayReducer.reducing(state, command: .recordEvidence(review))
        return try RelayReducer.reducing(
            state,
            command: .approveAttempt(
                reviewID,
                resultCommit: RelayCoreFixtures.initialCommit,
                resultWorkspaceDigest: resultDigest,
                baton: RelayCoreFixtures.baton(
                    id: RelayCoreFixtures.id(17),
                    revision: 3,
                    from: RelayCoreFixtures.reviewStageID,
                    to: nil,
                    sourceDigest: resultDigest,
                    resultDigest: resultDigest,
                    evidence: [verification.id, review.id]
                ),
                at: RelayCoreFixtures.later
            )
        )
    }
}
