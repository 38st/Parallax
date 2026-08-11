import Foundation

public enum RelayCommand: Hashable, Codable, Sendable {
    case createTask(RelayTaskDefinition)
    case requestWorkspaceProvisioning(RelayWorkspaceProvisioningIntent)
    case recordWorkspacePrepared(RelayWorkspaceIdentity)
    case declareReady
    case start(at: RelayInstant)
    case scheduleAttempt(RelayAttempt)
    case markAttemptStarting(RelayAttemptID, at: RelayInstant)
    case markAttemptRunning(RelayAttemptID, at: RelayInstant)
    case beginAttemptValidation(RelayAttemptID, at: RelayInstant)
    case recordArtifact(RelayArtifact)
    case recordEvidence(RelayEvidence)
    case openFinding(RelayFinding)
    case resolveFinding(RelayFindingID, resolution: String, at: RelayInstant)
    case waiveFinding(RelayFindingID, decisionID: RelayDecisionID, at: RelayInstant)
    case requestDecision(RelayDecision)
    case recordDecision(
        RelayDecisionID,
        status: RelayDecisionStatus,
        rationale: String,
        at: RelayInstant
    )
    case approveAttempt(
        RelayAttemptID,
        resultCommit: RelayGitOID,
        resultWorkspaceDigest: RelayDigest,
        baton: RelayBaton,
        at: RelayInstant
    )
    case rejectAttempt(RelayAttemptID, baton: RelayBaton, at: RelayInstant)
    case failAttempt(RelayAttemptID, reason: String, at: RelayInstant)
    case interruptAttempt(RelayAttemptID, reason: String, at: RelayInstant)
    case requestCancellation(RelayAttemptID, at: RelayInstant)
    case finishCancellation(RelayAttemptID, at: RelayInstant)
    case waitForUser(reason: String)
    case resume
    case markLocalReady
    case beginDelivery
    case markDelivered
    case failTask(reason: String)
    case cancelTask(reason: String)
}
