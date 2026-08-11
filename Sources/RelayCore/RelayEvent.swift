import Foundation

public enum RelayEvent: Hashable, Codable, Sendable {
    case taskCreated(RelayTaskDefinition)
    case workspaceProvisioningRequested(RelayWorkspaceProvisioningIntent)
    case workspacePrepared(RelayWorkspaceIdentity)
    case taskBecameReady
    case taskStarted(at: RelayInstant)
    case attemptScheduled(RelayAttempt)
    case attemptStarting(RelayAttemptID, at: RelayInstant)
    case attemptRunning(RelayAttemptID, at: RelayInstant)
    case attemptValidationStarted(RelayAttemptID, at: RelayInstant)
    case artifactRecorded(RelayArtifact)
    case evidenceRecorded(RelayEvidence)
    case findingOpened(RelayFinding)
    case findingResolved(RelayFindingID, resolution: String, at: RelayInstant)
    case findingWaived(RelayFindingID, decisionID: RelayDecisionID, at: RelayInstant)
    case decisionRequested(RelayDecision)
    case decisionRecorded(
        RelayDecisionID,
        status: RelayDecisionStatus,
        rationale: String,
        at: RelayInstant
    )
    case attemptApproved(
        RelayAttemptID,
        resultCommit: RelayGitOID,
        resultWorkspaceDigest: RelayDigest,
        baton: RelayBaton,
        at: RelayInstant
    )
    case attemptRejected(RelayAttemptID, baton: RelayBaton, at: RelayInstant)
    case attemptFailed(RelayAttemptID, reason: String, at: RelayInstant)
    case attemptInterrupted(RelayAttemptID, reason: String, at: RelayInstant)
    case cancellationRequested(RelayAttemptID, at: RelayInstant)
    case attemptCancelled(RelayAttemptID, at: RelayInstant)
    case taskWaiting(reason: String)
    case taskResumed
    case taskBecameLocalReady
    case deliveryStarted
    case taskDelivered
    case taskFailed(reason: String)
    case taskCancelled(reason: String)
}

public struct RelayEventEnvelope: Hashable, Codable, Sendable {
    public let schemaVersion: Int
    public let eventID: UUID
    public let taskID: RelayTaskID
    public let occurredAt: RelayInstant
    public let event: RelayEvent

    public init(
        schemaVersion: Int = RelaySchema.currentVersion,
        eventID: UUID,
        taskID: RelayTaskID,
        occurredAt: RelayInstant,
        event: RelayEvent
    ) {
        self.schemaVersion = schemaVersion
        self.eventID = eventID
        self.taskID = taskID
        self.occurredAt = occurredAt
        self.event = event
    }
}
