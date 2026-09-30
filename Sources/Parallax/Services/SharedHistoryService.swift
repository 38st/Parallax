import Foundation

/// Synchronizes saved local conversations only. Provider databases, credentials,
/// settings, permissions, and account records are never copied.
enum SharedHistoryService {
    static func claudeArtifactReferenceCount(_ participants: [SharedHistoryParticipant]) throws -> Int {
        var urls = Set<String>()
        for participant in participants where participant.provider == "claude" {
            try Task.checkCancellation()
            try forEachConversation(participant) { conversation in
                try Task.checkCancellation()
                urls.formUnion(ClaudeArtifactReferenceScanner.scan(conversation.original).map(\.url))
            }
        }
        return urls.count
    }

    static func synchronize(
        _ participants: [SharedHistoryParticipant], knownIDs: Set<String>,
        baselines: [String: SharedHistoryBaseline] = [:],
        beforePublication: () throws -> Void = {}
    ) throws -> Set<String> {
        try synchronizeResult(participants, knownIDs: knownIDs, baselines: baselines,
            beforePublication: beforePublication).ids
    }

    static func synchronizeResult(
        _ participants: [SharedHistoryParticipant], knownIDs: Set<String>,
        baselines: [String: SharedHistoryBaseline] = [:],
        validated: [String: [String: SharedHistoryValidation]] = [:],
        beforePublication: () throws -> Void = {}
    ) throws -> SharedHistorySynchronization {
        guard (2...8).contains(participants.count),
              Set(participants.map(\.storageID)).count == participants.count,
              Set(participants.map(\.provider)).count == 1,
              Set(participants.map { $0.files.rootPath }).count == participants.count else {
            throw SharedHistoryError.invalidSelection
        }
        var snapshots: [[String: SharedHistorySnapshot]] = []
        for participant in participants {
            let snapshot = try snapshot(participant, baselines: baselines,
                validated: validated[participant.storageID.uuidString] ?? [:])
            guard knownIDs.isSubset(of: Set(snapshot.keys)) else { throw SharedHistoryError.removed }
            guard Set(baselines.keys).isSubset(of: Set(snapshot.keys)) else { throw SharedHistoryError.conflict }
            snapshots.append(snapshot)
        }
        var newest: [String: (Int, SharedHistorySnapshot)] = [:]
        for (index, snapshot) in snapshots.enumerated() {
            for (id, candidate) in snapshot {
                guard let (currentIndex, current) = newest[id] else { newest[id] = (index, candidate); continue }
                guard candidate.claude?.workingDirectory == current.claude?.workingDirectory,
                      candidate.claude?.cliSessionID == current.claude?.cliSessionID else {
                    throw SharedHistoryError.conflict
                }
                if candidate.baseline == current.baseline {
                    if (candidate.claude?.lastActivityAt ?? 0) > (current.claude?.lastActivityAt ?? 0) {
                        newest[id] = (index, candidate)
                    }
                    continue
                }
                try autoreleasepool {
                    let candidateValue = try load(candidate, from: participants[index])
                    let currentValue = try load(current, from: participants[currentIndex])
                    if candidateValue.normalized.starts(with: currentValue.normalized) {
                        newest[id] = (index, candidate)
                    } else if !currentValue.normalized.starts(with: candidateValue.normalized) {
                        throw SharedHistoryError.conflict
                    }
                }
            }
        }
        // All conflicts are resolved before the first write. Partial publication
        // is safe to retry: IDs are stable and each replacement retains old bytes.
        try beforePublication()
        for (index, participant) in participants.enumerated() {
            guard try snapshot(participant, validated: snapshots[index].compactMapValues(\.validation)) == snapshots[index]
            else { throw SharedHistoryError.changed }
        }
        for id in newest.keys.sorted() {
            guard let (sourceIndex, conversation) = newest[id] else { continue }
            let source = participants[sourceIndex]
            // Repair older staged filenames too. Keep the source last so its
            // saved record remains valid while other participants read it.
            for index in participants.indices.filter({ $0 != sourceIndex }) + [sourceIndex] {
                let target = participants[index]
                let existing = snapshots[index][id]
                let needsPathRepair = existing?.claude?.stagedTranscriptPath != nil
                    && existing?.path.components.last != existing?.claude.map { $0.cliSessionID + ".jsonl" }
                if existing?.baseline == conversation.baseline && !needsPathRepair { continue }
                try autoreleasepool {
                    let value = try load(conversation, from: source)
                    let oldValue = try existing.map { try load($0, from: target) }
                    if target.provider == "claude" {
                        snapshots[index][id] = try publishClaude(value, existing: oldValue, to: target)
                    } else {
                        try target.files.replaceHistoryFile(at: existing?.path ?? conversation.path,
                            expected: oldValue?.original, with: value.original)
                    }
                }
            }
        }
        let validation = participants.first?.provider == "claude"
            ? Dictionary(uniqueKeysWithValues: participants.enumerated().map {
                ($0.element.storageID.uuidString, snapshots[$0.offset].compactMapValues(\.validation))
            }) : nil
        return SharedHistorySynchronization(ids: Set(newest.keys),
            baselines: newest.mapValues { $0.1.baseline }, claudeValidation: validation)
    }

    static func catalog(_ participant: SharedHistoryParticipant) throws -> [String: SharedHistoryConversation] {
        var result: [String: SharedHistoryConversation] = [:]
        try forEachConversation(participant) { conversation in
            result[conversation.id] = conversation
        }
        return result
    }

    static func forEachConversation(
        _ participant: SharedHistoryParticipant,
        visit: (SharedHistoryConversation) throws -> Void
    ) throws {
        if participant.provider == "claude" { return try forEachClaudeConversation(participant, visit: visit) }
        guard participant.provider == "codex" else { throw SharedHistoryError.unavailable }
        try forEachCodexConversation(participant, visit: visit)
    }

    private static func forEachClaudeConversation(
        _ participant: SharedHistoryParticipant,
        visit: (SharedHistoryConversation) throws -> Void
    ) throws {
        let service = ClaudeConversationCopyService(files: participant.files)
        _ = try service.destinationNamespace()
        let catalog = try service.catalog()
        guard catalog.unavailableCount == 0 else { throw SharedHistoryError.unavailable }
        var ids = Set<String>()
        for conversation in catalog.conversations {
            try autoreleasepool {
                let record = try participant.files.readFile(at: conversation.recordPath)
                guard LibraryPersistence.sha256(record) == conversation.recordDigest else { throw SharedHistoryError.changed }
                let object = try JSONSerialization.jsonObject(with: record) as? [String: Any]
                if object?["isArchived"] as? Bool == true { return }
                let path = try service.transcriptPath(for: conversation)
                let data = try participant.files.readFile(at: path)
                let normalized = try ClaudeConversationCopyService.importTranscript(data, conversation: conversation)
                guard ids.insert(conversation.sessionID).inserted else { throw SharedHistoryError.unavailable }
                try visit(SharedHistoryConversation(id: conversation.sessionID,
                    path: path, original: data, normalized: normalized, claude: conversation))
            }
        }
    }

    private static func publishClaude(
        _ value: SharedHistoryConversation, existing: SharedHistoryConversation?, to target: SharedHistoryParticipant
    ) throws -> SharedHistorySnapshot {
        guard let conversation = value.claude else { throw SharedHistoryError.unavailable }
        let service = ClaudeConversationCopyService(files: target.files)
        let namespace = try service.destinationNamespace()
        let recordPath = try namespace.appending(conversation.sessionID + ".json")
        let oldRecord: Data?
        if let old = existing?.claude {
            let bytes = try target.files.readFile(at: recordPath)
            guard LibraryPersistence.sha256(bytes) == old.recordDigest,
                  let existing,
                  try target.files.readFile(at: existing.path) == existing.original else {
                throw SharedHistoryError.changed
            }
            oldRecord = bytes
        } else { oldRecord = nil }
        let staging = try namespace.appending("imported-staging")
        if try target.files.itemState(at: staging) == .missing { try target.files.createDirectory(at: staging) }
        // Desktop resolves dirname(stagedTranscriptPath)/<cliSessionId>.jsonl.
        // Put the digest in a parent directory so versions remain immutable and
        // the native transcript reader can find the messages before resuming.
        let revision = try staging.appending(conversation.cliSessionID + "-" + LibraryPersistence.sha256(value.normalized))
        if try target.files.itemState(at: revision) == .missing { try target.files.createDirectory(at: revision) }
        let transcript = try revision.appending(conversation.cliSessionID + ".jsonl")
        if try target.files.itemState(at: transcript) == .missing {
            try target.files.write(value.normalized, to: transcript)
        } else if try target.files.readFile(at: transcript) != value.normalized {
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
        let recordData = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try target.files.replaceHistoryFile(at: recordPath, expected: oldRecord, with: recordData)
        return SharedHistorySnapshot(SharedHistoryConversation(id: value.id, path: transcript,
            original: value.normalized, normalized: value.normalized,
            claude: try ClaudeConversationCopyService.conversation(data: recordData, path: recordPath)))
    }
}
