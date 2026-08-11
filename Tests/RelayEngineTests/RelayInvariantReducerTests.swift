import Foundation
import RelayCore
import XCTest

final class RelayInvariantReducerTests: XCTestCase {
    func testCommandDerivationApplicationAndReplayStayEquivalent() throws {
        var projection = RelayProjection.empty
        var acceptedEvents: [RelayEvent] = []
        let commands = validLifecycleCommands()

        for command in commands {
            let events = try RelayReducer.events(
                for: command,
                applyingTo: projection
            )
            let reduced = try RelayReducer.reducing(projection, command: command)
            let applied = try RelayReducer.apply(events, to: projection)
            XCTAssertEqual(reduced, applied)
            projection = applied
            acceptedEvents.append(contentsOf: events)
            XCTAssertEqual(try RelayReducer.replay(acceptedEvents), projection)
        }

        XCTAssertEqual(projection.status, .localReady)
        XCTAssertNil(projection.activeAttemptID)
        XCTAssertEqual(
            projection.stages.map(\.status),
            [.approved, .approved, .approved]
        )
    }

    func testGeneratedValidEventPrefixesAreDeterministic() throws {
        var projection = RelayProjection.empty
        var events: [RelayEvent] = []
        var prefixes: [[RelayEvent]] = []
        for command in validLifecycleCommands() {
            let next = try RelayReducer.events(for: command, applyingTo: projection)
            projection = try RelayReducer.apply(next, to: projection)
            events.append(contentsOf: next)
            prefixes.append(events)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let harness = RelayInvariantHarness<RelayProjection, RelayEvent>(
            initialState: .empty,
            reduce: { state, event in
                try RelayReducer.apply([event], to: state)
            },
            fingerprint: { try encoder.encode($0) },
            rules: [
                { state in
                    state.activeAttemptID != nil
                        && state.attempt(state.activeAttemptID!) == nil
                        ? "active attempt is absent from projection"
                        : nil
                },
                { state in
                    Set(state.attempts.map(\.id)).count == state.attempts.count
                        ? nil
                        : "attempt identifiers are duplicated"
                },
            ]
        )

        XCTAssertEqual(harness.verify(sequences: prefixes), [])
    }

    func testTerminalProjectionCannotBeReopenedByAnotherCommand() throws {
        var projection = RelayProjection.empty
        projection = try RelayReducer.reducing(
            projection,
            command: .createTask(task())
        )
        projection = try RelayReducer.reducing(
            projection,
            command: .failTask(reason: "fixture terminal failure")
        )

        XCTAssertThrowsError(
            try RelayReducer.reducing(
                projection,
                command: .cancelTask(reason: "must not rewrite terminal state")
            )
        ) { error in
            XCTAssertEqual(
                error as? RelayCoreError,
                .invalidTaskStatus(expected: "nonterminal", actual: .failed)
            )
        }
        XCTAssertEqual(projection.status, .failed)
        XCTAssertEqual(projection.failureReason, "fixture terminal failure")
    }

    func testDeliveryCannotStartFromLocalReadyWithoutExplicitDecision() throws {
        let localReady = try validLifecycleCommands().reduce(
            RelayProjection.empty
        ) { projection, command in
            try RelayReducer.reducing(projection, command: command)
        }

        XCTAssertThrowsError(
            try RelayReducer.reducing(localReady, command: .beginDelivery)
        ) { error in
            XCTAssertEqual(
                error as? RelayCoreError,
                .invalidValue("Draft publication is not authorized.")
            )
        }
    }

    private func validLifecycleCommands() -> [RelayCommand] {
        let implementation = attempt(
            id: implementationAttemptID,
            stageID: implementationStageID,
            sourceCommit: baseCommit,
            sourceDigest: baselineDigest,
            scheduledAt: 5
        )
        let verification = attempt(
            id: verificationAttemptID,
            stageID: verificationStageID,
            sourceCommit: resultCommit,
            sourceDigest: changedDigest,
            scheduledAt: 10
        )
        let review = attempt(
            id: reviewAttemptID,
            stageID: reviewStageID,
            sourceCommit: resultCommit,
            sourceDigest: changedDigest,
            scheduledAt: 15
        )
        let verificationEvidence = evidence(
            id: verificationEvidenceID,
            stageID: verificationStageID,
            attemptID: verificationAttemptID,
            kind: .verification,
            recordedAt: 12
        )
        let reviewEvidence = evidence(
            id: reviewEvidenceID,
            stageID: reviewStageID,
            attemptID: reviewAttemptID,
            kind: .independentReview,
            recordedAt: 17
        )
        return [
            .createTask(task()),
            .requestWorkspaceProvisioning(workspaceProvisioningIntent()),
            .recordWorkspacePrepared(workspace()),
            .declareReady,
            .start(at: RelayInstant(rawValue: 3)),
            .scheduleAttempt(implementation),
            .markAttemptRunning(
                implementationAttemptID,
                at: RelayInstant(rawValue: 6)
            ),
            .approveAttempt(
                implementationAttemptID,
                resultCommit: resultCommit,
                resultWorkspaceDigest: changedDigest,
                baton: baton(
                    id: implementationBatonID,
                    revision: 1,
                    from: implementationStageID,
                    to: verificationStageID,
                    sourceCommit: baseCommit,
                    resultCommit: resultCommit,
                    sourceDigest: baselineDigest,
                    resultDigest: changedDigest,
                    evidenceIDs: [],
                    issuedAt: 8
                ),
                at: RelayInstant(rawValue: 9)
            ),
            .scheduleAttempt(verification),
            .markAttemptRunning(
                verificationAttemptID,
                at: RelayInstant(rawValue: 11)
            ),
            .recordEvidence(verificationEvidence),
            .approveAttempt(
                verificationAttemptID,
                resultCommit: resultCommit,
                resultWorkspaceDigest: changedDigest,
                baton: baton(
                    id: verificationBatonID,
                    revision: 2,
                    from: verificationStageID,
                    to: reviewStageID,
                    sourceCommit: resultCommit,
                    resultCommit: resultCommit,
                    sourceDigest: changedDigest,
                    resultDigest: changedDigest,
                    evidenceIDs: [verificationEvidenceID],
                    issuedAt: 13
                ),
                at: RelayInstant(rawValue: 14)
            ),
            .scheduleAttempt(review),
            .markAttemptRunning(
                reviewAttemptID,
                at: RelayInstant(rawValue: 16)
            ),
            .recordEvidence(reviewEvidence),
            .approveAttempt(
                reviewAttemptID,
                resultCommit: resultCommit,
                resultWorkspaceDigest: changedDigest,
                baton: baton(
                    id: reviewBatonID,
                    revision: 3,
                    from: reviewStageID,
                    to: nil,
                    sourceCommit: resultCommit,
                    resultCommit: resultCommit,
                    sourceDigest: changedDigest,
                    resultDigest: changedDigest,
                    evidenceIDs: [reviewEvidenceID],
                    issuedAt: 18
                ),
                at: RelayInstant(rawValue: 19)
            ),
            .markLocalReady,
        ]
    }

    private func task() -> RelayTaskDefinition {
        RelayTaskDefinition(
            id: taskID,
            title: "Deterministic reducer fixture",
            objective: "Prove the exact Relay event sequence.",
            acceptanceCriteria: [
                RelayAcceptanceCriterion(
                    id: criterionID,
                    statement: "Reducer and replay projections match.",
                    requiredEvidenceKinds: [
                        .verification,
                        .independentReview,
                    ]
                )
            ],
            stages: [
                RelayStageDefinition(
                    id: implementationStageID,
                    name: "Implement",
                    role: .implementer,
                    authority: .implementer
                ),
                RelayStageDefinition(
                    id: verificationStageID,
                    name: "Verify",
                    role: .verifier,
                    authority: .verifier,
                    requiredEvidence: [.verification]
                ),
                RelayStageDefinition(
                    id: reviewStageID,
                    name: "Review",
                    role: .reviewer,
                    authority: .reviewer,
                    requiredEvidence: [.independentReview],
                    rejectionStageID: implementationStageID
                ),
            ],
            createdAt: RelayInstant(rawValue: 1)
        )
    }

    private func workspace() -> RelayWorkspaceIdentity {
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
            headCommit: baseCommit,
            workspaceDigest: baselineDigest,
            taskReference: "detached/\(taskID.description)",
            isClean: true,
            preparedAt: RelayInstant(rawValue: 2)
        )
    }

    private func workspaceProvisioningIntent() -> RelayWorkspaceProvisioningIntent {
        RelayWorkspaceProvisioningIntent(
            id: relayID(13),
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

    private func attempt(
        id: RelayAttemptID,
        stageID: RelayStageID,
        sourceCommit: RelayGitOID,
        sourceDigest: RelayDigest,
        scheduledAt: Int64
    ) -> RelayAttempt {
        RelayAttempt(
            id: id,
            taskID: taskID,
            stageID: stageID,
            ordinal: 1,
            sourceCommit: sourceCommit,
            sourceWorkspaceDigest: sourceDigest,
            scheduledAt: RelayInstant(rawValue: scheduledAt)
        )
    }

    private func evidence(
        id: RelayEvidenceID,
        stageID: RelayStageID,
        attemptID: RelayAttemptID,
        kind: RelayEvidenceKind,
        recordedAt: Int64
    ) -> RelayEvidence {
        RelayEvidence(
            id: id,
            taskID: taskID,
            stageID: stageID,
            attemptID: attemptID,
            kind: kind,
            result: .passed,
            trust: .relayVerified,
            workspaceCommit: resultCommit,
            workspaceDigest: changedDigest,
            criterionIDs: [criterionID],
            summary: "Exact deterministic fixture evidence.",
            recordedAt: RelayInstant(rawValue: recordedAt)
        )
    }

    private func baton(
        id: RelayBatonID,
        revision: UInt64,
        from: RelayStageID,
        to: RelayStageID?,
        sourceCommit: RelayGitOID,
        resultCommit: RelayGitOID,
        sourceDigest: RelayDigest,
        resultDigest: RelayDigest,
        evidenceIDs: [RelayEvidenceID],
        issuedAt: Int64
    ) -> RelayBaton {
        RelayBaton(
            id: id,
            taskID: taskID,
            revision: revision,
            fromStageID: from,
            toStageID: to,
            sourceCommit: sourceCommit,
            resultCommit: resultCommit,
            sourceWorkspaceDigest: sourceDigest,
            resultWorkspaceDigest: resultDigest,
            findingIDs: [],
            evidenceIDs: evidenceIDs,
            artifactIDs: [],
            sourceJournalHead: RelayJournalHead(
                sequence: revision,
                digest: journalDigest
            ),
            issuedAt: RelayInstant(rawValue: issuedAt)
        )
    }

    private var taskID: RelayTaskID { relayID(1) }
    private var implementationStageID: RelayStageID { relayID(2) }
    private var verificationStageID: RelayStageID { relayID(3) }
    private var reviewStageID: RelayStageID { relayID(4) }
    private var implementationAttemptID: RelayAttemptID { relayID(5) }
    private var verificationAttemptID: RelayAttemptID { relayID(6) }
    private var reviewAttemptID: RelayAttemptID { relayID(7) }
    private var implementationBatonID: RelayBatonID { relayID(8) }
    private var verificationBatonID: RelayBatonID { relayID(9) }
    private var reviewBatonID: RelayBatonID { relayID(10) }
    private var verificationEvidenceID: RelayEvidenceID { relayID(11) }
    private var reviewEvidenceID: RelayEvidenceID { relayID(12) }
    private var criterionID: RelayAcceptanceCriterionID { relayID(14) }

    private var baseCommit: RelayGitOID {
        RelayGitOID(rawValue: String(repeating: "a", count: 40))!
    }

    private var resultCommit: RelayGitOID {
        RelayGitOID(rawValue: String(repeating: "b", count: 40))!
    }

    private var baselineDigest: RelayDigest {
        RelayDigest(rawValue: String(repeating: "c", count: 64))!
    }

    private var changedDigest: RelayDigest {
        RelayDigest(rawValue: String(repeating: "d", count: 64))!
    }

    private var journalDigest: RelayDigest {
        RelayDigest(rawValue: String(repeating: "e", count: 64))!
    }

    private func relayID<Tag>(_ ordinal: UInt8) -> RelayID<Tag>
    where Tag: Sendable {
        let suffix = String(format: "%012x", ordinal)
        return RelayID<Tag>(
            UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
        )
    }
}
