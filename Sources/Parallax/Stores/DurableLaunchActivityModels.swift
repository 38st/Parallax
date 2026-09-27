import Darwin
import CryptoKit
import Foundation

enum DurableLaunchCompletion: String, Codable, Sendable {
    case failed
    case terminated
}

struct DurableLaunchArtifact: Sendable {
    enum State: Sendable {
        case requestOnly(owner: ProcessStartIdentity)
        case opening
        case running(ProcessStartIdentity)
        case completed
        case corrupt
    }

    let requestID: UUID?
    let identity: ProfileActivityIdentity?
    let state: State
    let directoryURL: URL
    var isDataOperation = false
    var ownerProcess: ProcessStartIdentity?
}

enum DurableLaunchActivityStoreError: LocalizedError {
    case activityBusy
    case invalidRoot(String)
    case requestAlreadyExists(UUID)
    case profileAlreadyActive
    case processAlreadyTracked(pid_t)
    case missingRequest(UUID)
    case immutableMarkerExists(String)
    case invalidProcessIdentity(pid_t)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .activityBusy:
            String(localized: "Launch activity is being updated. Try again shortly.")
        case .invalidRoot(let path):
            String(localized: "The active-launch journal is unsafe at \(path).")
        case .requestAlreadyExists(let requestID):
            String(localized: "Launch request \(requestID.uuidString) already exists.")
        case .profileAlreadyActive:
            String(localized: "This profile is already launching or running.")
        case .processAlreadyTracked(let processIdentifier):
            String(
                localized:
                    "Process \(processIdentifier) is already attributed to another profile."
            )
        case .missingRequest(let requestID):
            String(localized: "Launch request \(requestID.uuidString) is missing.")
        case .immutableMarkerExists(let name):
            String(localized: "The immutable launch marker \(name) already exists.")
        case .invalidProcessIdentity(let processIdentifier):
            String(localized: "Process \(processIdentifier) has no verifiable start identity.")
        case .persistence(let detail):
            String(localized: "The active-launch journal could not be updated: \(detail)")
        }
    }
}
