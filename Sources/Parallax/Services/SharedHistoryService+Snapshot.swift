import Foundation

/// A scan retains identities and hashes, never all of the group's transcripts.
struct SharedHistorySnapshot: Equatable, Sendable {
    let id: String
    let path: SecureManagedPath
    let originalDigest: String
    let baseline: SharedHistoryBaseline
    let claude: ClaudeConversation?

    init(id: String, path: SecureManagedPath, originalDigest: String,
         baseline: SharedHistoryBaseline, claude: ClaudeConversation?) {
        self.id = id
        self.path = path
        self.originalDigest = originalDigest
        self.baseline = baseline
        self.claude = claude
    }

    init(_ conversation: SharedHistoryConversation) {
        id = conversation.id
        path = conversation.path
        originalDigest = LibraryPersistence.sha256(conversation.original)
        baseline = SharedHistoryBaseline(conversation.normalized)
        claude = conversation.claude
    }

    var validation: SharedHistoryValidation? {
        guard let claude else { return nil }
        return SharedHistoryValidation(recordPath: claude.recordPath.components, recordDigest: claude.recordDigest,
            transcriptPath: path.components, transcriptDigest: originalDigest, baseline: baseline)
    }
}

extension SharedHistoryService {
    static func snapshot(
        _ participant: SharedHistoryParticipant,
        baselines: [String: SharedHistoryBaseline] = [:],
        validated: [String: SharedHistoryValidation] = [:]
    ) throws -> [String: SharedHistorySnapshot] {
        if participant.provider == "claude" {
            return try claudeSnapshot(participant, baselines: baselines, validated: validated)
        }
        var result: [String: SharedHistorySnapshot] = [:]
        try forEachConversation(participant) { conversation in
            if let baseline = baselines[conversation.id], !baseline.isPrefix(of: conversation.normalized) {
                throw SharedHistoryError.conflict
            }
            result[conversation.id] = SharedHistorySnapshot(conversation)
        }
        return result
    }

    private static func claudeSnapshot(
        _ participant: SharedHistoryParticipant, baselines: [String: SharedHistoryBaseline],
        validated: [String: SharedHistoryValidation]
    ) throws -> [String: SharedHistorySnapshot] {
        let service = ClaudeConversationCopyService(files: participant.files)
        _ = try service.destinationNamespace()
        let catalog = try service.catalog()
        guard catalog.unavailableCount == 0 else { throw SharedHistoryError.unavailable }
        var result: [String: SharedHistorySnapshot] = [:]
        for conversation in catalog.conversations {
            try autoreleasepool {
                let record = try participant.files.readFile(at: conversation.recordPath)
                guard LibraryPersistence.sha256(record) == conversation.recordDigest else { throw SharedHistoryError.changed }
                let object = try JSONSerialization.jsonObject(with: record) as? [String: Any]
                if object?["isArchived"] as? Bool == true { return }
                guard result[conversation.sessionID] == nil else { throw SharedHistoryError.unavailable }
                let path = try service.transcriptPath(for: conversation)
                let data = try participant.files.readFile(at: path)
                let digest = LibraryPersistence.sha256(data)
                let baseline: SharedHistoryBaseline
                if let cached = validated[conversation.sessionID],
                   cached.recordPath == conversation.recordPath.components,
                   cached.recordDigest == conversation.recordDigest,
                   cached.transcriptPath == path.components, cached.transcriptDigest == digest,
                   baselines[conversation.sessionID] == nil || baselines[conversation.sessionID] == cached.baseline {
                    baseline = cached.baseline
                } else {
                    let normalized = try ClaudeConversationCopyService.importTranscript(data, conversation: conversation)
                    if let previous = baselines[conversation.sessionID], !previous.isPrefix(of: normalized) {
                        throw SharedHistoryError.conflict
                    }
                    baseline = SharedHistoryBaseline(normalized)
                }
                result[conversation.sessionID] = SharedHistorySnapshot(id: conversation.sessionID,
                    path: path, originalDigest: digest, baseline: baseline, claude: conversation)
            }
        }
        return result
    }

    /// Revalidates the exact bytes and Claude record before comparison or writing.
    static func load(
        _ snapshot: SharedHistorySnapshot, from participant: SharedHistoryParticipant
    ) throws -> SharedHistoryConversation {
        let data = try participant.files.readFile(at: snapshot.path)
        guard LibraryPersistence.sha256(data) == snapshot.originalDigest else { throw SharedHistoryError.changed }
        let normalized: Data
        if let conversation = snapshot.claude {
            let service = ClaudeConversationCopyService(files: participant.files)
            let record = try participant.files.readFile(at: conversation.recordPath)
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
