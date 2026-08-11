import Foundation

public enum RelaySchema {
    public static let currentVersion = 1
}

public enum RelayTaskStatus: String, Codable, CaseIterable, Sendable {
    case draft
    case ready
    case running
    case waitingForUser
    case localReady
    case delivering
    case delivered
    case failed
    case cancelled
    case corrupt
}

public enum RelayStageStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case running
    case approved
    case rejected
    case blocked
    case skipped
}

public enum RelayAttemptStatus: String, Codable, CaseIterable, Sendable {
    case scheduled
    case starting
    case running
    case validating
    case approved
    case rejected
    case failed
    case cancelling
    case cancelled
    case interrupted
}

public enum RelayStageRole: String, Codable, CaseIterable, Sendable {
    case scout
    case implementer
    case verifier
    case reviewer
}

public enum RelayFindingSeverity: String, Codable, CaseIterable, Sendable {
    case p0
    case p1
    case p2
    case p3
}

public enum RelayFindingStatus: String, Codable, CaseIterable, Sendable {
    case open
    case resolved
    case waived
}

public enum RelayEvidenceKind: Hashable, Codable, Sendable {
    case build
    case tests
    case lint
    case verification
    case independentReview
    case securityReview
    case release
    case custom(String)
}

public enum RelayEvidenceResult: String, Codable, CaseIterable, Sendable {
    case passed
    case failed
    case inconclusive
}

public enum RelayEvidenceTrust: String, Codable, CaseIterable, Sendable {
    case agentClaimed
    case relayVerified
    case externalObserved
}

public enum RelayDecisionKind: String, Codable, CaseIterable, Sendable {
    case executeRepositoryCode
    case waiveFinding
    case publishDraftPullRequest
    case continueAfterBudget
}

public enum RelayDecisionStatus: String, Codable, CaseIterable, Sendable {
    case requested
    case granted
    case denied
}

public enum RelayArtifactKind: String, Codable, CaseIterable, Sendable {
    case context
    case instructions
    case patch
    case commandLog
    case agentResult
    case commit
    case report
    case pullRequest
}

public enum RelayArtifactClassification: String, Codable, CaseIterable,
    Sendable
{
    case local
    case localSensitive
    case exportable
}

public struct RelayAcceptanceCriterion: Hashable, Codable, Sendable {
    public let id: RelayAcceptanceCriterionID
    public let statement: String
    public let requiredEvidenceKinds: [RelayEvidenceKind]

    public init(
        id: RelayAcceptanceCriterionID,
        statement: String,
        requiredEvidenceKinds: [RelayEvidenceKind]
    ) {
        self.id = id
        self.statement = statement
        self.requiredEvidenceKinds = requiredEvidenceKinds
    }
}

public struct RelayStageDefinition: Hashable, Codable, Sendable {
    public let id: RelayStageID
    public let name: String
    public let role: RelayStageRole
    public let authority: RelayAuthority
    public let requiredEvidence: [RelayEvidenceKind]
    public let rejectionStageID: RelayStageID?
    public let maximumTechnicalRetries: Int
    public let maximumRejectionCycles: Int

    public init(
        id: RelayStageID,
        name: String,
        role: RelayStageRole,
        authority: RelayAuthority,
        requiredEvidence: [RelayEvidenceKind] = [],
        rejectionStageID: RelayStageID? = nil,
        maximumTechnicalRetries: Int = 2,
        maximumRejectionCycles: Int = 3
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.authority = authority
        self.requiredEvidence = requiredEvidence
        self.rejectionStageID = rejectionStageID
        self.maximumTechnicalRetries = maximumTechnicalRetries
        self.maximumRejectionCycles = maximumRejectionCycles
    }
}

public struct RelayCompletionPolicy: Hashable, Codable, Sendable {
    public let requiredEvidence: [RelayEvidenceKind]
    public let blockingSeverities: [RelayFindingSeverity]

    public init(
        requiredEvidence: [RelayEvidenceKind] = [],
        blockingSeverities: [RelayFindingSeverity] = [.p0, .p1]
    ) {
        self.requiredEvidence = requiredEvidence
        self.blockingSeverities = blockingSeverities
    }
}

public struct RelayTaskDefinition: Hashable, Codable, Sendable {
    public let schemaVersion: Int
    public let id: RelayTaskID
    public let title: String
    public let objective: String
    public let acceptanceCriteria: [RelayAcceptanceCriterion]
    public let stages: [RelayStageDefinition]
    public let completionPolicy: RelayCompletionPolicy
    public let createdAt: RelayInstant

    public init(
        schemaVersion: Int = RelaySchema.currentVersion,
        id: RelayTaskID,
        title: String,
        objective: String,
        acceptanceCriteria: [RelayAcceptanceCriterion],
        stages: [RelayStageDefinition],
        completionPolicy: RelayCompletionPolicy = RelayCompletionPolicy(),
        createdAt: RelayInstant
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.objective = objective
        self.acceptanceCriteria = acceptanceCriteria
        self.stages = stages
        self.completionPolicy = completionPolicy
        self.createdAt = createdAt
    }

    public init(
        schemaVersion: Int = RelaySchema.currentVersion,
        id: RelayTaskID,
        title: String,
        objective: String,
        acceptanceCriteria: [String],
        stages: [RelayStageDefinition],
        completionPolicy: RelayCompletionPolicy = RelayCompletionPolicy(),
        createdAt: RelayInstant
    ) {
        let requiredKinds = completionPolicy.requiredEvidence.isEmpty
            ? [RelayEvidenceKind.verification, .independentReview]
            : completionPolicy.requiredEvidence
        self.init(
            schemaVersion: schemaVersion,
            id: id,
            title: title,
            objective: objective,
            acceptanceCriteria: acceptanceCriteria.enumerated().map { index, statement in
                RelayAcceptanceCriterion(
                    id: .derived(taskID: id, index: index, statement: statement),
                    statement: statement,
                    requiredEvidenceKinds: requiredKinds
                )
            },
            stages: stages,
            completionPolicy: completionPolicy,
            createdAt: createdAt
        )
    }
}

public struct RelayFileIdentity: Hashable, Codable, Sendable {
    public let deviceID: UInt64
    public let fileID: UInt64

    public init(deviceID: UInt64, fileID: UInt64) {
        self.deviceID = deviceID
        self.fileID = fileID
    }
}

public struct RelayWorkspaceIdentity: Hashable, Codable, Sendable {
    public let taskID: RelayTaskID
    public let repositoryRootPath: String
    public let gitCommonDirectoryPath: String
    public let repositoryFileIdentity: RelayFileIdentity
    public let gitCommonDirectoryFileIdentity: RelayFileIdentity
    public let baseCommit: RelayGitOID
    public let headCommit: RelayGitOID
    public let workspaceDigest: RelayDigest
    public let taskReference: String
    public let isClean: Bool
    public let preparedAt: RelayInstant

    public init(
        taskID: RelayTaskID,
        repositoryRootPath: String,
        gitCommonDirectoryPath: String,
        repositoryFileIdentity: RelayFileIdentity,
        gitCommonDirectoryFileIdentity: RelayFileIdentity,
        baseCommit: RelayGitOID,
        headCommit: RelayGitOID,
        workspaceDigest: RelayDigest,
        taskReference: String,
        isClean: Bool,
        preparedAt: RelayInstant
    ) {
        self.taskID = taskID
        self.repositoryRootPath = repositoryRootPath
        self.gitCommonDirectoryPath = gitCommonDirectoryPath
        self.repositoryFileIdentity = repositoryFileIdentity
        self.gitCommonDirectoryFileIdentity = gitCommonDirectoryFileIdentity
        self.baseCommit = baseCommit
        self.headCommit = headCommit
        self.workspaceDigest = workspaceDigest
        self.taskReference = taskReference
        self.isClean = isClean
        self.preparedAt = preparedAt
    }
}

/// Durable authority to create exactly one managed worktree for a task.
///
/// The source and managed-root identities are captured before provisioning.
/// The target itself does not exist yet, so its exact path and expected clean
/// digest are recorded instead. Recovery must revalidate these facts before it
/// creates or adopts anything at `targetWorkspacePath`.
public struct RelayWorkspaceProvisioningIntent: Hashable, Codable, Sendable {
    public let id: RelayWorkspaceProvisioningIntentID
    public let taskID: RelayTaskID
    public let sourceRepositoryRootPath: String
    public let sourceRepositoryFileIdentity: RelayFileIdentity
    public let sourceGitDirectoryPath: String
    public let sourceGitCommonDirectoryPath: String
    public let sourceGitCommonDirectoryFileIdentity: RelayFileIdentity
    public let baselineCommit: RelayGitOID
    public let managedRootPath: String
    public let managedRootFileIdentity: RelayFileIdentity
    public let targetWorkspacePath: String
    public let expectedTaskReference: String
    public let expectedInitialWorkspaceDigest: RelayDigest
    public let requestedAt: RelayInstant

    public init(
        id: RelayWorkspaceProvisioningIntentID,
        taskID: RelayTaskID,
        sourceRepositoryRootPath: String,
        sourceRepositoryFileIdentity: RelayFileIdentity,
        sourceGitDirectoryPath: String,
        sourceGitCommonDirectoryPath: String,
        sourceGitCommonDirectoryFileIdentity: RelayFileIdentity,
        baselineCommit: RelayGitOID,
        managedRootPath: String,
        managedRootFileIdentity: RelayFileIdentity,
        targetWorkspacePath: String,
        expectedTaskReference: String,
        expectedInitialWorkspaceDigest: RelayDigest,
        requestedAt: RelayInstant
    ) {
        self.id = id
        self.taskID = taskID
        self.sourceRepositoryRootPath = sourceRepositoryRootPath
        self.sourceRepositoryFileIdentity = sourceRepositoryFileIdentity
        self.sourceGitDirectoryPath = sourceGitDirectoryPath
        self.sourceGitCommonDirectoryPath = sourceGitCommonDirectoryPath
        self.sourceGitCommonDirectoryFileIdentity =
            sourceGitCommonDirectoryFileIdentity
        self.baselineCommit = baselineCommit
        self.managedRootPath = managedRootPath
        self.managedRootFileIdentity = managedRootFileIdentity
        self.targetWorkspacePath = targetWorkspacePath
        self.expectedTaskReference = expectedTaskReference
        self.expectedInitialWorkspaceDigest = expectedInitialWorkspaceDigest
        self.requestedAt = requestedAt
    }
}

public struct RelayAttempt: Hashable, Codable, Sendable {
    public let id: RelayAttemptID
    public let taskID: RelayTaskID
    public let stageID: RelayStageID
    public let ordinal: Int
    public let sourceCommit: RelayGitOID
    public let sourceWorkspaceDigest: RelayDigest
    public var resultCommit: RelayGitOID?
    public var resultWorkspaceDigest: RelayDigest?
    public var status: RelayAttemptStatus
    public let scheduledAt: RelayInstant
    public var startedAt: RelayInstant?
    public var endedAt: RelayInstant?
    public var failureReason: String?

    public init(
        id: RelayAttemptID,
        taskID: RelayTaskID,
        stageID: RelayStageID,
        ordinal: Int,
        sourceCommit: RelayGitOID,
        sourceWorkspaceDigest: RelayDigest,
        resultCommit: RelayGitOID? = nil,
        resultWorkspaceDigest: RelayDigest? = nil,
        status: RelayAttemptStatus = .scheduled,
        scheduledAt: RelayInstant,
        startedAt: RelayInstant? = nil,
        endedAt: RelayInstant? = nil,
        failureReason: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.stageID = stageID
        self.ordinal = ordinal
        self.sourceCommit = sourceCommit
        self.sourceWorkspaceDigest = sourceWorkspaceDigest
        self.resultCommit = resultCommit
        self.resultWorkspaceDigest = resultWorkspaceDigest
        self.status = status
        self.scheduledAt = scheduledAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.failureReason = failureReason
    }
}

public struct RelayBaton: Hashable, Codable, Sendable {
    public let id: RelayBatonID
    public let taskID: RelayTaskID
    public let revision: UInt64
    public let fromStageID: RelayStageID
    public let toStageID: RelayStageID?
    public let sourceCommit: RelayGitOID
    public let resultCommit: RelayGitOID
    public let sourceWorkspaceDigest: RelayDigest
    public let resultWorkspaceDigest: RelayDigest
    public let findingIDs: [RelayFindingID]
    public let evidenceIDs: [RelayEvidenceID]
    public let artifactIDs: [RelayArtifactID]
    public let sourceJournalHead: RelayJournalHead
    public let issuedAt: RelayInstant

    public init(
        id: RelayBatonID,
        taskID: RelayTaskID,
        revision: UInt64,
        fromStageID: RelayStageID,
        toStageID: RelayStageID?,
        sourceCommit: RelayGitOID,
        resultCommit: RelayGitOID,
        sourceWorkspaceDigest: RelayDigest,
        resultWorkspaceDigest: RelayDigest,
        findingIDs: [RelayFindingID],
        evidenceIDs: [RelayEvidenceID],
        artifactIDs: [RelayArtifactID],
        sourceJournalHead: RelayJournalHead,
        issuedAt: RelayInstant
    ) {
        self.id = id
        self.taskID = taskID
        self.revision = revision
        self.fromStageID = fromStageID
        self.toStageID = toStageID
        self.sourceCommit = sourceCommit
        self.resultCommit = resultCommit
        self.sourceWorkspaceDigest = sourceWorkspaceDigest
        self.resultWorkspaceDigest = resultWorkspaceDigest
        self.findingIDs = findingIDs
        self.evidenceIDs = evidenceIDs
        self.artifactIDs = artifactIDs
        self.sourceJournalHead = sourceJournalHead
        self.issuedAt = issuedAt
    }
}

public struct RelayFinding: Hashable, Codable, Sendable {
    public let id: RelayFindingID
    public let taskID: RelayTaskID
    public let stageID: RelayStageID
    public let attemptID: RelayAttemptID
    public let severity: RelayFindingSeverity
    public let title: String
    public let detail: String
    public let acceptanceCriteria: [String]
    public var status: RelayFindingStatus
    public var resolution: String?
    public let openedAt: RelayInstant
    public var closedAt: RelayInstant?

    public init(
        id: RelayFindingID,
        taskID: RelayTaskID,
        stageID: RelayStageID,
        attemptID: RelayAttemptID,
        severity: RelayFindingSeverity,
        title: String,
        detail: String,
        acceptanceCriteria: [String],
        status: RelayFindingStatus = .open,
        resolution: String? = nil,
        openedAt: RelayInstant,
        closedAt: RelayInstant? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.stageID = stageID
        self.attemptID = attemptID
        self.severity = severity
        self.title = title
        self.detail = detail
        self.acceptanceCriteria = acceptanceCriteria
        self.status = status
        self.resolution = resolution
        self.openedAt = openedAt
        self.closedAt = closedAt
    }
}

public struct RelayEvidence: Hashable, Codable, Sendable {
    public let id: RelayEvidenceID
    public let taskID: RelayTaskID
    public let stageID: RelayStageID
    public let attemptID: RelayAttemptID
    public let kind: RelayEvidenceKind
    public let result: RelayEvidenceResult
    public let trust: RelayEvidenceTrust
    public let workspaceCommit: RelayGitOID
    public let workspaceDigest: RelayDigest
    public let criterionIDs: [RelayAcceptanceCriterionID]
    public let summary: String
    public let artifactID: RelayArtifactID?
    public let recordedAt: RelayInstant

    public init(
        id: RelayEvidenceID,
        taskID: RelayTaskID,
        stageID: RelayStageID,
        attemptID: RelayAttemptID,
        kind: RelayEvidenceKind,
        result: RelayEvidenceResult,
        trust: RelayEvidenceTrust,
        workspaceCommit: RelayGitOID,
        workspaceDigest: RelayDigest,
        criterionIDs: [RelayAcceptanceCriterionID] = [],
        summary: String,
        artifactID: RelayArtifactID? = nil,
        recordedAt: RelayInstant
    ) {
        self.id = id
        self.taskID = taskID
        self.stageID = stageID
        self.attemptID = attemptID
        self.kind = kind
        self.result = result
        self.trust = trust
        self.workspaceCommit = workspaceCommit
        self.workspaceDigest = workspaceDigest
        self.criterionIDs = criterionIDs
        self.summary = summary
        self.artifactID = artifactID
        self.recordedAt = recordedAt
    }
}

public struct RelayDecision: Hashable, Codable, Sendable {
    public let id: RelayDecisionID
    public let taskID: RelayTaskID
    public let kind: RelayDecisionKind
    public let scope: String
    public var status: RelayDecisionStatus
    public let requestedAt: RelayInstant
    public var decidedAt: RelayInstant?
    public var rationale: String?

    public init(
        id: RelayDecisionID,
        taskID: RelayTaskID,
        kind: RelayDecisionKind,
        scope: String,
        status: RelayDecisionStatus = .requested,
        requestedAt: RelayInstant,
        decidedAt: RelayInstant? = nil,
        rationale: String? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.kind = kind
        self.scope = scope
        self.status = status
        self.requestedAt = requestedAt
        self.decidedAt = decidedAt
        self.rationale = rationale
    }
}

public struct RelayArtifact: Hashable, Codable, Sendable {
    public let id: RelayArtifactID
    public let taskID: RelayTaskID
    public let attemptID: RelayAttemptID?
    public let kind: RelayArtifactKind
    public let classification: RelayArtifactClassification
    public let digest: RelayDigest
    public let byteCount: UInt64
    public let mediaType: String
    public let relativePath: String
    public let createdAt: RelayInstant

    public init(
        id: RelayArtifactID,
        taskID: RelayTaskID,
        attemptID: RelayAttemptID? = nil,
        kind: RelayArtifactKind,
        classification: RelayArtifactClassification,
        digest: RelayDigest,
        byteCount: UInt64,
        mediaType: String,
        relativePath: String,
        createdAt: RelayInstant
    ) {
        self.id = id
        self.taskID = taskID
        self.attemptID = attemptID
        self.kind = kind
        self.classification = classification
        self.digest = digest
        self.byteCount = byteCount
        self.mediaType = mediaType
        self.relativePath = relativePath
        self.createdAt = createdAt
    }
}
