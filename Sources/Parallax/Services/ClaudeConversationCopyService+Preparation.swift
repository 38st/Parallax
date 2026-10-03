import Foundation

extension ClaudeConversationCopyService {
    func prepare(
        _ conversation: ClaudeConversation,
        destination: ClaudeConversationCopyService
    ) throws -> ClaudeConversationCopyPlan {
        guard files.rootIdentity != destination.files.rootIdentity else {
            throw ClaudeConversationCopyError.sameSpace
        }
        let currentRecord = try files.readFile(at: conversation.recordPath)
        guard try Self.conversation(data: currentRecord, path: conversation.recordPath) == conversation else {
            throw ClaudeConversationCopyError.changed
        }
        let path = try transcriptPath(for: conversation)
        let original = try files.readFile(at: path)
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
        guard !data.isEmpty else {
            throw ClaudeConversationCopyError.unsupportedFormat
        }
        let result = try HistoryFileBuffer()
        var hasMessage = false
        var hasWorkingDirectory = false
        try HistoryFileBuffer.forEachLine(in: data) { line in
            try Task.checkCancellation()
            guard var entry = (try? transcriptJSONObject(line)) as? [String: Any] else {
                // An interrupted write can leave a partial tail or a garbled
                // interior line. Retain only complete objects in this copy.
                return
            }
            guard let cwd = entry["cwd"] as? String else { return }
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
            try result.append(JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
            try result.append(Data([0x0A]))
        }
        guard hasMessage, hasWorkingDirectory else { throw ClaudeConversationCopyError.unsupportedFormat }
        return try result.finish()
    }

    /// Claude writes JSON from JavaScript strings, so a truncated tool result
    /// can end in an escaped lone surrogate that Foundation rejects. Only such
    /// escapes are replaced, with U+FFFD; any other malformed line still fails.
    static func transcriptJSONObject(_ line: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: line)
        } catch {
            guard let repaired = replacingLoneSurrogateEscapes(in: line) else { throw error }
            return try JSONSerialization.jsonObject(with: repaired)
        }
    }

    static func replacingLoneSurrogateEscapes(in line: Data) -> Data? {
        var bytes = [UInt8](line)
        let replacement = Array(#"\ufffd"#.utf8)
        func escapedUnit(at index: Int) -> UInt16? {
            guard index + 5 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u"),
                  let text = String(bytes: bytes[(index + 2)..<(index + 6)], encoding: .ascii) else { return nil }
            return UInt16(text, radix: 16)
        }
        var changed = false
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "\\"), index + 1 < bytes.count else { index += 1; continue }
            guard let unit = escapedUnit(at: index) else { index += 2; continue }
            if (0xD800...0xDBFF).contains(unit), let next = escapedUnit(at: index + 6), (0xDC00...0xDFFF).contains(next) {
                index += 12
            } else if (0xD800...0xDFFF).contains(unit) {
                bytes.replaceSubrange(index..<(index + 6), with: replacement)
                changed = true
                index += 6
            } else {
                index += 6
            }
        }
        return changed ? Data(bytes) : nil
    }
}
