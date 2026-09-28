import Foundation

struct SharedHistoryGroup: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    let applicationStorageID: UUID
    let provider: String
    var profileStorageIDs: [UUID]
    var rootPaths: [String: String] = [:]
    // A missing previously shared chat is a deletion, not a new empty account.
    var knownConversationIDs: Set<String> = []
    var baselines: [String: SharedHistoryBaseline] = [:]
}

struct SharedHistoryBaseline: Codable, Equatable, Sendable {
    let byteCount: Int
    let digest: String

    init(_ data: Data) {
        byteCount = data.count
        digest = LibraryPersistence.sha256(data)
    }

    func isPrefix(of data: Data) -> Bool {
        byteCount > 0 && data.count >= byteCount
            && LibraryPersistence.sha256(Data(data.prefix(byteCount))) == digest
    }
}

enum SharedHistoryError: LocalizedError, Equatable {
    case unavailable, changed, conflict, removed, running, invalidSelection, indexFailed

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "Shared history is unavailable for this storage or conversation format. Use separate histories until it is supported.")
        case .changed:
            String(localized: "The shared history settings or saved chats changed. Close the app and try again.")
        case .conflict:
            String(localized: "This chat was changed separately in linked accounts. Sharing stopped to preserve both versions. Turn off sharing to review them separately.")
        case .removed:
            String(localized: "A previously shared chat is missing or archived in one account. Sharing stopped to avoid restoring a chat you removed. Turn off sharing to continue separately.")
        case .running:
            String(localized: "Quit all windows of this app before switching accounts with shared history.")
        case .invalidSelection:
            String(localized: "Choose between two and eight spaces for shared history. A space can belong to only one group.")
        case .indexFailed:
            String(localized: "Codex could not refresh its local chat list. Saved chats were retained. Close Codex and retry, or turn off sharing.")
        }
    }
}

struct SharedHistoryConversation: Sendable, Equatable {
    let id: String
    let path: SecureManagedPath
    let original: Data
    let normalized: Data
    let claude: ClaudeConversation?
}

struct SharedHistoryParticipant: Sendable {
    let storageID: UUID
    let files: SecureManagedFileSystem
    let provider: String
}
