import Foundation

extension ClaudeConversationCopyService {
    func prepare(
        _ conversation: ClaudeConversation,
        destination: ClaudeConversationCopyService
    ) throws -> ClaudeConversationCopyPlan {
        guard files.rootIdentity != destination.files.rootIdentity else {
            throw ClaudeConversationCopyError.sameSpace
        }
        let currentRecord = try files.readFile(at: conversation.recordPath, maximumBytes: Self.maximumRecordBytes)
        guard try Self.conversation(data: currentRecord, path: conversation.recordPath) == conversation else {
            throw ClaudeConversationCopyError.changed
        }
        let path = try transcriptPath(for: conversation)
        let original = try files.readFile(at: path, maximumBytes: Self.maximumTranscriptBytes)
        let transcript = try Self.importTranscript(original, conversation: conversation)
        let namespace = try destination.destinationNamespace()
        guard case .present(let identity) = try destination.files.itemState(at: namespace) else {
            throw ClaudeConversationCopyError.changed
        }
        // Stable IDs make a retry resume the same prepared copy after a crash.
        // Length-prefixing prevents path/content separators from aliasing inputs.
        var fingerprint = LengthPrefixedSHA256FingerprintBuilder(domain: "parallax.claude-conversation-copy", version: 1)
        for (key, value) in [
            ("source", files.rootPath), ("destination", destination.files.rootPath),
            ("record", conversation.id), ("recordDigest", conversation.recordDigest),
            ("transcriptDigest", LibraryPersistence.sha256(original)),
            ("namespace", namespace.components.joined(separator: "/")),
        ] { fingerprint.append(value, for: key) }
        let hex = String(fingerprint.finalizeHexDigest().prefix(32))
        var characters = Array(hex)
        characters[12] = "5"
        characters[16] = "8"
        let uuidText = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
            .map { String(characters[$0]) }.joined(separator: "-")
        guard let copyID = UUID(uuidString: uuidText) else { throw ClaudeConversationCopyError.unsupportedFormat }
        let id = copyID.uuidString.lowercased()
        let staging = try namespace.appending("imported-staging")
        let stagedTranscript = try staging.appending(id + ".jsonl")
        let stagedRecord = try staging.appending("parallax-" + id + ".json")
        let publishedRecord = try namespace.appending("local_" + id + ".json")
        let record: [String: Any] = [
            "sessionId": "local_" + id, "cliSessionId": id,
            "cwd": conversation.workingDirectory, "originCwd": conversation.workingDirectory,
            "title": String(localized: "\(conversation.title) (copy)"),
            "createdAt": conversation.createdAt, "lastActivityAt": conversation.lastActivityAt,
            "isArchived": false, "importedFrom": "local-1p-code",
            "stagedTranscriptPath": destination.files.rootPath + "/" + stagedTranscript.components.joined(separator: "/"),
        ]
        return ClaudeConversationCopyPlan(
            conversation: conversation, transcriptPath: path, transcriptDigest: LibraryPersistence.sha256(original),
            transcript: transcript, sourceRoot: files.rootPath, destinationRoot: destination.files.rootPath,
            destinationNamespace: namespace, destinationNamespaceIdentity: identity, copyID: copyID,
            record: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
            stagedTranscript: stagedTranscript, stagedRecord: stagedRecord, publishedRecord: publishedRecord
        )
    }

    /// Mirrors the installed provider's import boundary: only records with a
    /// working directory, remove the old session binding and subagent link.
    /// Permissions, hooks, scheduling and provider settings are never imported
    /// from the desktop session record. Claude presents its own import review.
    static func importTranscript(_ data: Data, conversation: ClaudeConversation) throws -> Data {
        guard !data.isEmpty, data.count <= maximumTranscriptBytes else {
            throw ClaudeConversationCopyError.unsupportedFormat
        }
        var result = Data()
        var hasMessage = false
        var hasWorkingDirectory = false
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard line.count <= 16 * 1_024 * 1_024,
                  var entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else {
                throw ClaudeConversationCopyError.unsupportedFormat
            }
            guard let cwd = entry["cwd"] as? String else { continue }
            guard validWorkingDirectory(cwd) else { throw ClaudeConversationCopyError.unsupportedFormat }
            if let id = entry["sessionId"] as? String, id != conversation.cliSessionID {
                throw ClaudeConversationCopyError.unsupportedFormat
            }
            hasWorkingDirectory = hasWorkingDirectory || cwd == conversation.workingDirectory
            let type = entry["type"] as? String
            if (type == "user" || type == "assistant"), entry["isSidechain"] as? Bool != true {
                hasMessage = true
            }
            entry.removeValue(forKey: "sessionId")
            if var toolResult = entry["toolUseResult"] as? [String: Any] {
                toolResult.removeValue(forKey: "agentId")
                entry["toolUseResult"] = toolResult
            }
            result.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
            result.append(0x0A)
            guard result.count <= maximumTranscriptBytes else { throw ClaudeConversationCopyError.unsupportedFormat }
        }
        guard hasMessage, hasWorkingDirectory else { throw ClaudeConversationCopyError.unsupportedFormat }
        return result
    }
}
