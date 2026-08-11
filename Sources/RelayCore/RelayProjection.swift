import Foundation

public struct RelayStageState: Hashable, Codable, Sendable {
    public let stageID: RelayStageID
    public var status: RelayStageStatus
    public var attemptIDs: [RelayAttemptID]
    public var rejectionCount: Int

    public init(
        stageID: RelayStageID,
        status: RelayStageStatus = .pending,
        attemptIDs: [RelayAttemptID] = [],
        rejectionCount: Int = 0
    ) {
        self.stageID = stageID
        self.status = status
        self.attemptIDs = attemptIDs
        self.rejectionCount = rejectionCount
    }
}

public struct RelayProjection: Hashable, Codable, Sendable {
    public var task: RelayTaskDefinition?
    public var status: RelayTaskStatus
    public var workspaceProvisioningIntent: RelayWorkspaceProvisioningIntent?
    public var workspace: RelayWorkspaceIdentity?
    public var taskHeadCommit: RelayGitOID?
    public var currentWorkspaceDigest: RelayDigest?
    public var stages: [RelayStageState]
    public var attempts: [RelayAttempt]
    public var activeAttemptID: RelayAttemptID?
    public var currentStageID: RelayStageID?
    public var currentBaton: RelayBaton?
    public var findings: [RelayFinding]
    public var evidence: [RelayEvidence]
    public var decisions: [RelayDecision]
    public var artifacts: [RelayArtifact]
    public var waitingReason: String?
    public var failureReason: String?

    public init(
        task: RelayTaskDefinition? = nil,
        status: RelayTaskStatus = .draft,
        workspaceProvisioningIntent: RelayWorkspaceProvisioningIntent? = nil,
        workspace: RelayWorkspaceIdentity? = nil,
        taskHeadCommit: RelayGitOID? = nil,
        currentWorkspaceDigest: RelayDigest? = nil,
        stages: [RelayStageState] = [],
        attempts: [RelayAttempt] = [],
        activeAttemptID: RelayAttemptID? = nil,
        currentStageID: RelayStageID? = nil,
        currentBaton: RelayBaton? = nil,
        findings: [RelayFinding] = [],
        evidence: [RelayEvidence] = [],
        decisions: [RelayDecision] = [],
        artifacts: [RelayArtifact] = [],
        waitingReason: String? = nil,
        failureReason: String? = nil
    ) {
        self.task = task
        self.status = status
        self.workspaceProvisioningIntent = workspaceProvisioningIntent
        self.workspace = workspace
        self.taskHeadCommit = taskHeadCommit
        self.currentWorkspaceDigest = currentWorkspaceDigest
        self.stages = stages
        self.attempts = attempts
        self.activeAttemptID = activeAttemptID
        self.currentStageID = currentStageID
        self.currentBaton = currentBaton
        self.findings = findings
        self.evidence = evidence
        self.decisions = decisions
        self.artifacts = artifacts
        self.waitingReason = waitingReason
        self.failureReason = failureReason
    }

    public static let empty = RelayProjection()

    public func stage(_ id: RelayStageID) -> RelayStageState? {
        stages.first { $0.stageID == id }
    }

    public func attempt(_ id: RelayAttemptID) -> RelayAttempt? {
        attempts.first { $0.id == id }
    }

    public func finding(_ id: RelayFindingID) -> RelayFinding? {
        findings.first { $0.id == id }
    }

    public func evidenceItem(_ id: RelayEvidenceID) -> RelayEvidence? {
        evidence.first { $0.id == id }
    }

    public func decision(_ id: RelayDecisionID) -> RelayDecision? {
        decisions.first { $0.id == id }
    }

    public func artifact(_ id: RelayArtifactID) -> RelayArtifact? {
        artifacts.first { $0.id == id }
    }
}

public enum RelayReadyBlocker: Hashable, Codable, Sendable {
    case taskMissing
    case taskStatus(RelayTaskStatus)
    case unsupportedSchema(Int)
    case titleMissing
    case objectiveMissing
    case acceptanceCriteriaMissing
    case emptyAcceptanceCriterion(Int)
    case duplicateAcceptanceCriterionID(RelayAcceptanceCriterionID)
    case acceptanceCriterionEvidenceKindsMissing(RelayAcceptanceCriterionID)
    case duplicateAcceptanceCriterionEvidenceKind(RelayAcceptanceCriterionID)
    case stagesMissing
    case duplicateStageID(RelayStageID)
    case emptyStageName(RelayStageID)
    case duplicateEvidenceRequirement(RelayStageID)
    case invalidRetryBudget(RelayStageID)
    case invalidRejectionBudget(RelayStageID)
    case invalidRejectionTarget(RelayStageID)
    case invalidAuthority(RelayStageID)
    case duplicateCompletionEvidence
    case workspaceProvisioningIntentMissing
    case workspaceProvisioningIntentMismatch
    case workspaceMissing
    case workspaceTaskMismatch
    case repositoryPathNotAbsolute
    case gitCommonDirectoryPathNotAbsolute
    case workspaceNotClean
    case workspaceHeadMismatch
    case workspaceDigestMismatch
    case taskReferenceMissing
    case taskAlreadyHasAttempts
}

public struct RelayReadyGateResult: Hashable, Codable, Sendable {
    public let blockers: [RelayReadyBlocker]

    public init(blockers: [RelayReadyBlocker]) {
        self.blockers = blockers
    }

    public var isReady: Bool { blockers.isEmpty }
}

public enum RelayLocalReadyBlocker: Hashable, Codable, Sendable {
    case taskMissing
    case taskStatus(RelayTaskStatus)
    case activeAttempt(RelayAttemptID)
    case inFlightAttempt(RelayAttemptID)
    case stageNotApproved(RelayStageID)
    case openBlockingFinding(RelayFindingID)
    case pendingDecision(RelayDecisionID)
    case missingTaskHead
    case missingWorkspaceDigest
    case workspaceUnchanged
    case exactImplementationDeltaMissing
    case exactVerificationMissing
    case exactIndependentReviewMissing
    case missingEvidence(RelayEvidenceKind)
    case unverifiedEvidence(RelayEvidenceKind)
    case failedEvidence(RelayEvidenceKind)
    case criterionEvidenceMissing(
        RelayAcceptanceCriterionID,
        RelayEvidenceKind
    )
    case criterionEvidenceUnverified(
        RelayAcceptanceCriterionID,
        RelayEvidenceKind
    )
    case criterionEvidenceFailed(
        RelayAcceptanceCriterionID,
        RelayEvidenceKind
    )
}

public struct RelayLocalReadyGateResult: Hashable, Codable, Sendable {
    public let blockers: [RelayLocalReadyBlocker]

    public init(blockers: [RelayLocalReadyBlocker]) {
        self.blockers = blockers
    }

    public var isReady: Bool { blockers.isEmpty }
}
