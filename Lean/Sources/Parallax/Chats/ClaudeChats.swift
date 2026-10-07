import CryptoKit
import Foundation

/// One Claude Code chat as saved in one space.
struct ChatCopy: Hashable, Sendable {
    var spaceID: UUID
    var namespace: URL
    var sessionID: String
    var cliSessionID: String
    var title: String
    var cwd: String
    var createdAt: Double
    var lastActivityAt: Double
    var stagedTranscriptPath: String?
}

/// A chat merged across every Claude space that has it.
struct Chat: Identifiable, Hashable, Sendable {
    var id: String
    var copies: [ChatCopy]

    var newest: ChatCopy { copies.max { $0.lastActivityAt < $1.lastActivityAt } ?? copies[0] }
    var title: String { newest.title }
    var project: String { URL(fileURLWithPath: newest.cwd).lastPathComponent }
    var lastActivity: Date { Date(timeIntervalSince1970: newest.lastActivityAt / 1000) }
}

/// What continuing a chat in a space will do.
struct ChatTransfer: Sendable {
    enum Kind: Equatable, Sendable {
        /// The space already has the latest messages.
        case upToDate
        /// The space's copy is older; it will be updated.
        case update
        /// The space doesn't have this chat yet.
        case add
        /// Both copies have messages the other lacks. The space's copy is backed up and replaced.
        case replaceDiverged
    }

    var kind: Kind
    var chatID: String
    var source: ChatCopy
    var targetSpaceID: UUID
    var targetNamespace: URL
    var targetRecord: URL?
    var targetTranscript: URL?
    var transcript: Data
}

enum ChatError: LocalizedError {
    case noChatFolder(String)
    case transcriptMissing
    case unsupported

    var errorDescription: String? {
        switch self {
        case .noChatFolder(let space): "Open Claude Code once in \(space) so Claude creates its chat folder, then try again."
        case .transcriptMissing: "This chat's messages couldn't be found."
        case .unsupported: "This chat's file format isn't supported."
        }
    }
}

/// Reads and continues Claude Desktop Code-tab chats across Claude spaces.
enum ClaudeChats {
    struct SpaceFolders: Sendable {
        var spaceID: UUID
        var name: String
        var root: URL
        var config: URL

        var sessions: URL { root.appendingPathComponent("UserData/claude-code-sessions", isDirectory: true) }
    }

    static func folders(for space: Space) -> SpaceFolders {
        let root = URL(fileURLWithPath: space.folder, isDirectory: true)
        let custom = LaunchText.environment(space.environment).values["CLAUDE_CONFIG_DIR"]
        let config = custom.map { URL(fileURLWithPath: LaunchPlanner.expandTilde($0, home: NSHomeDirectory()), isDirectory: true) }
            ?? root.appendingPathComponent("UserData/ClaudeConfig", isDirectory: true)
        return SpaceFolders(spaceID: space.id, name: space.name, root: root, config: config)
    }

    // MARK: Listing

    static func scan(_ spaces: [SpaceFolders]) -> [Chat] {
        var merged: [String: [ChatCopy]] = [:]
        for space in spaces {
            for namespace in namespaces(in: space) {
                for copy in records(in: namespace, spaceID: space.spaceID) {
                    merged[copy.sessionID, default: []].append(copy)
                }
            }
        }
        return merged.map { Chat(id: $0.key, copies: $0.value) }.sorted { $0.newest.lastActivityAt > $1.newest.lastActivityAt }
    }

    /// `<account>/<organization>` folders inside a space.
    static func namespaces(in space: SpaceFolders) -> [URL] {
        let manager = FileManager.default
        let accounts = (try? manager.contentsOfDirectory(at: space.sessions, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return accounts.flatMap { account in
            ((try? manager.contentsOfDirectory(at: account, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
    }

    /// The folder the signed-in account writes its chats to: the one with the most recent chat.
    static func primaryNamespace(in space: SpaceFolders) throws -> URL {
        let all = namespaces(in: space)
        let withChats = all.compactMap { namespace -> (URL, Date)? in
            let newest = recordFiles(in: namespace).compactMap {
                try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            }.max()
            return newest.map { (namespace, $0) }
        }
        if let best = withChats.max(by: { $0.1 < $1.1 }) { return best.0 }
        if all.count == 1 { return all[0] }
        throw ChatError.noChatFolder(space.name)
    }

    private static func recordFiles(in namespace: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: namespace, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("local_") && $0.pathExtension == "json" }
    }

    static func records(in namespace: URL, spaceID: UUID) -> [ChatCopy] {
        let names = Set((try? FileManager.default.contentsOfDirectory(atPath: namespace.path)) ?? [])
        return recordFiles(in: namespace).compactMap { url in
            guard let data = try? Data(contentsOf: url), let copy = parseRecord(data, namespace: namespace, spaceID: spaceID),
                  url.lastPathComponent == copy.sessionID + ".json",
                  !names.contains("deleted_" + copy.sessionID.dropFirst("local_".count))
            else { return nil }
            return copy
        }
    }

    static func parseRecord(_ data: Data, namespace: URL, spaceID: UUID) -> ChatCopy? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionID = object["sessionId"] as? String, sessionID.hasPrefix("local_"),
              let cli = object["cliSessionId"] as? String,
              let cwd = object["cwd"] as? String, cwd.hasPrefix("/"),
              (object["isArchived"] as? Bool) != true,
              object["sshConfig"] == nil || object["sshConfig"] is NSNull,
              object["wslConfig"] == nil || object["wslConfig"] is NSNull
        else { return nil }
        return ChatCopy(
            spaceID: spaceID,
            namespace: namespace,
            sessionID: sessionID,
            cliSessionID: cli,
            title: (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled conversation",
            cwd: cwd,
            createdAt: (object["createdAt"] as? NSNumber)?.doubleValue ?? 0,
            lastActivityAt: (object["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0,
            stagedTranscriptPath: object["stagedTranscriptPath"] as? String
        )
    }

    // MARK: Transcripts

    /// A staged import transcript if Claude hasn't taken it in yet, otherwise the CLI transcript.
    static func transcriptURL(for copy: ChatCopy, in space: SpaceFolders) -> URL? {
        if let staged = copy.stagedTranscriptPath, FileManager.default.fileExists(atPath: staged) {
            return URL(fileURLWithPath: staged)
        }
        let projects = space.config.appendingPathComponent("projects", isDirectory: true)
        let matches = ((try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent(copy.cliSessionID + ".jsonl") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        return matches.count == 1 ? matches[0] : nil
    }

    /// Normalizes a transcript so copies from different accounts can be compared and imported:
    /// drops unreadable lines and lines without a working directory, removes per-account session ids.
    static func normalizedTranscript(_ data: Data, cliSessionID: String, cwd: String) throws -> Data {
        var output = Data()
        var hasMessage = false
        var hasWorkingDirectory = false
        for line in data.split(separator: 0x0A) {
            guard var entry = jsonObject(line) else { continue }
            guard let lineCwd = entry["cwd"] as? String else { continue }
            if let session = entry["sessionId"] as? String, session != cliSessionID { throw ChatError.unsupported }
            if lineCwd == cwd { hasWorkingDirectory = true }
            if let type = entry["type"] as? String, type == "user" || type == "assistant", (entry["isSidechain"] as? Bool) != true {
                hasMessage = true
            }
            entry.removeValue(forKey: "sessionId")
            if var result = entry["toolUseResult"] as? [String: Any] {
                result.removeValue(forKey: "agentId")
                entry["toolUseResult"] = result
            }
            output.append(try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]))
            output.append(0x0A)
        }
        guard hasMessage, hasWorkingDirectory else { throw ChatError.unsupported }
        return output
    }

    private static func jsonObject(_ line: Data.SubSequence) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] { return object }
        // Replace lone UTF-16 surrogate escapes, which some transcripts contain, then try again.
        guard let text = String(data: Data(line), encoding: .utf8) else { return nil }
        let repaired = text
            .replacingOccurrences(of: #"\\u[dD][89abAB][0-9a-fA-F]{2}(?!\\u[dD][c-fC-F][0-9a-fA-F]{2})"#, with: #"\\ufffd"#, options: .regularExpression)
            .replacingOccurrences(of: #"(?<!\\u[dD][89abAB][0-9a-fA-F]{2})\\u[dD][c-fC-F][0-9a-fA-F]{2}"#, with: #"\\ufffd"#, options: .regularExpression)
        return (try? JSONSerialization.jsonObject(with: Data(repaired.utf8))) as? [String: Any]
    }

    // MARK: Continuing a chat in another space

    static func prepare(chat: Chat, target: SpaceFolders, spaces: [SpaceFolders]) throws -> ChatTransfer {
        let source = chat.newest
        guard let sourceSpace = spaces.first(where: { $0.spaceID == source.spaceID }),
              let sourceURL = transcriptURL(for: source, in: sourceSpace)
        else { throw ChatError.transcriptMissing }
        let sourceTranscript = try normalizedTranscript(Data(contentsOf: sourceURL), cliSessionID: source.cliSessionID, cwd: source.cwd)

        let existing = chat.copies.first { $0.spaceID == target.spaceID }
        let namespace = try existing?.namespace ?? primaryNamespace(in: target)
        var transfer = ChatTransfer(
            kind: .add, chatID: chat.id, source: source, targetSpaceID: target.spaceID,
            targetNamespace: namespace, transcript: sourceTranscript
        )
        guard let existing else { return transfer }
        transfer.targetRecord = namespace.appendingPathComponent(existing.sessionID + ".json")
        transfer.targetTranscript = transcriptURL(for: existing, in: target)
        if existing.spaceID == source.spaceID {
            transfer.kind = .upToDate
            return transfer
        }
        guard let targetURL = transfer.targetTranscript,
              let targetTranscript = try? normalizedTranscript(Data(contentsOf: targetURL), cliSessionID: existing.cliSessionID, cwd: existing.cwd)
        else {
            transfer.kind = .update
            return transfer
        }
        if targetTranscript == sourceTranscript || targetTranscript.starts(with: sourceTranscript) {
            transfer.kind = .upToDate
        } else if sourceTranscript.starts(with: targetTranscript) {
            transfer.kind = .update
        } else {
            transfer.kind = .replaceDiverged
        }
        return transfer
    }

    /// Writes the transcript, then the chat record, into the target account's folder.
    /// The target's previous files are copied to `backups` first.
    static func apply(_ transfer: ChatTransfer, backups: URL, now: Date = Date()) throws {
        guard transfer.kind != .upToDate else { return }
        let manager = FileManager.default
        if transfer.targetRecord != nil || transfer.targetTranscript != nil {
            let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
            let unique = UUID().uuidString.prefix(8).lowercased()
            let folder = backups.appendingPathComponent("\(stamp)-\(transfer.chatID)-\(unique)", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            for file in [transfer.targetRecord, transfer.targetTranscript].compactMap({ $0 }) where manager.fileExists(atPath: file.path) {
                try manager.copyItem(at: file, to: folder.appendingPathComponent(file.lastPathComponent))
            }
        }

        let source = transfer.source
        let digest = SHA256.hash(data: transfer.transcript).map { String(format: "%02x", $0) }.joined()
        let stagingFolder = transfer.targetNamespace
            .appendingPathComponent("imported-staging", isDirectory: true)
            .appendingPathComponent("\(source.cliSessionID)-\(digest)", isDirectory: true)
        try manager.createDirectory(at: stagingFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let transcriptURL = stagingFolder.appendingPathComponent(source.cliSessionID + ".jsonl")
        try writeAtomically(transfer.transcript, to: transcriptURL)

        let record: [String: Any] = [
            "cliSessionId": source.cliSessionID,
            "createdAt": source.createdAt,
            "cwd": source.cwd,
            "importedFrom": "local-1p-code",
            "isArchived": false,
            "lastActivityAt": source.lastActivityAt,
            "originCwd": source.cwd,
            "sessionId": source.sessionID,
            "stagedTranscriptPath": transcriptURL.path,
            "title": source.title,
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        try writeAtomically(data, to: transfer.targetNamespace.appendingPathComponent(source.sessionID + ".json"))
    }

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, url.path) != 0 {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    static func continueURL(chatID: String) -> URL? {
        var components = URLComponents()
        components.scheme = "claude"
        components.host = "code"
        components.path = "/continue"
        components.queryItems = [URLQueryItem(name: "session", value: chatID)]
        return components.url
    }
}
