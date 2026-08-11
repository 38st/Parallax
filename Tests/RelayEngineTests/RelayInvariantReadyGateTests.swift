import Foundation
import RelayCore
import XCTest

final class RelayInvariantReadyGateTests: XCTestCase {
    func testAgentClaimedPassCannotSatisfyLocalReadyGate() {
        var projection = localReadyProjection()
        projection.evidence = [
            exactVerificationEvidence(),
            exactReviewEvidence(),
            evidence(
                result: .passed,
                trust: .agentClaimed,
                commit: candidateCommit,
                workspaceDigest: changedDigest
            ),
        ]

        XCTAssertEqual(
            RelayLocalReadyGate.evaluate(projection).blockers,
            [
                .criterionEvidenceUnverified(criterionID, .tests),
                .unverifiedEvidence(.tests),
            ]
        )
    }

    func testStaleVerifiedPassCannotSatisfyLocalReadyGate() {
        var projection = localReadyProjection()
        projection.evidence = [
            exactVerificationEvidence(),
            exactReviewEvidence(),
            evidence(
                result: .passed,
                trust: .relayVerified,
                commit: staleCommit,
                workspaceDigest: changedDigest
            ),
        ]

        XCTAssertEqual(
            RelayLocalReadyGate.evaluate(projection).blockers,
            [.missingEvidence(.tests)]
        )
    }

    func testFailedVerifiedEvidenceCannotBeOutvotedByAgentClaim() {
        var projection = localReadyProjection()
        projection.evidence = [
            exactVerificationEvidence(),
            exactReviewEvidence(),
            evidence(
                result: .failed,
                trust: .relayVerified,
                commit: candidateCommit,
                workspaceDigest: changedDigest
            ),
            evidence(
                id: 2,
                result: .passed,
                trust: .agentClaimed,
                commit: candidateCommit,
                workspaceDigest: changedDigest
            ),
        ]

        XCTAssertEqual(
            RelayLocalReadyGate.evaluate(projection).blockers,
            [
                .criterionEvidenceFailed(criterionID, .tests),
                .failedEvidence(.tests),
            ]
        )
    }

    func testExactRelayVerifiedPassIsReadyOnlyAfterAllOtherGatesClose() {
        var projection = localReadyProjection()
        projection.evidence = [
            exactVerificationEvidence(),
            exactReviewEvidence(),
            evidence(
                result: .passed,
                trust: .relayVerified,
                commit: candidateCommit,
                workspaceDigest: changedDigest
            ),
        ]

        XCTAssertTrue(RelayLocalReadyGate.evaluate(projection).isReady)

        projection.findings = [blockingFinding()]
        XCTAssertEqual(
            RelayLocalReadyGate.evaluate(projection).blockers,
            [.openBlockingFinding(findingID)]
        )
    }

    func testSameHEADWithStaleWorkspaceDigestCannotReachLocalReady() {
        var projection = localReadyProjection()
        projection.evidence = [
            exactVerificationEvidence(workspaceDigest: baselineDigest),
            exactReviewEvidence(workspaceDigest: baselineDigest),
            evidence(
                result: .passed,
                trust: .relayVerified,
                commit: candidateCommit,
                workspaceDigest: baselineDigest
            ),
        ]

        let result = RelayLocalReadyGate.evaluate(projection)
        XCTAssertFalse(result.isReady)
        XCTAssertTrue(result.blockers.contains(.exactVerificationMissing))
        XCTAssertTrue(result.blockers.contains(.exactIndependentReviewMissing))
        XCTAssertTrue(
            result.blockers.contains(
                .criterionEvidenceMissing(criterionID, .tests)
            )
        )
        XCTAssertTrue(result.blockers.contains(.missingEvidence(.tests)))
    }

    func testReadyGateRejectsReviewerWriteAuthority() {
        let unsafeReview = RelayStageDefinition(
            id: reviewStageID,
            name: "Review",
            role: .reviewer,
            authority: .implementer,
            requiredEvidence: [.tests],
            rejectionStageID: implementationStageID
        )
        var projection = admissionProjection()
        projection.task = task(stages: [implementationStage, unsafeReview])

        XCTAssertTrue(
            RelayReadyGate.evaluate(projection).blockers.contains(
                .invalidAuthority(reviewStageID)
            )
        )
    }

    func testReadyGateRejectsDirtyOrMismatchedWorkspace() {
        var dirty = admissionProjection()
        dirty.workspace = workspace(
            isClean: false,
            head: baseCommit,
            workspaceDigest: baselineDigest
        )
        XCTAssertTrue(
            RelayReadyGate.evaluate(dirty).blockers.contains(.workspaceNotClean)
        )

        var mismatched = admissionProjection()
        mismatched.taskHeadCommit = staleCommit
        XCTAssertTrue(
            RelayReadyGate.evaluate(mismatched).blockers.contains(
                .workspaceHeadMismatch
            )
        )

        var digestMismatch = admissionProjection()
        digestMismatch.currentWorkspaceDigest = changedDigest
        XCTAssertTrue(
            RelayReadyGate.evaluate(digestMismatch).blockers.contains(
                .workspaceDigestMismatch
            )
        )
    }

    private var taskID: RelayTaskID { id(RelayTaskID.self, 1) }
    private var implementationStageID: RelayStageID {
        id(RelayStageID.self, 2)
    }
    private var verifierStageID: RelayStageID { id(RelayStageID.self, 3) }
    private var reviewStageID: RelayStageID { id(RelayStageID.self, 4) }
    private var implementationAttemptID: RelayAttemptID {
        id(RelayAttemptID.self, 5)
    }
    private var verifierAttemptID: RelayAttemptID { id(RelayAttemptID.self, 6) }
    private var reviewAttemptID: RelayAttemptID { id(RelayAttemptID.self, 7) }
    private var findingID: RelayFindingID { id(RelayFindingID.self, 8) }
    private var criterionID: RelayAcceptanceCriterionID {
        id(RelayAcceptanceCriterionID.self, 10)
    }

    private var baseCommit: RelayGitOID {
        RelayGitOID(rawValue: String(repeating: "a", count: 40))!
    }

    private var candidateCommit: RelayGitOID {
        RelayGitOID(rawValue: String(repeating: "b", count: 40))!
    }

    private var staleCommit: RelayGitOID {
        RelayGitOID(rawValue: String(repeating: "c", count: 40))!
    }

    private var baselineDigest: RelayDigest {
        RelayDigest(rawValue: String(repeating: "d", count: 64))!
    }

    private var changedDigest: RelayDigest {
        RelayDigest(rawValue: String(repeating: "e", count: 64))!
    }

    private var verifierStage: RelayStageDefinition {
        RelayStageDefinition(
            id: verifierStageID,
            name: "Verify",
            role: .verifier,
            authority: .verifier,
            requiredEvidence: [.verification]
        )
    }

    private var implementationStage: RelayStageDefinition {
        RelayStageDefinition(
            id: implementationStageID,
            name: "Implement",
            role: .implementer,
            authority: .implementer,
            requiredEvidence: [.tests]
        )
    }

    private var reviewStage: RelayStageDefinition {
        RelayStageDefinition(
            id: reviewStageID,
            name: "Review",
            role: .reviewer,
            authority: .reviewer,
            requiredEvidence: [.tests],
            rejectionStageID: implementationStageID
        )
    }

    private func task(
        stages: [RelayStageDefinition]? = nil
    ) -> RelayTaskDefinition {
        RelayTaskDefinition(
            id: taskID,
            title: "Fix the fixture",
            objective: "Produce an independently verified repair.",
            acceptanceCriteria: [
                RelayAcceptanceCriterion(
                    id: criterionID,
                    statement: "Hidden and public tests pass.",
                    requiredEvidenceKinds: [.tests]
                )
            ],
            stages: stages ?? [implementationStage, verifierStage, reviewStage],
            completionPolicy: RelayCompletionPolicy(
                requiredEvidence: [.tests],
                blockingSeverities: [.p0, .p1]
            ),
            createdAt: RelayInstant(rawValue: 1)
        )
    }

    private func admissionProjection() -> RelayProjection {
        RelayProjection(
            task: task(),
            status: .draft,
            workspaceProvisioningIntent: workspaceProvisioningIntent(),
            workspace: workspace(
                isClean: true,
                head: baseCommit,
                workspaceDigest: baselineDigest
            ),
            taskHeadCommit: baseCommit,
            currentWorkspaceDigest: baselineDigest,
            stages: [
                RelayStageState(stageID: implementationStageID),
                RelayStageState(stageID: verifierStageID),
                RelayStageState(stageID: reviewStageID),
            ]
        )
    }

    private func localReadyProjection() -> RelayProjection {
        RelayProjection(
            task: task(),
            status: .running,
            workspaceProvisioningIntent: workspaceProvisioningIntent(),
            workspace: workspace(
                isClean: true,
                head: baseCommit,
                workspaceDigest: baselineDigest
            ),
            taskHeadCommit: candidateCommit,
            currentWorkspaceDigest: changedDigest,
            stages: [
                RelayStageState(
                    stageID: implementationStageID,
                    status: .approved,
                    attemptIDs: [implementationAttemptID]
                ),
                RelayStageState(
                    stageID: verifierStageID,
                    status: .approved,
                    attemptIDs: [verifierAttemptID]
                ),
                RelayStageState(
                    stageID: reviewStageID,
                    status: .approved,
                    attemptIDs: [reviewAttemptID]
                ),
            ],
            attempts: approvedAttempts()
        )
    }

    private func workspace(
        isClean: Bool,
        head: RelayGitOID,
        workspaceDigest: RelayDigest
    ) -> RelayWorkspaceIdentity {
        RelayWorkspaceIdentity(
            taskID: taskID,
            repositoryRootPath: managedWorkspacePath,
            gitCommonDirectoryPath: "/tmp/relay-source/.git",
            repositoryFileIdentity: RelayFileIdentity(deviceID: 1, fileID: 2),
            gitCommonDirectoryFileIdentity: RelayFileIdentity(
                deviceID: 1,
                fileID: 3
            ),
            baseCommit: baseCommit,
            headCommit: head,
            workspaceDigest: workspaceDigest,
            taskReference: "detached/\(taskID.description)",
            isClean: isClean,
            preparedAt: RelayInstant(rawValue: 2)
        )
    }

    private func workspaceProvisioningIntent() -> RelayWorkspaceProvisioningIntent {
        RelayWorkspaceProvisioningIntent(
            id: id(RelayWorkspaceProvisioningIntentID.self, 9),
            taskID: taskID,
            sourceRepositoryRootPath: "/tmp/relay-source",
            sourceRepositoryFileIdentity: RelayFileIdentity(
                deviceID: 1,
                fileID: 1
            ),
            sourceGitDirectoryPath: "/tmp/relay-source/.git",
            sourceGitCommonDirectoryPath: "/tmp/relay-source/.git",
            sourceGitCommonDirectoryFileIdentity: RelayFileIdentity(
                deviceID: 1,
                fileID: 3
            ),
            baselineCommit: baseCommit,
            managedRootPath: "/tmp/relay-managed",
            managedRootFileIdentity: RelayFileIdentity(deviceID: 1, fileID: 4),
            targetWorkspacePath: managedWorkspacePath,
            expectedTaskReference: "detached/\(taskID.description)",
            expectedInitialWorkspaceDigest: baselineDigest,
            requestedAt: RelayInstant(rawValue: 2)
        )
    }

    private var managedWorkspacePath: String {
        "/tmp/relay-managed/\(taskID.description)"
    }

    private func evidence(
        id ordinal: Int = 1,
        result: RelayEvidenceResult,
        trust: RelayEvidenceTrust,
        commit: RelayGitOID,
        workspaceDigest: RelayDigest,
        kind: RelayEvidenceKind = .tests,
        stageID: RelayStageID? = nil,
        attemptID: RelayAttemptID? = nil
    ) -> RelayEvidence {
        guard let identifierOrdinal = UInt8(exactly: 10 + ordinal) else {
            preconditionFailure("fixture evidence ordinal is out of range")
        }
        return RelayEvidence(
            id: id(RelayEvidenceID.self, identifierOrdinal),
            taskID: taskID,
            stageID: stageID ?? verifierStageID,
            attemptID: attemptID ?? verifierAttemptID,
            kind: kind,
            result: result,
            trust: trust,
            workspaceCommit: commit,
            workspaceDigest: workspaceDigest,
            criterionIDs: [criterionID],
            summary: "fixture",
            recordedAt: RelayInstant(rawValue: 3)
        )
    }

    private func exactVerificationEvidence(
        workspaceDigest: RelayDigest? = nil
    ) -> RelayEvidence {
        evidence(
            id: 20,
            result: .passed,
            trust: .relayVerified,
            commit: candidateCommit,
            workspaceDigest: workspaceDigest ?? changedDigest,
            kind: .verification,
            stageID: verifierStageID,
            attemptID: verifierAttemptID
        )
    }

    private func exactReviewEvidence(
        workspaceDigest: RelayDigest? = nil
    ) -> RelayEvidence {
        evidence(
            id: 21,
            result: .passed,
            trust: .relayVerified,
            commit: candidateCommit,
            workspaceDigest: workspaceDigest ?? changedDigest,
            kind: .independentReview,
            stageID: reviewStageID,
            attemptID: reviewAttemptID
        )
    }

    private func approvedAttempts() -> [RelayAttempt] {
        [
            approvedAttempt(
                id: implementationAttemptID,
                stageID: implementationStageID,
                sourceCommit: baseCommit,
                sourceDigest: baselineDigest,
                resultCommit: candidateCommit,
                resultDigest: changedDigest
            ),
            approvedAttempt(
                id: verifierAttemptID,
                stageID: verifierStageID,
                sourceCommit: candidateCommit,
                sourceDigest: changedDigest,
                resultCommit: candidateCommit,
                resultDigest: changedDigest
            ),
            approvedAttempt(
                id: reviewAttemptID,
                stageID: reviewStageID,
                sourceCommit: candidateCommit,
                sourceDigest: changedDigest,
                resultCommit: candidateCommit,
                resultDigest: changedDigest
            ),
        ]
    }

    private func approvedAttempt(
        id: RelayAttemptID,
        stageID: RelayStageID,
        sourceCommit: RelayGitOID,
        sourceDigest: RelayDigest,
        resultCommit: RelayGitOID,
        resultDigest: RelayDigest
    ) -> RelayAttempt {
        RelayAttempt(
            id: id,
            taskID: taskID,
            stageID: stageID,
            ordinal: 1,
            sourceCommit: sourceCommit,
            sourceWorkspaceDigest: sourceDigest,
            resultCommit: resultCommit,
            resultWorkspaceDigest: resultDigest,
            status: .approved,
            scheduledAt: RelayInstant(rawValue: 1),
            startedAt: RelayInstant(rawValue: 2),
            endedAt: RelayInstant(rawValue: 3)
        )
    }

    private func blockingFinding() -> RelayFinding {
        RelayFinding(
            id: findingID,
            taskID: taskID,
            stageID: reviewStageID,
            attemptID: reviewAttemptID,
            severity: .p1,
            title: "Hidden acceptance failed",
            detail: "The candidate does not meet the hidden semantic oracle.",
            acceptanceCriteria: ["Hidden oracle passes."],
            openedAt: RelayInstant(rawValue: 4)
        )
    }

    private func id<Tag>(
        _ type: RelayID<Tag>.Type,
        _ ordinal: UInt8
    ) -> RelayID<Tag> where Tag: Sendable {
        let suffix = String(format: "%012x", ordinal)
        return RelayID<Tag>(
            UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
        )
    }
}
