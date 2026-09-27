import Foundation
import Observation

enum LaunchHistoryState: String, Codable, Sendable {
    case opening
    case running
    case closed
    case failed

    var isTerminal: Bool {
        switch self {
        case .closed, .failed:
            true
        case .opening, .running:
            false
        }
    }
}

struct LaunchHistoryEntry:
    Identifiable,
    Codable,
    Equatable,
    Hashable,
    Sendable
{
    var id: UUID { requestID }

    let requestID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileID: UUID
    let profileStorageID: UUID
    var applicationName: String
    var applicationBundleIdentifier: String?
    var profileName: String
    let requestedAt: Date
    var startedAt: Date?
    var endedAt: Date?
    var state: LaunchHistoryState
    var process: ProcessStartIdentity?
    var observedProcessIdentifier: pid_t? = nil
    var terminationDisposition:
        ManagedProcessTerminationDisposition? = nil
    var updatedAt: Date? = nil

    var processIdentifier: pid_t? {
        process?.processIdentifier ?? observedProcessIdentifier
    }

    var duration: TimeInterval? {
        guard let startedAt else { return nil }
        let end = endedAt ?? Date()
        return max(0, end.timeIntervalSince(startedAt))
    }
}

enum LaunchHistoryStoreError: LocalizedError {
    case invalidDocument
    case unsupportedSchema(Int)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            String(localized: "Recent activity could not be read.")
        case .unsupportedSchema(let version):
            String(
                localized:
                    "Recent activity uses unsupported format \(version)."
            )
        case .persistence(let detail):
            String(
                localized:
                    "Recent activity could not be saved: \(detail)"
            )
        }
    }
}
