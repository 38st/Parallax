import Foundation

public enum RelayCoreError: Error, Equatable, Sendable {
    case taskAlreadyExists
    case taskMissing
    case invalidTaskStatus(expected: String, actual: RelayTaskStatus)
    case invalidStageStatus(RelayStageID, expected: String, actual: RelayStageStatus)
    case invalidAttemptStatus(
        RelayAttemptID,
        expected: String,
        actual: RelayAttemptStatus
    )
    case taskIdentityMismatch
    case stageIdentityMismatch
    case attemptIdentityMismatch
    case duplicateIdentifier(String)
    case unknownStage(RelayStageID)
    case unknownAttempt(RelayAttemptID)
    case unknownFinding(RelayFindingID)
    case unknownDecision(RelayDecisionID)
    case unknownArtifact(RelayArtifactID)
    case activeAttemptMismatch
    case noActiveAttempt
    case invalidValue(String)
    case invalidBaton(String)
    case rejectionUnavailable(RelayStageID)
    case rejectionBudgetExhausted(RelayStageID)
    case blockingFindingRequired
    case readyBlocked([RelayReadyBlocker])
    case localReadyBlocked([RelayLocalReadyBlocker])
}

public enum RelayReducer {
    public static func events(
        for command: RelayCommand,
        applyingTo projection: RelayProjection
    ) throws -> [RelayEvent] {
        let candidate: [RelayEvent]
        switch command {
        case .createTask(let task):
            candidate = [.taskCreated(task)]
        case .requestWorkspaceProvisioning(let intent):
            candidate = [.workspaceProvisioningRequested(intent)]
        case .recordWorkspacePrepared(let workspace):
            candidate = [.workspacePrepared(workspace)]
        case .declareReady:
            candidate = [.taskBecameReady]
        case .start(let instant):
            candidate = [.taskStarted(at: instant)]
        case .scheduleAttempt(let attempt):
            candidate = [.attemptScheduled(attempt)]
        case .markAttemptStarting(let id, let instant):
            candidate = [.attemptStarting(id, at: instant)]
        case .markAttemptRunning(let id, let instant):
            candidate = [.attemptRunning(id, at: instant)]
        case .beginAttemptValidation(let id, let instant):
            candidate = [.attemptValidationStarted(id, at: instant)]
        case .recordArtifact(let artifact):
            candidate = [.artifactRecorded(artifact)]
        case .recordEvidence(let evidence):
            candidate = [.evidenceRecorded(evidence)]
        case .openFinding(let finding):
            candidate = [.findingOpened(finding)]
        case .resolveFinding(let id, let resolution, let instant):
            candidate = [.findingResolved(id, resolution: resolution, at: instant)]
        case .waiveFinding(let findingID, let decisionID, let instant):
            candidate = [
                .findingWaived(findingID, decisionID: decisionID, at: instant)
            ]
        case .requestDecision(let decision):
            candidate = [.decisionRequested(decision)]
        case .recordDecision(let id, let status, let rationale, let instant):
            candidate = [
                .decisionRecorded(id, status: status, rationale: rationale, at: instant)
            ]
        case .approveAttempt(
            let id,
            let commit,
            let workspaceDigest,
            let baton,
            let instant
        ):
            candidate = [
                .attemptApproved(
                    id,
                    resultCommit: commit,
                    resultWorkspaceDigest: workspaceDigest,
                    baton: baton,
                    at: instant
                )
            ]
        case .rejectAttempt(let id, let baton, let instant):
            candidate = [.attemptRejected(id, baton: baton, at: instant)]
        case .failAttempt(let id, let reason, let instant):
            candidate = [
                .attemptFailed(id, reason: reason, at: instant),
                .taskWaiting(reason: reason),
            ]
        case .interruptAttempt(let id, let reason, let instant):
            candidate = [
                .attemptInterrupted(id, reason: reason, at: instant),
                .taskWaiting(reason: reason),
            ]
        case .requestCancellation(let id, let instant):
            candidate = [.cancellationRequested(id, at: instant)]
        case .finishCancellation(let id, let instant):
            candidate = [
                .attemptCancelled(id, at: instant),
                .taskWaiting(reason: "The attempt was cancelled."),
            ]
        case .waitForUser(let reason):
            candidate = [.taskWaiting(reason: reason)]
        case .resume:
            candidate = [.taskResumed]
        case .markLocalReady:
            candidate = [.taskBecameLocalReady]
        case .beginDelivery:
            candidate = [.deliveryStarted]
        case .markDelivered:
            candidate = [.taskDelivered]
        case .failTask(let reason):
            candidate = [.taskFailed(reason: reason)]
        case .cancelTask(let reason):
            candidate = [.taskCancelled(reason: reason)]
        }

        _ = try apply(candidate, to: projection)
        return candidate
    }

    public static func reducing(
        _ projection: RelayProjection,
        command: RelayCommand
    ) throws -> RelayProjection {
        try apply(events(for: command, applyingTo: projection), to: projection)
    }

    public static func apply(
        _ events: [RelayEvent],
        to projection: RelayProjection = .empty
    ) throws -> RelayProjection {
        var result = projection
        for event in events {
            try apply(event, to: &result)
        }
        return result
    }

    public static func replay(_ events: [RelayEvent]) throws -> RelayProjection {
        try apply(events, to: .empty)
    }
}

private extension RelayReducer {
    static func apply(_ event: RelayEvent, to state: inout RelayProjection) throws {
        switch event {
        case .taskCreated(let task):
            guard state.task == nil else { throw RelayCoreError.taskAlreadyExists }
            state.task = task
            state.status = .draft
            state.stages = task.stages.map { RelayStageState(stageID: $0.id) }
            state.currentStageID = task.stages.first?.id

        case .workspaceProvisioningRequested(let intent):
            let task = try requireTask(state)
            try requireStatus(state, .draft)
            guard state.workspaceProvisioningIntent == nil,
                  state.workspace == nil
            else {
                throw RelayCoreError.invalidValue(
                    "Workspace provisioning authority is immutable."
                )
            }
            guard intent.taskID == task.id else {
                throw RelayCoreError.taskIdentityMismatch
            }
            guard intent.isStructurallyValid else {
                throw RelayCoreError.invalidValue(
                    "Workspace provisioning authority is malformed."
                )
            }
            state.workspaceProvisioningIntent = intent

        case .workspacePrepared(let workspace):
            let task = try requireTask(state)
            try requireStatus(state, .draft)
            guard let intent = state.workspaceProvisioningIntent else {
                throw RelayCoreError.invalidValue(
                    "Workspace provisioning was not durably requested."
                )
            }
            guard workspace.taskID == task.id else {
                throw RelayCoreError.taskIdentityMismatch
            }
            guard state.workspace == nil else {
                throw RelayCoreError.invalidValue("Workspace identity is immutable.")
            }
            guard intent.matchesPreparedWorkspace(workspace) else {
                throw RelayCoreError.invalidValue(
                    "Prepared workspace does not match its durable authority."
                )
            }
            state.workspace = workspace
            state.taskHeadCommit = workspace.headCommit
            state.currentWorkspaceDigest = workspace.workspaceDigest

        case .taskBecameReady:
            let gate = RelayReadyGate.evaluate(state)
            guard gate.isReady else { throw RelayCoreError.readyBlocked(gate.blockers) }
            state.status = .ready

        case .taskStarted:
            try requireStatus(state, .ready)
            state.status = .running
            state.currentStageID = state.task?.stages.first?.id

        case .attemptScheduled(let attempt):
            let task = try requireTask(state)
            try requireStatus(state, .running)
            guard state.activeAttemptID == nil else {
                throw RelayCoreError.noActiveAttempt
            }
            guard attempt.taskID == task.id else {
                throw RelayCoreError.taskIdentityMismatch
            }
            guard attempt.stageID == state.currentStageID else {
                throw RelayCoreError.stageIdentityMismatch
            }
            guard attempt.status == .scheduled,
                  attempt.resultCommit == nil,
                  attempt.resultWorkspaceDigest == nil,
                  attempt.startedAt == nil,
                  attempt.endedAt == nil,
                  attempt.failureReason == nil
            else { throw RelayCoreError.invalidValue("Attempt must be newly scheduled.") }
            guard attempt.sourceCommit == state.taskHeadCommit else {
                throw RelayCoreError.invalidValue("Attempt source is not the task head.")
            }
            guard attempt.sourceWorkspaceDigest == state.currentWorkspaceDigest else {
                throw RelayCoreError.invalidValue(
                    "Attempt source is not the current workspace snapshot."
                )
            }
            guard !state.attempts.contains(where: { $0.id == attempt.id }) else {
                throw RelayCoreError.duplicateIdentifier(attempt.id.description)
            }
            guard let stageIndex = state.stageIndex(attempt.stageID) else {
                throw RelayCoreError.unknownStage(attempt.stageID)
            }
            let stage = state.stages[stageIndex]
            guard stage.status == .pending || stage.status == .rejected else {
                throw RelayCoreError.invalidStageStatus(
                    stage.stageID,
                    expected: "pending or rejected",
                    actual: stage.status
                )
            }
            guard attempt.ordinal == stage.attemptIDs.count + 1 else {
                throw RelayCoreError.invalidValue("Attempt ordinal is not contiguous.")
            }
            state.attempts.append(attempt)
            state.stages[stageIndex].attemptIDs.append(attempt.id)
            state.stages[stageIndex].status = .running
            state.activeAttemptID = attempt.id

        case .attemptStarting(let id, let instant):
            let index = try activeAttemptIndex(id, in: state)
            try requireAttemptStatus(state.attempts[index], .scheduled)
            state.attempts[index].status = .starting
            state.attempts[index].startedAt = instant

        case .attemptRunning(let id, let instant):
            let index = try activeAttemptIndex(id, in: state)
            let attempt = state.attempts[index]
            guard attempt.status == .starting || attempt.status == .scheduled else {
                throw RelayCoreError.invalidAttemptStatus(
                    id,
                    expected: "scheduled or starting",
                    actual: attempt.status
                )
            }
            state.attempts[index].status = .running
            if state.attempts[index].startedAt == nil {
                state.attempts[index].startedAt = instant
            }

        case .attemptValidationStarted(let id, _):
            let index = try activeAttemptIndex(id, in: state)
            try requireAttemptStatus(state.attempts[index], .running)
            state.attempts[index].status = .validating

        case .artifactRecorded(let artifact):
            let task = try requireTask(state)
            guard artifact.taskID == task.id else {
                throw RelayCoreError.taskIdentityMismatch
            }
            guard !state.artifacts.contains(where: { $0.id == artifact.id }) else {
                throw RelayCoreError.duplicateIdentifier(artifact.id.description)
            }
            try validateArtifact(artifact, state: state)
            state.artifacts.append(artifact)

        case .evidenceRecorded(let evidence):
            let task = try requireTask(state)
            guard evidence.taskID == task.id else {
                throw RelayCoreError.taskIdentityMismatch
            }
            guard !state.evidence.contains(where: { $0.id == evidence.id }) else {
                throw RelayCoreError.duplicateIdentifier(evidence.id.description)
            }
            try validateEvidence(evidence, state: state)
            state.evidence.append(evidence)

        case .findingOpened(let finding):
            let task = try requireTask(state)
            guard finding.taskID == task.id else {
                throw RelayCoreError.taskIdentityMismatch
            }
            guard !state.findings.contains(where: { $0.id == finding.id }) else {
                throw RelayCoreError.duplicateIdentifier(finding.id.description)
            }
            try validateFinding(finding, state: state)
            state.findings.append(finding)

        case .findingResolved(let id, let resolution, let instant):
            guard let index = state.findingIndex(id) else {
                throw RelayCoreError.unknownFinding(id)
            }
            guard state.findings[index].status == .open else {
                throw RelayCoreError.invalidValue("Only an open finding can be resolved.")
            }
            guard !resolution.relayCoreTrimmed.isEmpty else {
                throw RelayCoreError.invalidValue("Finding resolution is empty.")
            }
            state.findings[index].status = .resolved
            state.findings[index].resolution = resolution
            state.findings[index].closedAt = instant

        case .findingWaived(let findingID, let decisionID, let instant):
            guard let findingIndex = state.findingIndex(findingID) else {
                throw RelayCoreError.unknownFinding(findingID)
            }
            guard let decision = state.decisions.first(where: { $0.id == decisionID }) else {
                throw RelayCoreError.unknownDecision(decisionID)
            }
            guard state.findings[findingIndex].status == .open,
                  decision.kind == .waiveFinding,
                  decision.status == .granted,
                  decision.scope == findingID.description
            else { throw RelayCoreError.invalidValue("Finding waiver is not authorized.") }
            state.findings[findingIndex].status = .waived
            state.findings[findingIndex].resolution = decision.rationale
            state.findings[findingIndex].closedAt = instant

        case .decisionRequested(let decision):
            let task = try requireTask(state)
            guard decision.taskID == task.id else {
                throw RelayCoreError.taskIdentityMismatch
            }
            guard state.status == .running || state.status == .waitingForUser else {
                throw RelayCoreError.invalidTaskStatus(
                    expected: "running or waitingForUser",
                    actual: state.status
                )
            }
            guard decision.status == .requested,
                  !decision.scope.relayCoreTrimmed.isEmpty,
                  decision.decidedAt == nil,
                  decision.rationale == nil
            else { throw RelayCoreError.invalidValue("Decision request is malformed.") }
            guard !state.decisions.contains(where: { $0.id == decision.id }) else {
                throw RelayCoreError.duplicateIdentifier(decision.id.description)
            }
            state.decisions.append(decision)
            state.status = .waitingForUser
            state.waitingReason = "A decision is required."

        case .decisionRecorded(let id, let status, let rationale, let instant):
            guard let index = state.decisionIndex(id) else {
                throw RelayCoreError.unknownDecision(id)
            }
            guard state.decisions[index].status == .requested,
                  status != .requested,
                  !rationale.relayCoreTrimmed.isEmpty
            else { throw RelayCoreError.invalidValue("Decision outcome is malformed.") }
            state.decisions[index].status = status
            state.decisions[index].rationale = rationale
            state.decisions[index].decidedAt = instant

        case .attemptApproved(
            let id,
            let resultCommit,
            let resultWorkspaceDigest,
            let baton,
            let instant
        ):
            let attemptIndex = try activeAttemptIndex(id, in: state)
            let attempt = state.attempts[attemptIndex]
            try requireCompletableAttempt(attempt)
            let stage = try stageDefinition(attempt.stageID, in: state)
            let nextStageID = state.nextStageID(after: attempt.stageID)
            try validateApproval(
                attempt: attempt,
                stage: stage,
                resultCommit: resultCommit,
                resultWorkspaceDigest: resultWorkspaceDigest,
                baton: baton,
                expectedNextStageID: nextStageID,
                state: state
            )
            state.attempts[attemptIndex].status = .approved
            state.attempts[attemptIndex].resultCommit = resultCommit
            state.attempts[attemptIndex].resultWorkspaceDigest = resultWorkspaceDigest
            state.attempts[attemptIndex].endedAt = instant
            let stageIndex = try requiredStageIndex(attempt.stageID, in: state)
            state.stages[stageIndex].status = .approved
            state.activeAttemptID = nil
            state.currentStageID = nextStageID
            state.currentBaton = baton
            state.taskHeadCommit = resultCommit
            state.currentWorkspaceDigest = resultWorkspaceDigest

        case .attemptRejected(let id, let baton, let instant):
            let attemptIndex = try activeAttemptIndex(id, in: state)
            let attempt = state.attempts[attemptIndex]
            try requireCompletableAttempt(attempt)
            let stage = try stageDefinition(attempt.stageID, in: state)
            guard let target = stage.rejectionStageID else {
                throw RelayCoreError.rejectionUnavailable(stage.id)
            }
            let stageIndex = try requiredStageIndex(stage.id, in: state)
            guard state.stages[stageIndex].rejectionCount
                < stage.maximumRejectionCycles
            else { throw RelayCoreError.rejectionBudgetExhausted(stage.id) }
            let blocking = Set(try requireTask(state).completionPolicy.blockingSeverities)
            guard state.findings.contains(where: {
                $0.attemptID == id && $0.status == .open && blocking.contains($0.severity)
            }) else { throw RelayCoreError.blockingFindingRequired }
            try validateBaton(
                baton,
                attempt: attempt,
                resultCommit: baton.resultCommit,
                resultWorkspaceDigest: baton.resultWorkspaceDigest,
                expectedTarget: target,
                state: state
            )
            if stage.role != .implementer {
                guard baton.resultCommit == attempt.sourceCommit,
                      baton.resultWorkspaceDigest == attempt.sourceWorkspaceDigest
                else {
                    throw RelayCoreError.invalidBaton(
                        "A non-implementation stage changed the workspace."
                    )
                }
            }
            state.attempts[attemptIndex].status = .rejected
            state.attempts[attemptIndex].resultCommit = baton.resultCommit
            state.attempts[attemptIndex].resultWorkspaceDigest =
                baton.resultWorkspaceDigest
            state.attempts[attemptIndex].endedAt = instant
            state.stages[stageIndex].rejectionCount += 1
            let targetIndex = try requiredStageIndex(target, in: state)
            for index in targetIndex..<state.stages.count {
                state.stages[index].status = .pending
            }
            state.activeAttemptID = nil
            state.currentStageID = target
            state.currentBaton = baton
            state.taskHeadCommit = baton.resultCommit
            state.currentWorkspaceDigest = baton.resultWorkspaceDigest

        case .attemptFailed(let id, let reason, let instant):
            try finishAttempt(
                id,
                status: .failed,
                reason: reason,
                at: instant,
                state: &state
            )

        case .attemptInterrupted(let id, let reason, let instant):
            try finishAttempt(
                id,
                status: .interrupted,
                reason: reason,
                at: instant,
                state: &state
            )

        case .cancellationRequested(let id, _):
            let index = try activeAttemptIndex(id, in: state)
            guard [.scheduled, .starting, .running, .validating]
                .contains(state.attempts[index].status)
            else {
                throw RelayCoreError.invalidAttemptStatus(
                    id,
                    expected: "active",
                    actual: state.attempts[index].status
                )
            }
            state.attempts[index].status = .cancelling

        case .attemptCancelled(let id, let instant):
            let index = try activeAttemptIndex(id, in: state)
            try requireAttemptStatus(state.attempts[index], .cancelling)
            state.attempts[index].status = .cancelled
            state.attempts[index].endedAt = instant
            let stageIndex = try requiredStageIndex(
                state.attempts[index].stageID,
                in: state
            )
            state.stages[stageIndex].status = .pending
            state.activeAttemptID = nil

        case .taskWaiting(let reason):
            guard state.status == .running || state.status == .waitingForUser else {
                throw RelayCoreError.invalidTaskStatus(
                    expected: "running or waitingForUser",
                    actual: state.status
                )
            }
            guard !reason.relayCoreTrimmed.isEmpty else {
                throw RelayCoreError.invalidValue("Waiting reason is empty.")
            }
            state.status = .waitingForUser
            state.waitingReason = reason

        case .taskResumed:
            try requireStatus(state, .waitingForUser)
            guard state.activeAttemptID == nil,
                  !state.decisions.contains(where: { $0.status == .requested })
            else { throw RelayCoreError.invalidValue("The task is still blocked.") }
            state.status = .running
            state.waitingReason = nil

        case .taskBecameLocalReady:
            let gate = RelayLocalReadyGate.evaluate(state)
            guard gate.isReady else {
                throw RelayCoreError.localReadyBlocked(gate.blockers)
            }
            state.status = .localReady

        case .deliveryStarted:
            try requireStatus(state, .localReady)
            guard let head = state.taskHeadCommit,
                  state.decisions.contains(where: {
                      $0.kind == .publishDraftPullRequest
                          && $0.status == .granted
                          && $0.scope == head.rawValue
                  }) else {
                throw RelayCoreError.invalidValue("Draft publication is not authorized.")
            }
            state.status = .delivering

        case .taskDelivered:
            try requireStatus(state, .delivering)
            state.status = .delivered

        case .taskFailed(let reason):
            guard !state.status.isTerminal else {
                throw RelayCoreError.invalidTaskStatus(
                    expected: "nonterminal",
                    actual: state.status
                )
            }
            guard state.activeAttemptID == nil,
                  !reason.relayCoreTrimmed.isEmpty
            else { throw RelayCoreError.invalidValue("Task failure is unsafe or empty.") }
            state.status = .failed
            state.failureReason = reason

        case .taskCancelled(let reason):
            guard !state.status.isTerminal else {
                throw RelayCoreError.invalidTaskStatus(
                    expected: "nonterminal",
                    actual: state.status
                )
            }
            guard state.activeAttemptID == nil,
                  !reason.relayCoreTrimmed.isEmpty
            else { throw RelayCoreError.invalidValue("Task cancellation is unsafe or empty.") }
            state.status = .cancelled
            state.failureReason = reason
        }
    }
}

private extension RelayReducer {
    static func requireTask(_ state: RelayProjection) throws -> RelayTaskDefinition {
        guard let task = state.task else { throw RelayCoreError.taskMissing }
        return task
    }

    static func requireStatus(
        _ state: RelayProjection,
        _ expected: RelayTaskStatus
    ) throws {
        guard state.status == expected else {
            throw RelayCoreError.invalidTaskStatus(
                expected: expected.rawValue,
                actual: state.status
            )
        }
    }

    static func requireAttemptStatus(
        _ attempt: RelayAttempt,
        _ expected: RelayAttemptStatus
    ) throws {
        guard attempt.status == expected else {
            throw RelayCoreError.invalidAttemptStatus(
                attempt.id,
                expected: expected.rawValue,
                actual: attempt.status
            )
        }
    }

    static func requireCompletableAttempt(_ attempt: RelayAttempt) throws {
        guard attempt.status == .running || attempt.status == .validating else {
            throw RelayCoreError.invalidAttemptStatus(
                attempt.id,
                expected: "running or validating",
                actual: attempt.status
            )
        }
    }

    static func activeAttemptIndex(
        _ id: RelayAttemptID,
        in state: RelayProjection
    ) throws -> Int {
        guard state.activeAttemptID == id else {
            throw RelayCoreError.activeAttemptMismatch
        }
        guard let index = state.attemptIndex(id) else {
            throw RelayCoreError.unknownAttempt(id)
        }
        return index
    }

    static func requiredStageIndex(
        _ id: RelayStageID,
        in state: RelayProjection
    ) throws -> Int {
        guard let index = state.stageIndex(id) else {
            throw RelayCoreError.unknownStage(id)
        }
        return index
    }

    static func stageDefinition(
        _ id: RelayStageID,
        in state: RelayProjection
    ) throws -> RelayStageDefinition {
        guard let stage = state.task?.stages.first(where: { $0.id == id }) else {
            throw RelayCoreError.unknownStage(id)
        }
        return stage
    }

    static func validateArtifact(
        _ artifact: RelayArtifact,
        state: RelayProjection
    ) throws {
        if let attemptID = artifact.attemptID,
           !state.attempts.contains(where: { $0.id == attemptID }) {
            throw RelayCoreError.unknownAttempt(attemptID)
        }
        guard artifact.byteCount > 0,
              !artifact.mediaType.relayCoreTrimmed.isEmpty,
              !artifact.relativePath.relayCoreTrimmed.isEmpty,
              !artifact.relativePath.hasPrefix("/"),
              !artifact.relativePath.split(separator: "/").contains("..")
        else { throw RelayCoreError.invalidValue("Artifact metadata is unsafe.") }
    }

    static func validateEvidence(
        _ evidence: RelayEvidence,
        state: RelayProjection
    ) throws {
        let task = try requireTask(state)
        guard state.activeAttemptID == evidence.attemptID,
              let attempt = state.attempt(evidence.attemptID),
              attempt.stageID == evidence.stageID
        else { throw RelayCoreError.attemptIdentityMismatch }
        guard attempt.status == .running || attempt.status == .validating else {
            throw RelayCoreError.invalidAttemptStatus(
                attempt.id,
                expected: "running or validating",
                actual: attempt.status
            )
        }
        guard !evidence.summary.relayCoreTrimmed.isEmpty else {
            throw RelayCoreError.invalidValue("Evidence summary is empty.")
        }
        guard !evidence.criterionIDs.isEmpty,
              Set(evidence.criterionIDs).count == evidence.criterionIDs.count
        else {
            throw RelayCoreError.invalidValue(
                "Evidence must bind unique acceptance criteria."
            )
        }
        for criterionID in evidence.criterionIDs {
            guard let criterion = task.acceptanceCriteria.first(where: {
                $0.id == criterionID
            }) else {
                throw RelayCoreError.invalidValue(
                    "Evidence references an unknown acceptance criterion."
                )
            }
            guard criterion.requiredEvidenceKinds.contains(evidence.kind) else {
                throw RelayCoreError.invalidValue(
                    "Evidence kind is not authorized for its acceptance criterion."
                )
            }
        }
        if let artifactID = evidence.artifactID,
           state.artifact(artifactID) == nil {
            throw RelayCoreError.unknownArtifact(artifactID)
        }
    }

    static func validateFinding(
        _ finding: RelayFinding,
        state: RelayProjection
    ) throws {
        guard state.activeAttemptID == finding.attemptID,
              let attempt = state.attempt(finding.attemptID),
              attempt.stageID == finding.stageID
        else { throw RelayCoreError.attemptIdentityMismatch }
        guard finding.status == .open,
              finding.resolution == nil,
              finding.closedAt == nil,
              !finding.title.relayCoreTrimmed.isEmpty,
              !finding.detail.relayCoreTrimmed.isEmpty,
              !finding.acceptanceCriteria.isEmpty,
              finding.acceptanceCriteria.allSatisfy({ !$0.relayCoreTrimmed.isEmpty })
        else { throw RelayCoreError.invalidValue("Finding is malformed.") }
    }

    static func validateApproval(
        attempt: RelayAttempt,
        stage: RelayStageDefinition,
        resultCommit: RelayGitOID,
        resultWorkspaceDigest: RelayDigest,
        baton: RelayBaton,
        expectedNextStageID: RelayStageID?,
        state: RelayProjection
    ) throws {
        if stage.role != .implementer {
            guard resultCommit == attempt.sourceCommit,
                  resultWorkspaceDigest == attempt.sourceWorkspaceDigest
            else {
                throw RelayCoreError.invalidBaton(
                    "A non-implementation stage changed the workspace."
                )
            }
        }
        if stage.rejectionStageID != nil {
            let blocking = Set(try requireTask(state).completionPolicy.blockingSeverities)
            guard !state.findings.contains(where: {
                $0.status == .open && blocking.contains($0.severity)
            }) else {
                throw RelayCoreError.invalidBaton("Blocking findings remain open.")
            }
        }
        for requirement in stage.requiredEvidence {
            guard state.evidence.contains(where: {
                $0.stageID == stage.id
                    && $0.attemptID == attempt.id
                    && $0.kind == requirement
                    && $0.result == .passed
                    && $0.trust == .relayVerified
                    && $0.workspaceCommit == resultCommit
                    && $0.workspaceDigest == resultWorkspaceDigest
            }) else {
                throw RelayCoreError.invalidValue(
                    "Required Relay-verified evidence is missing."
                )
            }
        }
        try validateBaton(
            baton,
            attempt: attempt,
            resultCommit: resultCommit,
            resultWorkspaceDigest: resultWorkspaceDigest,
            expectedTarget: expectedNextStageID,
            state: state
        )
    }

    static func validateBaton(
        _ baton: RelayBaton,
        attempt: RelayAttempt,
        resultCommit: RelayGitOID,
        resultWorkspaceDigest: RelayDigest,
        expectedTarget: RelayStageID?,
        state: RelayProjection
    ) throws {
        guard baton.taskID == attempt.taskID,
              baton.fromStageID == attempt.stageID,
              baton.toStageID == expectedTarget,
              baton.sourceCommit == attempt.sourceCommit,
              baton.resultCommit == resultCommit,
              baton.sourceWorkspaceDigest == attempt.sourceWorkspaceDigest,
              baton.resultWorkspaceDigest == resultWorkspaceDigest,
              baton.revision == (state.currentBaton?.revision ?? 0) + 1,
              baton.sourceJournalHead.sequence > 0
        else { throw RelayCoreError.invalidBaton("Baton identity is inconsistent." ) }
        guard Set(baton.findingIDs).count == baton.findingIDs.count,
              Set(baton.evidenceIDs).count == baton.evidenceIDs.count,
              Set(baton.artifactIDs).count == baton.artifactIDs.count
        else { throw RelayCoreError.invalidBaton("Baton references are duplicated.") }
        guard baton.findingIDs.allSatisfy({ state.finding($0) != nil }),
              baton.evidenceIDs.allSatisfy({ state.evidenceItem($0) != nil }),
              baton.artifactIDs.allSatisfy({ state.artifact($0) != nil })
        else { throw RelayCoreError.invalidBaton("Baton references are stale.") }
    }

    static func finishAttempt(
        _ id: RelayAttemptID,
        status: RelayAttemptStatus,
        reason: String,
        at instant: RelayInstant,
        state: inout RelayProjection
    ) throws {
        let attemptIndex = try activeAttemptIndex(id, in: state)
        guard [.scheduled, .starting, .running, .validating]
            .contains(state.attempts[attemptIndex].status),
              !reason.relayCoreTrimmed.isEmpty
        else {
            throw RelayCoreError.invalidAttemptStatus(
                id,
                expected: "active",
                actual: state.attempts[attemptIndex].status
            )
        }
        state.attempts[attemptIndex].status = status
        state.attempts[attemptIndex].failureReason = reason
        state.attempts[attemptIndex].endedAt = instant
        let stageIndex = try requiredStageIndex(
            state.attempts[attemptIndex].stageID,
            in: state
        )
        state.stages[stageIndex].status = .pending
        state.activeAttemptID = nil
    }
}

private extension RelayProjection {
    func stageIndex(_ id: RelayStageID) -> Int? {
        stages.firstIndex { $0.stageID == id }
    }

    func attemptIndex(_ id: RelayAttemptID) -> Int? {
        attempts.firstIndex { $0.id == id }
    }

    func findingIndex(_ id: RelayFindingID) -> Int? {
        findings.firstIndex { $0.id == id }
    }

    func decisionIndex(_ id: RelayDecisionID) -> Int? {
        decisions.firstIndex { $0.id == id }
    }

    func nextStageID(after id: RelayStageID) -> RelayStageID? {
        guard let task, let index = task.stages.firstIndex(where: { $0.id == id })
        else { return nil }
        let next = task.stages.index(after: index)
        return next < task.stages.endIndex ? task.stages[next].id : nil
    }
}

private extension RelayTaskStatus {
    var isTerminal: Bool {
        switch self {
        case .delivered, .failed, .cancelled, .corrupt:
            true
        case .draft, .ready, .running, .waitingForUser, .localReady, .delivering:
            false
        }
    }
}

private extension String {
    var relayCoreTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension RelayWorkspaceProvisioningIntent {
    var isStructurallyValid: Bool {
        let paths = [
            sourceRepositoryRootPath,
            sourceGitDirectoryPath,
            sourceGitCommonDirectoryPath,
            managedRootPath,
            targetWorkspacePath,
        ]
        guard paths.allSatisfy(Self.isCanonicalAbsolutePath),
              managedRootPath != "/",
              sourceRepositoryRootPath != targetWorkspacePath,
              expectedTaskReference == "detached/\(taskID.description)"
        else { return false }

        let expectedTarget = URL(fileURLWithPath: managedRootPath)
            .appendingPathComponent(taskID.description, isDirectory: true)
            .standardizedFileURL.path
        return targetWorkspacePath == expectedTarget
    }

    func matchesPreparedWorkspace(_ workspace: RelayWorkspaceIdentity) -> Bool {
        isStructurallyValid
            && workspace.taskID == taskID
            && workspace.repositoryRootPath == targetWorkspacePath
            && workspace.gitCommonDirectoryPath == sourceGitCommonDirectoryPath
            && workspace.gitCommonDirectoryFileIdentity
                == sourceGitCommonDirectoryFileIdentity
            && workspace.baseCommit == baselineCommit
            && workspace.headCommit == baselineCommit
            && workspace.workspaceDigest == expectedInitialWorkspaceDigest
            && workspace.taskReference == expectedTaskReference
            && workspace.isClean
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              !path.utf8.contains(0),
              path.utf8.count <= 16 * 1_024
        else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path == path
    }
}
