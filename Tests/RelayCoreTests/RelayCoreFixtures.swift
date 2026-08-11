import Foundation
import RelayCore

enum RelayCoreFixtures {
    static let instant = RelayInstant(rawValue: 1_000)
    static let later = RelayInstant(rawValue: 2_000)
    static let initialCommit = RelayGitOID(rawValue: String(repeating: "a", count: 40))!
    static let initialDigest = RelayDigest(rawValue: String(repeating: "1", count: 64))!
    static let changedDigest = RelayDigest(rawValue: String(repeating: "2", count: 64))!
    static let otherDigest = RelayDigest(rawValue: String(repeating: "3", count: 64))!
    static let journalDigest = RelayDigest(rawValue: String(repeating: "f", count: 64))!

    static let taskID: RelayTaskID = id(1)
    static let implementStageID: RelayStageID = id(2)
    static let verifyStageID: RelayStageID = id(3)
    static let reviewStageID: RelayStageID = id(4)
    static let intentID: RelayWorkspaceProvisioningIntentID = id(5)
    static let criterionID: RelayAcceptanceCriterionID = id(6)

    static func id<Tag>(_ value: UInt32) -> RelayID<Tag> {
        let encoded = String(format: "00000000-0000-0000-0000-%012x", value)
        return RelayID<Tag>(uuidString: encoded)!
    }

    static func task(
        stages: [RelayStageDefinition]? = nil,
        criteria: [RelayAcceptanceCriterion]? = nil,
        completionEvidence: [RelayEvidenceKind] = []
    ) -> RelayTaskDefinition {
        RelayTaskDefinition(
            id: taskID,
            title: "Harden launch custody",
            objective: "Implement and independently verify the change.",
            acceptanceCriteria: criteria ?? [
                RelayAcceptanceCriterion(
                    id: criterionID,
                    statement: "Warnings-fatal tests pass.",
                    requiredEvidenceKinds: [.verification, .independentReview]
                )
            ],
            stages: stages ?? [implementStage(), verifyStage(), reviewStage()],
            completionPolicy: RelayCompletionPolicy(
                requiredEvidence: completionEvidence
            ),
            createdAt: instant
        )
    }

    static func implementStage() -> RelayStageDefinition {
        RelayStageDefinition(
            id: implementStageID,
            name: "Implement",
            role: .implementer,
            authority: .implementer
        )
    }

    static func verifyStage() -> RelayStageDefinition {
        RelayStageDefinition(
            id: verifyStageID,
            name: "Verify",
            role: .verifier,
            authority: .verifier,
            requiredEvidence: [.verification],
            rejectionStageID: implementStageID
        )
    }

    static func reviewStage(maximumRejectionCycles: Int = 3) -> RelayStageDefinition {
        RelayStageDefinition(
            id: reviewStageID,
            name: "Review",
            role: .reviewer,
            authority: .reviewer,
            requiredEvidence: [.independentReview],
            rejectionStageID: implementStageID,
            maximumRejectionCycles: maximumRejectionCycles
        )
    }

    static func workspace(
        digest: RelayDigest = initialDigest,
        clean: Bool = true,
        taskID: RelayTaskID = taskID
    ) -> RelayWorkspaceIdentity {
        RelayWorkspaceIdentity(
            taskID: taskID,
            repositoryRootPath: "/tmp/relay-managed/\(taskID.description)",
            gitCommonDirectoryPath: "/tmp/source-repository/.git",
            repositoryFileIdentity: RelayFileIdentity(deviceID: 1, fileID: 2),
            gitCommonDirectoryFileIdentity: RelayFileIdentity(deviceID: 1, fileID: 3),
            baseCommit: initialCommit,
            headCommit: initialCommit,
            workspaceDigest: digest,
            taskReference: "detached/\(taskID.description)",
            isClean: clean,
            preparedAt: instant
        )
    }

    static func provisioningIntent(
        taskID: RelayTaskID = taskID,
        targetWorkspacePath: String? = nil,
        initialDigest: RelayDigest = initialDigest
    ) -> RelayWorkspaceProvisioningIntent {
        RelayWorkspaceProvisioningIntent(
            id: intentID,
            taskID: taskID,
            sourceRepositoryRootPath: "/tmp/source-repository",
            sourceRepositoryFileIdentity: RelayFileIdentity(deviceID: 1, fileID: 9),
            sourceGitDirectoryPath: "/tmp/source-repository/.git",
            sourceGitCommonDirectoryPath: "/tmp/source-repository/.git",
            sourceGitCommonDirectoryFileIdentity: RelayFileIdentity(
                deviceID: 1,
                fileID: 3
            ),
            baselineCommit: initialCommit,
            managedRootPath: "/tmp/relay-managed",
            managedRootFileIdentity: RelayFileIdentity(deviceID: 1, fileID: 8),
            targetWorkspacePath: targetWorkspacePath
                ?? "/tmp/relay-managed/\(taskID.description)",
            expectedTaskReference: "detached/\(taskID.description)",
            expectedInitialWorkspaceDigest: initialDigest,
            requestedAt: instant
        )
    }

    static func admitted(
        task: RelayTaskDefinition = task(),
        workspace: RelayWorkspaceIdentity? = nil
    ) throws -> RelayProjection {
        var state = try RelayReducer.reducing(.empty, command: .createTask(task))
        state = try RelayReducer.reducing(
            state,
            command: .requestWorkspaceProvisioning(
                provisioningIntent(taskID: task.id)
            )
        )
        state = try RelayReducer.reducing(
            state,
            command: .recordWorkspacePrepared(workspace ?? self.workspace())
        )
        return state
    }

    static func running(task: RelayTaskDefinition = task()) throws -> RelayProjection {
        var state = try admitted(task: task)
        state = try RelayReducer.reducing(state, command: .declareReady)
        return try RelayReducer.reducing(state, command: .start(at: later))
    }

    static func attempt(
        id: RelayAttemptID,
        stageID: RelayStageID,
        ordinal: Int,
        digest: RelayDigest
    ) -> RelayAttempt {
        RelayAttempt(
            id: id,
            taskID: taskID,
            stageID: stageID,
            ordinal: ordinal,
            sourceCommit: initialCommit,
            sourceWorkspaceDigest: digest,
            scheduledAt: later
        )
    }

    static func baton(
        id: RelayBatonID,
        revision: UInt64,
        from: RelayStageID,
        to: RelayStageID?,
        sourceDigest: RelayDigest,
        resultDigest: RelayDigest,
        findings: [RelayFindingID] = [],
        evidence: [RelayEvidenceID] = [],
        artifacts: [RelayArtifactID] = []
    ) -> RelayBaton {
        RelayBaton(
            id: id,
            taskID: taskID,
            revision: revision,
            fromStageID: from,
            toStageID: to,
            sourceCommit: initialCommit,
            resultCommit: initialCommit,
            sourceWorkspaceDigest: sourceDigest,
            resultWorkspaceDigest: resultDigest,
            findingIDs: findings,
            evidenceIDs: evidence,
            artifactIDs: artifacts,
            sourceJournalHead: RelayJournalHead(sequence: revision, digest: journalDigest),
            issuedAt: later
        )
    }

    static func evidence(
        id: RelayEvidenceID,
        attemptID: RelayAttemptID,
        stageID: RelayStageID,
        kind: RelayEvidenceKind,
        digest: RelayDigest,
        trust: RelayEvidenceTrust = .relayVerified,
        result: RelayEvidenceResult = .passed,
        criterionIDs: [RelayAcceptanceCriterionID] = [criterionID]
    ) -> RelayEvidence {
        RelayEvidence(
            id: id,
            taskID: taskID,
            stageID: stageID,
            attemptID: attemptID,
            kind: kind,
            result: result,
            trust: trust,
            workspaceCommit: initialCommit,
            workspaceDigest: digest,
            criterionIDs: criterionIDs,
            summary: "The exact workspace snapshot passed.",
            recordedAt: later
        )
    }

    static func scheduleAndRun(
        _ attempt: RelayAttempt,
        in state: RelayProjection
    ) throws -> RelayProjection {
        var next = try RelayReducer.reducing(state, command: .scheduleAttempt(attempt))
        next = try RelayReducer.reducing(
            next,
            command: .markAttemptRunning(attempt.id, at: later)
        )
        return next
    }
}
