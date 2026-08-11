import Foundation
import RelayCore

enum RelayPresentationAdapter {
    static func make(_ projection: RelayProjection) -> RelayTaskPresentation? {
        guard let task = projection.task else { return nil }
        let definitions = Dictionary(
            uniqueKeysWithValues: task.stages.map { ($0.id, $0) }
        )
        let attempts = Dictionary(grouping: projection.attempts, by: \.stageID)
        let summary = RelayTaskSummaryPresentation(
            id: task.id.rawValue,
            title: task.title,
            objective: task.objective,
            repositoryName: repositoryName(projection),
            repositoryPath: projection.workspace?.repositoryRootPath ?? "",
            branchName: projection.workspace?.taskReference,
            executionStatus: executionStatus(projection.status),
            deliveryStatus: deliveryStatus(projection.status),
            currentStageLabel: projection.currentStageID.flatMap {
                definitions[$0]?.name
            },
            lastVerifiedAt: nil,
            updatedAt: latestDate(projection)
        )
        let stagePresentations = projection.stages.enumerated().map {
            position, state in
            let definition = definitions[state.stageID]
            return RelayStagePresentation(
                id: state.stageID.rawValue,
                position: position,
                name: definition?.name ?? String(localized: "Unknown Stage"),
                role: roleLabel(definition?.role),
                status: stageStatus(state.status),
                isCurrent: state.stageID == projection.currentStageID,
                attempts: (attempts[state.stageID] ?? []).map(attempt),
                incomingBatonID: projection.currentBaton?.toStageID
                    == state.stageID ? projection.currentBaton?.id.rawValue : nil,
                outgoingBatonID: projection.currentBaton?.fromStageID
                    == state.stageID ? projection.currentBaton?.id.rawValue : nil
            )
        }

        return RelayTaskPresentation(
            summary: summary,
            stages: stagePresentations,
            batons: baton(projection, definitions: definitions),
            findings: projection.findings.map {
                finding($0, definitions: definitions)
            },
            evidence: projection.evidence.map {
                evidence($0, definitions: definitions)
            },
            gates: projection.decisions.map(gate),
            recovery: recovery(projection.status, reason: projection.failureReason),
            completion: completion(projection, task: task)
        )
    }

    private static func repositoryName(_ projection: RelayProjection) -> String {
        guard let path = projection.workspace?.repositoryRootPath else {
            return String(localized: "Repository Not Prepared")
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private static func executionStatus(_ status: RelayTaskStatus)
        -> RelayExecutionStatus
    {
        switch status {
        case .draft: .interrupted
        case .ready: .blocked
        case .running: .recovering
        case .waitingForUser: .needsUser
        case .localReady, .delivered: .completed
        case .delivering: .blocked
        case .failed, .corrupt: .failed
        case .cancelled: .stopped
        }
    }

    private static func deliveryStatus(_ status: RelayTaskStatus)
        -> RelayDeliveryStatus
    {
        switch status {
        case .localReady: .localEvidenceCaptured
        case .delivered: .delivered
        case .delivering: .stateUnknown
        case .draft, .ready, .running, .waitingForUser, .failed, .cancelled,
             .corrupt:
            .noArtifact
        }
    }

    private static func stageStatus(_ status: RelayCore.RelayStageStatus)
        -> RelayStageStatus
    {
        switch status {
        case .pending: .notStarted
        case .running: .running
        case .approved: .approved
        case .rejected: .rejected
        case .blocked: .blocked
        case .skipped: .skipped
        }
    }

    private static func attempt(_ value: RelayAttempt)
        -> RelayAttemptPresentation
    {
        RelayAttemptPresentation(
            id: value.id.rawValue,
            number: value.ordinal,
            status: attemptStatus(value.status),
            startedAt: value.startedAt.map(date),
            endedAt: value.endedAt.map(date),
            summary: value.failureReason,
            returnReasonFindingIDs: []
        )
    }

    private static func attemptStatus(_ status: RelayAttemptStatus)
        -> RelayStageStatus
    {
        switch status {
        case .scheduled: .queued
        case .starting, .running: .running
        case .validating: .waitingForApproval
        case .approved: .approved
        case .rejected: .rejected
        case .failed: .failed
        case .cancelling: .pausing
        case .cancelled: .paused
        case .interrupted: .interrupted
        }
    }

    private static func roleLabel(_ role: RelayStageRole?) -> String {
        switch role {
        case .scout: String(localized: "Scout")
        case .implementer: String(localized: "Implementer")
        case .verifier: String(localized: "Verifier")
        case .reviewer: String(localized: "Reviewer")
        case nil: String(localized: "Unknown Role")
        }
    }

    private static func baton(
        _ projection: RelayProjection,
        definitions: [RelayStageID: RelayStageDefinition]
    ) -> [RelayBatonPresentation] {
        guard let baton = projection.currentBaton, let task = projection.task
        else { return [] }
        return [RelayBatonPresentation(
            id: baton.id.rawValue,
            sourceStage: definitions[baton.fromStageID]?.name
                ?? String(localized: "Unknown Stage"),
            destinationStage: baton.toStageID.flatMap {
                definitions[$0]?.name
            } ?? String(localized: "Ready for Your Inspection"),
            recordedAt: date(baton.issuedAt),
            taskRevision: Int(clamping: baton.revision),
            workspaceCommit: baton.resultCommit.rawValue,
            objective: task.objective,
            acceptanceCriteria: task.acceptanceCriteria.map(\.statement),
            changes: [
                String(
                    format: String(localized: "Workspace digest %@"),
                    baton.resultWorkspaceDigest.rawValue
                )
            ],
            evidenceIDs: baton.evidenceIDs.map(\.description),
            openFindingIDs: baton.findingIDs.map(\.description),
            residualRisks: [],
            isStale: baton.resultWorkspaceDigest
                != projection.currentWorkspaceDigest
        )]
    }

    private static func finding(
        _ value: RelayCore.RelayFinding,
        definitions: [RelayStageID: RelayStageDefinition]
    ) -> RelayFindingPresentation {
        RelayFindingPresentation(
            id: value.id.description,
            severity: findingSeverity(value.severity),
            status: findingStatus(value.status),
            title: value.title,
            ownerStage: definitions[value.stageID]?.name
                ?? String(localized: "Unknown Stage"),
            attemptLabel: value.attemptID.description,
            detail: value.detail,
            evidenceIDs: [],
            resolution: value.resolution
        )
    }

    private static func findingSeverity(
        _ value: RelayCore.RelayFindingSeverity
    ) -> RelayFindingSeverity {
        switch value {
        case .p0: .p0
        case .p1: .p1
        case .p2: .p2
        case .p3: .p3
        }
    }

    private static func findingStatus(_ value: RelayCore.RelayFindingStatus)
        -> RelayFindingStatus
    {
        switch value {
        case .open: .open
        case .resolved: .resolved
        case .waived: .waived
        }
    }

    private static func evidence(
        _ value: RelayCore.RelayEvidence,
        definitions: [RelayStageID: RelayStageDefinition]
    ) -> RelayEvidencePresentation {
        RelayEvidencePresentation(
            id: value.id.description,
            kind: evidenceKind(value.kind),
            status: evidenceStatus(value),
            title: definitions[value.stageID]?.name
                ?? value.kind.description,
            detail: value.summary,
            command: nil,
            workingDirectory: nil,
            startedAt: nil,
            endedAt: date(value.recordedAt),
            exitCode: value.result == .passed ? 0 : nil,
            digest: value.workspaceDigest.rawValue,
            output: nil,
            isOutputTruncated: false,
            lastOutputAt: nil
        )
    }

    private static func evidenceKind(_ value: RelayCore.RelayEvidenceKind)
        -> RelayEvidenceKind
    {
        switch value {
        case .tests, .verification: .testSuite
        case .build, .lint: .command
        case .independentReview, .securityReview: .artifact
        case .release: .artifact
        case .custom: .artifact
        }
    }

    private static func evidenceStatus(_ value: RelayCore.RelayEvidence)
        -> RelayEvidenceStatus
    {
        if value.result == .failed { return .failed }
        switch value.trust {
        case .agentClaimed: return .claimed
        case .relayVerified: return .reproduced
        case .externalObserved: return .captured
        }
    }

    private static func gate(_ value: RelayDecision)
        -> RelayHumanGatePresentation
    {
        RelayHumanGatePresentation(
            id: value.id.rawValue,
            title: String(localized: "Relay Decision"),
            requestedAction: decisionLabel(value.kind),
            target: value.scope,
            authority: String(localized: "Approve once for this exact request"),
            sideEffects: value.scope,
            reversibility: String(localized: "The decision is recorded and cannot be silently reused."),
            evidenceSummary: value.rationale,
            requestedAt: date(value.requestedAt),
            state: gateState(value.status)
        )
    }

    private static func decisionLabel(_ value: RelayDecisionKind) -> String {
        switch value {
        case .executeRepositoryCode:
            String(localized: "Execute repository code")
        case .waiveFinding:
            String(localized: "Waive a finding")
        case .publishDraftPullRequest:
            String(localized: "Publish a draft pull request")
        case .continueAfterBudget:
            String(localized: "Continue after the configured budget")
        }
    }

    private static func gateState(_ value: RelayDecisionStatus)
        -> RelayGateState
    {
        switch value {
        case .requested: .pending
        case .granted: .approved
        case .denied: .denied
        }
    }

    private static func recovery(
        _ status: RelayTaskStatus,
        reason: String?
    ) -> RelayRecoveryPresentation {
        switch status {
        case .ready:
            .blocked(
                title: String(localized: "Secure Execution Unavailable"),
                detail: String(
                    localized: "The task and isolated worktree are saved. Relay will not run repository code until an attested OS sandbox backend is available."
                )
            )
        case .running:
            .reconciling(lastDurableEvent: String(localized: "Task running"))
        case .failed, .corrupt:
            .blocked(
                title: String(localized: "Relay Unavailable"),
                detail: reason ?? String(localized: "The durable Relay state could not be verified.")
            )
        case .delivering:
            .deliveryStateUnknown(
                detail: String(localized: "External delivery is outside the local Relay MVP.")
            )
        case .draft:
            .interrupted(
                detail: String(
                    localized: "Relay setup did not reach a durable workspace checkpoint. Inspect the preserved Relay workspace before retrying."
                )
            )
        case .waitingForUser, .localReady, .delivered, .cancelled:
            .none
        }
    }

    private static func completion(
        _ projection: RelayProjection,
        task: RelayTaskDefinition
    ) -> RelayCompletionPresentation? {
        guard projection.status == .localReady
                || projection.status == .delivered
        else { return nil }
        return RelayCompletionPresentation(
            title: String(localized: "Ready for Your Inspection"),
            summary: String(
                localized: "Relay verified the local completion contract. No commit, push, pull request, merge, or deployment is implied."
            ),
            criteria: task.acceptanceCriteria.map { criterion in
                let evidence = projection.evidence.filter {
                    $0.criterionIDs.contains(criterion.id)
                        && $0.workspaceDigest == projection.currentWorkspaceDigest
                }
                return RelayCriterionPresentation(
                    id: criterion.id.description,
                    text: criterion.statement,
                    status: evidence.contains {
                        $0.trust == .relayVerified && $0.result == .failed
                    } ? .failed : .satisfied,
                    evidenceIDs: evidence.map(\.id.description)
                )
            },
            residualRisks: [],
            artifactLabel: String(localized: "Preserved Worktree"),
            artifactDestination: projection.workspace?.repositoryRootPath,
            approvalSummary: String(localized: "Independent local review recorded")
        )
    }

    private static func latestDate(_ projection: RelayProjection) -> Date {
        let taskInstants: [RelayInstant] = projection.task.map {
            [$0.createdAt]
        } ?? []
        let attemptInstants: [RelayInstant] = projection.attempts.flatMap {
            [$0.scheduledAt] + [$0.startedAt, $0.endedAt].compactMap { $0 }
        }
        let decisionInstants: [RelayInstant] = projection.decisions.flatMap {
            [$0.requestedAt] + [$0.decidedAt].compactMap { $0 }
        }
        let instants = taskInstants
            + attemptInstants
            + projection.evidence.map(\.recordedAt)
            + decisionInstants
        return instants.map(date).max() ?? Date()
    }

    private static func date(_ value: RelayInstant) -> Date {
        Date(timeIntervalSince1970: TimeInterval(value.rawValue) / 1_000)
    }
}

private extension RelayCore.RelayEvidenceKind {
    var description: String {
        switch self {
        case .build: "Build"
        case .tests: "Tests"
        case .lint: "Lint"
        case .verification: "Verification"
        case .independentReview: "Independent Review"
        case .securityReview: "Security Review"
        case .release: "Release"
        case .custom(let value): value
        }
    }
}
