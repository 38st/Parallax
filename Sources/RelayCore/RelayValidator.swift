import Foundation

public enum RelayReadyGate {
    public static func evaluate(_ projection: RelayProjection) -> RelayReadyGateResult {
        var blockers: [RelayReadyBlocker] = []
        guard let task = projection.task else {
            return RelayReadyGateResult(blockers: [.taskMissing])
        }
        if projection.status != .draft {
            blockers.append(.taskStatus(projection.status))
        }
        if task.schemaVersion != RelaySchema.currentVersion {
            blockers.append(.unsupportedSchema(task.schemaVersion))
        }
        if task.title.relayTrimmed.isEmpty { blockers.append(.titleMissing) }
        if task.objective.relayTrimmed.isEmpty { blockers.append(.objectiveMissing) }
        if task.acceptanceCriteria.isEmpty {
            blockers.append(.acceptanceCriteriaMissing)
        }
        var criterionIDs = Set<RelayAcceptanceCriterionID>()
        for (index, criterion) in task.acceptanceCriteria.enumerated() {
            if criterion.statement.relayTrimmed.isEmpty {
                blockers.append(.emptyAcceptanceCriterion(index))
            }
            if !criterionIDs.insert(criterion.id).inserted {
                blockers.append(.duplicateAcceptanceCriterionID(criterion.id))
            }
            if criterion.requiredEvidenceKinds.isEmpty {
                blockers.append(.acceptanceCriterionEvidenceKindsMissing(criterion.id))
            }
            if Set(criterion.requiredEvidenceKinds).count
                != criterion.requiredEvidenceKinds.count {
                blockers.append(.duplicateAcceptanceCriterionEvidenceKind(criterion.id))
            }
        }
        if task.stages.isEmpty { blockers.append(.stagesMissing) }

        var stageIDs = Set<RelayStageID>()
        for (index, stage) in task.stages.enumerated() {
            if !stageIDs.insert(stage.id).inserted {
                blockers.append(.duplicateStageID(stage.id))
            }
            if stage.name.relayTrimmed.isEmpty {
                blockers.append(.emptyStageName(stage.id))
            }
            if Set(stage.requiredEvidence).count != stage.requiredEvidence.count {
                blockers.append(.duplicateEvidenceRequirement(stage.id))
            }
            if !(0...10).contains(stage.maximumTechnicalRetries) {
                blockers.append(.invalidRetryBudget(stage.id))
            }
            if !(0...10).contains(stage.maximumRejectionCycles) {
                blockers.append(.invalidRejectionBudget(stage.id))
            }
            if let target = stage.rejectionStageID,
               task.stages[..<index].contains(where: { $0.id == target }) == false {
                blockers.append(.invalidRejectionTarget(stage.id))
            }
            if !authorityIsValid(for: stage) {
                blockers.append(.invalidAuthority(stage.id))
            }
        }
        if Set(task.completionPolicy.requiredEvidence).count
            != task.completionPolicy.requiredEvidence.count {
            blockers.append(.duplicateCompletionEvidence)
        }

        guard let intent = projection.workspaceProvisioningIntent else {
            blockers.append(.workspaceProvisioningIntentMissing)
            if projection.workspace == nil {
                blockers.append(.workspaceMissing)
            }
            return RelayReadyGateResult(blockers: blockers)
        }
        if intent.taskID != task.id || !intent.isStructurallyValid {
            blockers.append(.workspaceProvisioningIntentMismatch)
        }

        guard let workspace = projection.workspace else {
            blockers.append(.workspaceMissing)
            return RelayReadyGateResult(blockers: blockers)
        }
        if !intent.matchesPreparedWorkspace(workspace) {
            blockers.append(.workspaceProvisioningIntentMismatch)
        }
        if workspace.taskID != task.id { blockers.append(.workspaceTaskMismatch) }
        if !workspace.repositoryRootPath.hasPrefix("/") {
            blockers.append(.repositoryPathNotAbsolute)
        }
        if !workspace.gitCommonDirectoryPath.hasPrefix("/") {
            blockers.append(.gitCommonDirectoryPathNotAbsolute)
        }
        if !workspace.isClean { blockers.append(.workspaceNotClean) }
        if workspace.baseCommit != workspace.headCommit
            || projection.taskHeadCommit != workspace.headCommit {
            blockers.append(.workspaceHeadMismatch)
        }
        if projection.currentWorkspaceDigest != workspace.workspaceDigest {
            blockers.append(.workspaceDigestMismatch)
        }
        if workspace.taskReference.relayTrimmed.isEmpty {
            blockers.append(.taskReferenceMissing)
        }
        if !projection.attempts.isEmpty {
            blockers.append(.taskAlreadyHasAttempts)
        }
        return RelayReadyGateResult(blockers: blockers)
    }

    private static func authorityIsValid(for stage: RelayStageDefinition) -> Bool {
        let authority = stage.authority
        guard authority.externalWrites == .none,
              authority.credentials != .githubDelivery
        else { return false }
        switch stage.role {
        case .reviewer:
            return authority.fileSystem == .readOnly
                && authority.git != .checkpoint
        case .scout:
            return authority.git != .checkpoint
        case .implementer, .verifier:
            return true
        }
    }
}

public enum RelayLocalReadyGate {
    public static func evaluate(
        _ projection: RelayProjection
    ) -> RelayLocalReadyGateResult {
        var blockers: [RelayLocalReadyBlocker] = []
        guard let task = projection.task else {
            return RelayLocalReadyGateResult(blockers: [.taskMissing])
        }
        if projection.status != .running {
            blockers.append(.taskStatus(projection.status))
        }
        if let active = projection.activeAttemptID {
            blockers.append(.activeAttempt(active))
        }
        let inFlightStatuses: Set<RelayAttemptStatus> = [
            .scheduled, .starting, .running, .validating, .cancelling,
        ]
        for attempt in projection.attempts where inFlightStatuses.contains(attempt.status) {
            blockers.append(.inFlightAttempt(attempt.id))
        }
        for stage in projection.stages where stage.status != .approved {
            blockers.append(.stageNotApproved(stage.stageID))
        }
        for finding in projection.findings where finding.status == .open {
            blockers.append(.openBlockingFinding(finding.id))
        }
        for decision in projection.decisions where decision.status == .requested {
            blockers.append(.pendingDecision(decision.id))
        }
        guard let head = projection.taskHeadCommit else {
            blockers.append(.missingTaskHead)
            return RelayLocalReadyGateResult(blockers: blockers)
        }
        guard let digest = projection.currentWorkspaceDigest else {
            blockers.append(.missingWorkspaceDigest)
            return RelayLocalReadyGateResult(blockers: blockers)
        }
        if digest == projection.workspace?.workspaceDigest {
            blockers.append(.workspaceUnchanged)
        }

        let exactImplementationDelta = task.stages
            .filter { $0.role == .implementer }
            .contains { stage in
                projection.attempts.contains { attempt in
                    attempt.stageID == stage.id
                        && attempt.status == .approved
                        && attempt.sourceWorkspaceDigest != attempt.resultWorkspaceDigest
                        && attempt.resultWorkspaceDigest == digest
                }
            }
        if !exactImplementationDelta {
            blockers.append(.exactImplementationDeltaMissing)
        }

        let exactVerification = task.stages
            .filter { $0.role == .verifier }
            .contains { stage in
                projection.attempts.contains { attempt in
                    attempt.stageID == stage.id
                        && attempt.status == .approved
                        && attempt.resultWorkspaceDigest == digest
                        && projection.evidence.contains {
                            $0.attemptID == attempt.id
                                && $0.stageID == stage.id
                                && $0.kind == .verification
                                && $0.workspaceDigest == digest
                                && $0.result == .passed
                                && $0.trust == .relayVerified
                        }
                }
            }
        if !exactVerification {
            blockers.append(.exactVerificationMissing)
        }

        let exactReview = task.stages
            .filter { $0.role == .reviewer }
            .contains { stage in
                projection.attempts.contains { attempt in
                    attempt.stageID == stage.id
                        && attempt.status == .approved
                        && attempt.sourceWorkspaceDigest == digest
                        && attempt.resultWorkspaceDigest == digest
                        && projection.evidence.contains {
                            $0.attemptID == attempt.id
                                && $0.stageID == stage.id
                                && $0.kind == .independentReview
                                && $0.workspaceDigest == digest
                                && $0.result == .passed
                                && $0.trust == .relayVerified
                        }
                }
            }
        if !exactReview {
            blockers.append(.exactIndependentReviewMissing)
        }
        for criterion in task.acceptanceCriteria {
            for kind in criterion.requiredEvidenceKinds {
                let matching = projection.evidence.filter {
                    $0.criterionIDs.contains(criterion.id)
                        && $0.kind == kind
                        && $0.workspaceDigest == digest
                }
                if matching.isEmpty {
                    blockers.append(.criterionEvidenceMissing(criterion.id, kind))
                } else if !matching.contains(where: { $0.trust == .relayVerified }) {
                    blockers.append(.criterionEvidenceUnverified(criterion.id, kind))
                } else if !matching.contains(where: {
                    $0.trust == .relayVerified && $0.result == .passed
                }) {
                    blockers.append(.criterionEvidenceFailed(criterion.id, kind))
                }
            }
        }
        for kind in task.completionPolicy.requiredEvidence {
            let matching = projection.evidence.filter {
                $0.kind == kind
                    && $0.workspaceCommit == head
                    && $0.workspaceDigest == digest
            }
            if matching.isEmpty {
                blockers.append(.missingEvidence(kind))
            } else if !matching.contains(where: { $0.trust == .relayVerified }) {
                blockers.append(.unverifiedEvidence(kind))
            } else if !matching.contains(where: {
                $0.trust == .relayVerified && $0.result == .passed
            }) {
                blockers.append(.failedEvidence(kind))
            }
        }
        return RelayLocalReadyGateResult(blockers: blockers)
    }
}

extension String {
    fileprivate var relayTrimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
