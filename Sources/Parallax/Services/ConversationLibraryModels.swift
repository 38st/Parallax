import Foundation

/// Provider-neutral identities are kept separate from native storage paths.
/// Version one deliberately admits only managed Claude local Code histories.
struct ConversationLibrary: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let id: UUID
    let applicationStorageID: UUID
    var generation: UInt64 = 0
    var bindings: [String: ConversationAccountBinding]
    var conversations: [String: LibraryConversation] = [:]
    var unavailableRecords: [String: [String: String]] = [:]
    var activeProfileID: UUID?
    var selectedConversationID: String?
    var handoff: ConversationHandoff?
}

struct ConversationAccountBinding: Codable, Equatable, Sendable {
    let profileStorageID: UUID
    let rootPath: String
    let namespace: [String]
    let rootFileID: UInt64
    let rootVolumeID: UInt64
    let namespaceFileID: UInt64
    /// A user-confirmed label, never represented as provider authentication.
    let label: String
    /// Records outside the binding at enrollment; newly written foreign
    /// records require review. Scheduling-only folders are not conversations.
    var foreignRecords: [String: String] = [:]
}

struct LibraryConversation: Codable, Equatable, Sendable, Identifiable {
    let id: String
    var title: String
    var head: String
    var revisions: [String: ConversationRevision]
    var projections: [String: ConversationProjection] = [:]
    var problems: [String: ConversationProblem] = [:]
    var archived = false
}

struct ConversationRevision: Codable, Equatable, Sendable {
    let digest: String
    let originalDigest: String
    let parent: String?
    let sourceProfileID: UUID
    let sourceAccountID: String
    let sourceOrganizationID: String
    let cliSessionID: String
    let workingDirectory: String
    let createdAt: Double
    let lastActivityAt: Double
}

struct ConversationProjection: Codable, Equatable, Sendable {
    var revision: String
    var recordDigest: String
    var transcriptDigest: String
    var disposition: ConversationDisposition = .present
    var restoreRequested = false
}

enum ConversationDisposition: String, Codable, Sendable {
    case present, missing, archived
}

enum ConversationProblem: String, Codable, Sendable {
    case unavailable, conflict, missing, archived

    var message: String {
        switch self {
        case .unavailable: String(localized: "This conversation could not be read. Its saved versions are retained.")
        case .conflict: String(localized: "This conversation has different saved versions. Choose a version before continuing.")
        case .missing: String(localized: "This conversation was removed from this account. Restore it explicitly to continue here.")
        case .archived: String(localized: "This conversation is archived in this account. Restore it explicitly to continue here.")
        }
    }
}

struct ConversationHandoff: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable {
        case waiting, capturing, preparing, ready, opening
    }
    let id: UUID
    let sourceProfileID: UUID?
    let targetProfileID: UUID
    let conversationID: String?
    var phase: Phase
}

enum ConversationLibraryError: LocalizedError, Equatable {
    case unavailable, changed, accountChanged, busy, selectedConversation, corrupt, unsupported, waitingForQuit

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "The shared conversation library is unavailable. Reconnect its storage and try again.")
        case .changed: String(localized: "The conversation library changed. Refresh it before trying again.")
        case .accountChanged: String(localized: "This space needs its account binding reviewed. Confirm the signed-in account in Claude, then reconnect it to the library.")
        case .busy: String(localized: "Another account switch is unfinished. Retry or recover that switch first.")
        case .selectedConversation: String(localized: "The selected conversation needs review. Choose a saved version or another conversation before switching.")
        case .corrupt: String(localized: "The conversation library failed its integrity check. Saved files were retained for recovery.")
        case .unsupported: String(localized: "This conversation library requires a newer version of Parallax.")
        case .waitingForQuit: String(localized: "Claude is still running. Finish active work and quit Claude, then retry the switch.")
        }
    }
}
