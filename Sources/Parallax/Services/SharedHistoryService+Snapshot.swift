import Foundation

/// A scan retains identities and hashes, never all of the group's transcripts.
struct SharedHistorySnapshot: Equatable, Sendable {
    let id: String
    let path: SecureManagedPath
    let originalDigest: String
    let baseline: SharedHistoryBaseline
    let claude: ClaudeConversation?

    init(_ conversation: SharedHistoryConversation) {
        id = conversation.id
        path = conversation.path
        originalDigest = LibraryPersistence.sha256(conversation.original)
        baseline = SharedHistoryBaseline(conversation.normalized)
        claude = conversation.claude
    }
}

extension SharedHistoryService {
    static func snapshot(
        _ participant: SharedHistoryParticipant,
        baselines: [String: SharedHistoryBaseline] = [:]
    ) throws -> [String: SharedHistorySnapshot] {
        var result: [String: SharedHistorySnapshot] = [:]
        try forEachConversation(participant) { conversation in
            if let baseline = baselines[conversation.id], !baseline.isPrefix(of: conversation.normalized) {
                throw SharedHistoryError.conflict
            }
            result[conversation.id] = SharedHistorySnapshot(conversation)
        }
        return result
    }

    /// Revalidates the exact bytes and Claude record before comparison or writing.
    static func load(
        _ snapshot: SharedHistorySnapshot, from participant: SharedHistoryParticipant
    ) throws -> SharedHistoryConversation {
        let data = try participant.files.readFile(at: snapshot.path,
            maximumBytes: ClaudeConversationCopyService.maximumTranscriptBytes)
        guard LibraryPersistence.sha256(data) == snapshot.originalDigest else { throw SharedHistoryError.changed }
        let normalized: Data
        if let conversation = snapshot.claude {
            let service = ClaudeConversationCopyService(files: participant.files)
            let record = try participant.files.readFile(at: conversation.recordPath,
                maximumBytes: ClaudeConversationCopyService.maximumRecordBytes)
            guard participant.provider == "claude",
                  try ClaudeConversationCopyService.conversation(data: record, path: conversation.recordPath) == conversation,
                  try service.transcriptPath(for: conversation) == snapshot.path else { throw SharedHistoryError.changed }
            normalized = try ClaudeConversationCopyService.importTranscript(data, conversation: conversation)
        } else {
            guard participant.provider == "codex" else { throw SharedHistoryError.changed }
            let (id, value) = try codexTranscript(data)
            guard id == snapshot.id else { throw SharedHistoryError.changed }
            normalized = value
        }
        let value = SharedHistoryConversation(id: snapshot.id, path: snapshot.path,
            original: data, normalized: normalized, claude: snapshot.claude)
        guard SharedHistorySnapshot(value) == snapshot else { throw SharedHistoryError.changed }
        return value
    }
}
