import RelayCore
import XCTest

final class RelayCriterionEvidenceTests: XCTestCase {
    func testCompatibilityCriterionIDIsStableAndContentSensitive() {
        let taskID = RelayCoreFixtures.taskID
        let first = RelayAcceptanceCriterionID.derived(
            taskID: taskID,
            index: 0,
            statement: "Exact tests pass."
        )

        XCTAssertEqual(
            first,
            .derived(taskID: taskID, index: 0, statement: "Exact tests pass.")
        )
        XCTAssertNotEqual(
            first,
            .derived(taskID: taskID, index: 1, statement: "Exact tests pass.")
        )
        XCTAssertNotEqual(
            first,
            .derived(taskID: taskID, index: 0, statement: "Review passes.")
        )
    }

    func testReadyGateRejectsMalformedCriterionContracts() throws {
        let duplicateID: RelayAcceptanceCriterionID = RelayCoreFixtures.id(800)
        let criteria = [
            RelayAcceptanceCriterion(
                id: duplicateID,
                statement: " ",
                requiredEvidenceKinds: []
            ),
            RelayAcceptanceCriterion(
                id: duplicateID,
                statement: "Must pass twice.",
                requiredEvidenceKinds: [.tests, .tests]
            ),
        ]
        let state = try RelayCoreFixtures.admitted(
            task: RelayCoreFixtures.task(criteria: criteria)
        )
        let blockers = RelayReadyGate.evaluate(state).blockers

        XCTAssertTrue(blockers.contains(.emptyAcceptanceCriterion(0)))
        XCTAssertTrue(blockers.contains(.duplicateAcceptanceCriterionID(duplicateID)))
        XCTAssertTrue(
            blockers.contains(.acceptanceCriterionEvidenceKindsMissing(duplicateID))
        )
        XCTAssertTrue(
            blockers.contains(.duplicateAcceptanceCriterionEvidenceKind(duplicateID))
        )
    }

    func testReducerRejectsUnboundDuplicateUnknownAndWrongKindEvidence() throws {
        var state = try RelayCoreFixtures.running()
        let attemptID: RelayAttemptID = RelayCoreFixtures.id(801)
        state = try RelayCoreFixtures.scheduleAndRun(
            RelayCoreFixtures.attempt(
                id: attemptID,
                stageID: RelayCoreFixtures.implementStageID,
                ordinal: 1,
                digest: RelayCoreFixtures.initialDigest
            ),
            in: state
        )
        let unknown: RelayAcceptanceCriterionID = RelayCoreFixtures.id(802)
        let cases: [RelayEvidence] = [
            evidence(attemptID: attemptID, criterionIDs: []),
            evidence(
                attemptID: attemptID,
                criterionIDs: [RelayCoreFixtures.criterionID, RelayCoreFixtures.criterionID]
            ),
            evidence(attemptID: attemptID, criterionIDs: [unknown]),
            evidence(
                attemptID: attemptID,
                kind: .tests,
                criterionIDs: [RelayCoreFixtures.criterionID]
            ),
        ]

        for value in cases {
            XCTAssertThrowsError(
                try RelayReducer.reducing(state, command: .recordEvidence(value))
            )
        }
    }

    func testOneEvidenceItemMayCoverSeveralExplicitlyBoundCriteria() throws {
        let secondID: RelayAcceptanceCriterionID = RelayCoreFixtures.id(803)
        let criteria = [
            RelayAcceptanceCriterion(
                id: RelayCoreFixtures.criterionID,
                statement: "Primary behavior passes.",
                requiredEvidenceKinds: [.verification]
            ),
            RelayAcceptanceCriterion(
                id: secondID,
                statement: "Regression behavior passes.",
                requiredEvidenceKinds: [.verification]
            ),
        ]
        var state = try RelayCoreFixtures.running(
            task: RelayCoreFixtures.task(criteria: criteria)
        )
        let attemptID: RelayAttemptID = RelayCoreFixtures.id(804)
        state = try RelayCoreFixtures.scheduleAndRun(
            RelayCoreFixtures.attempt(
                id: attemptID,
                stageID: RelayCoreFixtures.implementStageID,
                ordinal: 1,
                digest: RelayCoreFixtures.initialDigest
            ),
            in: state
        )
        let value = evidence(
            attemptID: attemptID,
            criterionIDs: [RelayCoreFixtures.criterionID, secondID]
        )

        XCTAssertNoThrow(
            try RelayReducer.reducing(state, command: .recordEvidence(value))
        )
    }
}

private extension RelayCriterionEvidenceTests {
    func evidence(
        attemptID: RelayAttemptID,
        kind: RelayEvidenceKind = .verification,
        criterionIDs: [RelayAcceptanceCriterionID]
    ) -> RelayEvidence {
        RelayEvidence(
            id: RelayCoreFixtures.id(805),
            taskID: RelayCoreFixtures.taskID,
            stageID: RelayCoreFixtures.implementStageID,
            attemptID: attemptID,
            kind: kind,
            result: .passed,
            trust: .relayVerified,
            workspaceCommit: RelayCoreFixtures.initialCommit,
            workspaceDigest: RelayCoreFixtures.initialDigest,
            criterionIDs: criterionIDs,
            summary: "Exact criterion evidence.",
            recordedAt: RelayCoreFixtures.later
        )
    }
}
