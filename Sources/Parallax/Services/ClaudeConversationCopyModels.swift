import Foundation

struct ClaudeConversation: Identifiable, Equatable, Sendable {
    let recordPath: SecureManagedPath
    let recordDigest: String
    let sessionID: String
    let cliSessionID: String
    let title: String
    let workingDirectory: String
    let createdAt: Double
    let lastActivityAt: Double
    let stagedTranscriptPath: String?
    var id: String { recordPath.components.joined(separator: "/") }
}

struct ClaudeConversationCatalog: Sendable {
    var conversations: [ClaudeConversation] = []
    var unavailableCount = 0
}

struct ClaudeConversationCopyPlan: Equatable, Sendable {
    let conversation: ClaudeConversation
    let transcriptPath: SecureManagedPath
    let transcriptDigest: String
    let transcript: Data
    let sourceRoot: String
    let destinationRoot: String
    let destinationNamespace: SecureManagedPath
    let destinationNamespaceIdentity: SecureManagedItemIdentity
    let copyID: UUID
    let record: Data
    let stagedTranscript: SecureManagedPath
    let stagedRecord: SecureManagedPath
    let publishedRecord: SecureManagedPath
}

enum ClaudeConversationCopyOutcome: Sendable, Equatable {
    case copied
    case alreadyCopied
}

enum ClaudeConversationCopyError: LocalizedError, Equatable {
    case unavailable
    case unsupportedFormat
    case ambiguousAccount
    case missingTranscript
    case changed
    case sameSpace
    case externalStorage
    case running
    case interrupted

    var errorDescription: String? {
        switch self {
        case .unavailable:
            String(localized: "Open Claude in this space, sign in, and create a local Code conversation before copying chats here.")
        case .unsupportedFormat:
            String(localized: "This conversation uses an unsupported or incomplete Claude session format. Its data has not been changed.")
        case .ambiguousAccount:
            String(localized: "This space contains several Claude account histories. Copying is unavailable because the destination account cannot be identified safely.")
        case .missingTranscript:
            String(localized: "The saved transcript is missing or ambiguous. Only local Code conversations stored in this space can be copied.")
        case .changed:
            String(localized: "The conversation or space changed. Refresh the conversation list and review the copy again.")
        case .sameSpace:
            String(localized: "Choose a different Claude space for the conversation copy.")
        case .externalStorage:
            String(localized: "Conversation copying requires separate Parallax-managed Claude data and configuration folders.")
        case .running:
            String(localized: "Quit all Claude windows before copying a conversation, then try again.")
        case .interrupted:
            String(localized: "The copy could not be confirmed. Refresh and retry the same conversation to finish it. Existing conversations were not replaced; prepared copy files may remain.")
        }
    }
}
