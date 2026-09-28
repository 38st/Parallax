import Foundation
import Observation

enum LaunchHistoryState: String, Codable, Sendable {
    case opening
    case running
    case closed
    case failed
    case cancelled

    var isTerminal: Bool {
        switch self {
        case .closed, .failed, .cancelled:
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

extension LaunchHistoryEntry {
    enum CodingKeys: String, CodingKey {
        case requestID, applicationID, applicationStorageID, profileID, profileStorageID
        case applicationName, applicationBundleIdentifier, profileName, requestedAt, startedAt, endedAt
        case state, process, observedProcessIdentifier, terminationDisposition, updatedAt, wasCancelled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try values.decode(UUID.self, forKey: .requestID)
        applicationID = try values.decode(UUID.self, forKey: .applicationID)
        applicationStorageID = try values.decode(UUID.self, forKey: .applicationStorageID)
        profileID = try values.decode(UUID.self, forKey: .profileID)
        profileStorageID = try values.decode(UUID.self, forKey: .profileStorageID)
        applicationName = try values.decode(String.self, forKey: .applicationName)
        profileName = try values.decode(String.self, forKey: .profileName)
        requestedAt = try values.decode(Date.self, forKey: .requestedAt)
        applicationBundleIdentifier = try values.decodeIfPresent(String.self, forKey: .applicationBundleIdentifier)
        startedAt = try values.decodeIfPresent(Date.self, forKey: .startedAt)
        endedAt = try values.decodeIfPresent(Date.self, forKey: .endedAt)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt)
        process = try values.decodeIfPresent(ProcessStartIdentity.self, forKey: .process)
        observedProcessIdentifier = try values.decodeIfPresent(pid_t.self, forKey: .observedProcessIdentifier)
        terminationDisposition = try values.decodeIfPresent(ManagedProcessTerminationDisposition.self, forKey: .terminationDisposition)
        let stored = try values.decode(LaunchHistoryState.self, forKey: .state)
        let cancelled = try values.decodeIfPresent(Bool.self, forKey: .wasCancelled) == true
        state = stored == .closed && cancelled ? .cancelled : stored
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(requestID, forKey: .requestID)
        try values.encode(applicationID, forKey: .applicationID)
        try values.encode(applicationStorageID, forKey: .applicationStorageID)
        try values.encode(profileID, forKey: .profileID)
        try values.encode(profileStorageID, forKey: .profileStorageID)
        try values.encode(applicationName, forKey: .applicationName)
        try values.encode(profileName, forKey: .profileName)
        try values.encode(requestedAt, forKey: .requestedAt)
        try values.encodeIfPresent(applicationBundleIdentifier, forKey: .applicationBundleIdentifier)
        try values.encodeIfPresent(startedAt, forKey: .startedAt)
        try values.encodeIfPresent(endedAt, forKey: .endedAt)
        try values.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try values.encodeIfPresent(process, forKey: .process)
        try values.encodeIfPresent(observedProcessIdentifier, forKey: .observedProcessIdentifier)
        try values.encodeIfPresent(terminationDisposition, forKey: .terminationDisposition)
        try values.encode(state == .cancelled ? LaunchHistoryState.closed : state, forKey: .state)
        if state == .cancelled { try values.encode(true, forKey: .wasCancelled) }
    }
}
