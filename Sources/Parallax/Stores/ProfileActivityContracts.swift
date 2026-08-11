import Darwin
import Foundation

struct ProfileActivityIdentity: Hashable, Sendable {
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileID: UUID
    let profileStorageID: UUID
}

struct ConcurrentProfileLaunchRiskAcknowledgement:
    Equatable,
    Sendable
{
    /// Concurrent processes writing one browser/Codex profile can corrupt or
    /// destabilize that profile. Callers must surface that risk and record an
    /// affirmative acknowledgement before constructing an effective override.
    let acknowledgesProfileDataCorruptionRisk: Bool
}

enum ConcurrentProfileLaunchPolicy: Equatable, Sendable {
    case deny
    case expertOverride(ConcurrentProfileLaunchRiskAcknowledgement)
}

enum ProfileActivityRegistryError: LocalizedError {
    case requestIdentityConflict(requestID: UUID)
    case profileAlreadyActive(
        applicationStorageID: UUID,
        profileStorageID: UUID
    )
    case expertOverrideRiskNotAcknowledged
    case processExitedBeforeRegistration(pid_t)
    case processIdentityAmbiguous(pid_t)
    case processIdentityChanged(pid_t)

    var errorDescription: String? {
        switch self {
        case .requestIdentityConflict(let requestID):
            String(
                localized:
                    "Launch request \(requestID.uuidString) is already tracking a different profile."
            )
        case .profileAlreadyActive:
            String(
                localized:
                    "This profile is already launching or running."
            )
        case .expertOverrideRiskNotAcknowledged:
            String(
                localized:
                    "Launching this profile concurrently can corrupt profile data or destabilize both processes. The expert override requires explicit acknowledgement of that risk."
            )
        case .processExitedBeforeRegistration(let processIdentifier):
            String(localized: "Process \(processIdentifier) exited before launch tracking completed.")
        case .processIdentityAmbiguous(let processIdentifier),
             .processIdentityChanged(let processIdentifier):
            String(
                localized:
                    "Process \(processIdentifier) does not have a verifiable start identity."
            )
        }
    }
}

struct ProfileActivityReconciliationReport: Equatable, Sendable {
    var recoveredLiveCount = 0
    var removedDeadCount = 0
    var ambiguousCount = 0
    var globalAmbiguousCount = 0
}

struct ProfileRunningProcess: Equatable, Sendable {
    let requestID: UUID
    let identity: ProfileActivityIdentity
    let process: ProcessStartIdentity
}
