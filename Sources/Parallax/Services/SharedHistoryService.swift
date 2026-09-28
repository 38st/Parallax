import Foundation

/// Synchronizes saved local conversations only. Provider databases, credentials,
/// settings, permissions, and account records are never copied.
enum SharedHistoryService {
    static let maximumTotalBytes = 256 * 1_024 * 1_024

    static func synchronize(
        _ participants: [SharedHistoryParticipant], knownIDs: Set<String>,
        baselines: [String: SharedHistoryBaseline] = [:],
        beforePublication: () throws -> Void = {}
    ) throws -> Set<String> {
        guard (2...8).contains(participants.count),
              Set(participants.map(\.storageID)).count == participants.count,
              Set(participants.map(\.provider)).count == 1,
              Set(participants.map { $0.files.rootPath }).count == participants.count else {
            throw SharedHistoryError.invalidSelection
        }
        var snapshots: [[String: SharedHistoryConversation]] = []
        var total = 0
        for participant in participants {
            let snapshot = try catalog(participant)
            guard knownIDs.isSubset(of: Set(snapshot.keys)) else { throw SharedHistoryError.removed }
            for (id, baseline) in baselines {
                guard let conversation = snapshot[id], baseline.isPrefix(of: conversation.normalized) else {
                    throw SharedHistoryError.conflict
                }
            }
            total += snapshot.values.reduce(0) { $0 + $1.original.count + $1.normalized.count }
            guard total <= maximumTotalBytes else { throw SharedHistoryError.unavailable }
            snapshots.append(snapshot)
        }
        var newest: [String: (Int, SharedHistoryConversation)] = [:]
        for (index, snapshot) in snapshots.enumerated() {
            for (id, candidate) in snapshot {
                guard let (_, current) = newest[id] else { newest[id] = (index, candidate); continue }
                guard candidate.claude?.workingDirectory == current.claude?.workingDirectory,
                      candidate.claude?.cliSessionID == current.claude?.cliSessionID else {
                    throw SharedHistoryError.conflict
                }
                if candidate.normalized.starts(with: current.normalized) {
                    if candidate.normalized.count > current.normalized.count
                        || (candidate.claude?.lastActivityAt ?? 0) > (current.claude?.lastActivityAt ?? 0) {
                        newest[id] = (index, candidate)
                    }
                } else if !current.normalized.starts(with: candidate.normalized) {
                    throw SharedHistoryError.conflict
                }
            }
        }
        guard newest.count <= 2_000 else { throw SharedHistoryError.unavailable }
        // All conflicts are resolved before the first write. Partial publication
        // is safe to retry: IDs are stable and each replacement retains old bytes.
        try beforePublication()
        for (index, participant) in participants.enumerated() {
            guard try catalog(participant) == snapshots[index] else { throw SharedHistoryError.changed }
        }
        for id in newest.keys.sorted() {
            guard let (sourceIndex, conversation) = newest[id] else { continue }
            let source = participants[sourceIndex]
            for (index, target) in participants.enumerated() where index != sourceIndex {
                let existing = snapshots[index][id]
                if existing?.normalized == conversation.normalized { continue }
                guard try source.files.readFile(at: conversation.path,
                    maximumBytes: ClaudeConversationCopyService.maximumTranscriptBytes) == conversation.original else {
                    throw SharedHistoryError.changed
                }
                if target.provider == "claude" {
                    try publishClaude(conversation, existing: existing, to: target)
                } else {
                    try target.files.replaceHistoryFile(at: existing?.path ?? conversation.path,
                        expected: existing?.original, with: conversation.original)
                }
            }
        }
        return Set(newest.keys)
    }

    static func catalog(_ participant: SharedHistoryParticipant) throws -> [String: SharedHistoryConversation] {
        if participant.provider == "claude" { return try claudeCatalog(participant) }
        guard participant.provider == "codex" else { throw SharedHistoryError.unavailable }
        return try codexCatalog(participant)
    }

    private static func claudeCatalog(_ participant: SharedHistoryParticipant) throws -> [String: SharedHistoryConversation] {
        let service = ClaudeConversationCopyService(files: participant.files)
        _ = try service.destinationNamespace()
        let catalog = try service.catalog()
        guard catalog.unavailableCount == 0 else { throw SharedHistoryError.unavailable }
        var result: [String: SharedHistoryConversation] = [:]
        var size = 0
        for conversation in catalog.conversations {
            let record = try participant.files.readFile(at: conversation.recordPath,
                maximumBytes: ClaudeConversationCopyService.maximumRecordBytes)
            let object = try JSONSerialization.jsonObject(with: record) as? [String: Any]
            if object?["isArchived"] as? Bool == true { continue }
            let path = try service.transcriptPath(for: conversation)
            let data = try participant.files.readFile(at: path,
                maximumBytes: ClaudeConversationCopyService.maximumTranscriptBytes)
            let normalized = try ClaudeConversationCopyService.importTranscript(data, conversation: conversation)
            size += data.count + normalized.count
            guard size <= maximumTotalBytes, result[conversation.sessionID] == nil else { throw SharedHistoryError.unavailable }
            result[conversation.sessionID] = SharedHistoryConversation(id: conversation.sessionID,
                path: path, original: data, normalized: normalized, claude: conversation)
        }
        return result
    }

    private static func publishClaude(
        _ value: SharedHistoryConversation, existing: SharedHistoryConversation?, to target: SharedHistoryParticipant
    ) throws {
        guard let conversation = value.claude else { throw SharedHistoryError.unavailable }
        let service = ClaudeConversationCopyService(files: target.files)
        let namespace = try service.destinationNamespace()
        let recordPath = try namespace.appending(conversation.sessionID + ".json")
        let oldRecord: Data?
        if let old = existing?.claude {
            let bytes = try target.files.readFile(at: recordPath, maximumBytes: ClaudeConversationCopyService.maximumRecordBytes)
            guard LibraryPersistence.sha256(bytes) == old.recordDigest,
                  let existing,
                  try target.files.readFile(at: existing.path,
                    maximumBytes: ClaudeConversationCopyService.maximumTranscriptBytes) == existing.original else {
                throw SharedHistoryError.changed
            }
            oldRecord = bytes
        } else { oldRecord = nil }
        let staging = try namespace.appending("imported-staging")
        if try target.files.itemState(at: staging) == .missing { try target.files.createDirectory(at: staging) }
        let transcript = try staging.appending(conversation.cliSessionID + "-" + LibraryPersistence.sha256(value.normalized) + ".jsonl")
        if try target.files.itemState(at: transcript) == .missing {
            try target.files.write(value.normalized, to: transcript)
        } else if try target.files.readFile(at: transcript,
            maximumBytes: ClaudeConversationCopyService.maximumTranscriptBytes) != value.normalized {
            throw SharedHistoryError.changed
        }
        // Only the native import allowlist crosses accounts. In particular,
        // permission approvals, spawn seeds and MCP configuration do not.
        let record: [String: Any] = [
            "sessionId": conversation.sessionID, "cliSessionId": conversation.cliSessionID,
            "cwd": conversation.workingDirectory, "originCwd": conversation.workingDirectory,
            "title": conversation.title, "createdAt": conversation.createdAt,
            "lastActivityAt": conversation.lastActivityAt, "isArchived": false,
            "importedFrom": "local-1p-code",
            "stagedTranscriptPath": target.files.rootPath + "/" + transcript.components.joined(separator: "/"),
        ]
        try target.files.replaceHistoryFile(at: recordPath, expected: oldRecord,
            with: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
    }
}
