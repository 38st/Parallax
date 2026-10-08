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

    var newest: ChatCopy {
        copies.sorted {
            if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
            return $0.namespace.path < $1.namespace.path
        }[0]
    }
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
    case removedInTarget
    case unreadableTarget

    var errorDescription: String? {
        switch self {
        case .noChatFolder(let space): "Open Claude Code once in \(space) so Claude creates its chat folder, then try again."
        case .transcriptMissing: "This chat's messages couldn't be found."
        case .unsupported: "This chat's file format isn't supported."
        case .removedInTarget: "This chat was deleted or archived in that account. Restore it in Claude there, or continue it in another account."
        case .unreadableTarget: "The destination has an unreadable or unsupported chat record, so it was left untouched."
        }
    }
}

/// Reads and continues Claude Desktop Code-tab chats across Claude spaces.
enum ClaudeChats {
    struct SyncResult: Sendable {
        var transferred = 0
        var issues: [String] = []

        var summary: String? {
            guard !issues.isEmpty else { return nil }
            let remaining = issues.count > 5 ? "\n\n…and \(issues.count - 5) more issues." : ""
            return "Carried over \(transferred) Claude Code chat\(transferred == 1 ? "" : "s"). "
                + "\(issues.count) issue\(issues.count == 1 ? " needs" : "s need") attention:\n\n"
                + issues.prefix(5).joined(separator: "\n\n") + remaining
        }
    }

    struct SpaceFolders: Sendable {
        var spaceID: UUID
        var name: String
        var root: URL
        var config: URL
        var userData: URL? = nil

        var sessions: URL { (userData ?? root.appendingPathComponent("UserData", isDirectory: true)).appendingPathComponent("claude-code-sessions", isDirectory: true) }
    }

    static func folders(for space: Space) -> SpaceFolders {
        let root = URL(fileURLWithPath: space.folder, isDirectory: true)
        let custom = LaunchText.environment(space.environment).values["CLAUDE_CONFIG_DIR"]
        let config = custom.map { URL(fileURLWithPath: LaunchPlanner.expandTilde($0, home: NSHomeDirectory()), isDirectory: true) }
            ?? root.appendingPathComponent("UserData/ClaudeConfig", isDirectory: true)
        let userData = (try? LaunchText.words(space.arguments))?.optionValue(LaunchPlanner.userDataOptions)
            .map { URL(fileURLWithPath: LaunchPlanner.expandTilde($0, home: NSHomeDirectory()), isDirectory: true) }
        return SpaceFolders(spaceID: space.id, name: space.name, root: root, config: config, userData: userData)
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
        return merged.map { Chat(id: $0.key, copies: $0.value) }.sorted {
            if $0.newest.lastActivityAt != $1.newest.lastActivityAt { return $0.newest.lastActivityAt > $1.newest.lastActivityAt }
            return $0.id < $1.id
        }
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
              let sessionID = object["sessionId"] as? String, sessionID.hasPrefix("local_"), safeIdentifier(sessionID),
              let cli = object["cliSessionId"] as? String, safeIdentifier(cli),
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

    private static func safeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
    }

    // MARK: Transcripts

    /// A staged import transcript if Claude hasn't taken it in yet, otherwise the CLI transcript.
    static func transcriptURL(for copy: ChatCopy, in space: SpaceFolders) -> URL? {
        let staged = copy.stagedTranscriptPath.map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        let projects = space.config.appendingPathComponent("projects", isDirectory: true)
        let matches = ((try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.appendingPathComponent(copy.cliSessionID + ".jsonl") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard matches.count == 1, let native = matches.first else { return staged }
        guard let staged else { return native }

        // Claude may retain stagedTranscriptPath after importing and continuing the chat.
        // Prefer whichever transcript extends the other, even when metadata hasn't changed.
        if let stagedData = try? normalizedTranscript(Data(contentsOf: staged), cliSessionID: copy.cliSessionID, cwd: copy.cwd),
           let nativeData = try? normalizedTranscript(Data(contentsOf: native), cliSessionID: copy.cliSessionID, cwd: copy.cwd) {
            if nativeData.starts(with: stagedData) { return native }
            if stagedData.starts(with: nativeData) { return staged }
        }
        // A newer staged import must remain pending until the native transcript includes it.
        return staged
    }

    /// Normalizes a transcript so copies from different accounts can be compared and imported:
    /// rejects unreadable lines, skips metadata without a working directory, removes per-account session ids.
    static func normalizedTranscript(_ data: Data, cliSessionID: String, cwd: String) throws -> Data {
        var output = Data()
        var hasMessage = false
        var hasWorkingDirectory = false
        for line in data.split(separator: 0x0A) {
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            guard var entry = jsonObject(line) else { throw ChatError.unsupported }
            guard let lineCwd = entry["cwd"] as? String else {
                if let type = entry["type"] as? String, type == "user" || type == "assistant" { throw ChatError.unsupported }
                continue
            }
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

    /// All Claude spaces must be stopped before calling this. Each chat is independent:
    /// a missing transcript doesn't prevent the remaining chats from being carried over.
    static func syncAll(to target: SpaceFolders, spaces: [SpaceFolders], backups: URL) -> SyncResult {
        var result = SyncResult()
        for space in spaces where space.spaceID != target.spaceID {
            let unsupported = namespaces(in: space).reduce(0) { count, namespace in
                count + recordFiles(in: namespace).filter { file in
                    let tombstone = namespace.appendingPathComponent("deleted_" + file.deletingPathExtension().lastPathComponent.dropFirst("local_".count))
                    if FileManager.default.fileExists(atPath: tombstone.path) { return false }
                    guard let data = try? Data(contentsOf: file),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
                    if object["isArchived"] as? Bool == true { return false }
                    guard let copy = parseRecord(data, namespace: namespace, spaceID: space.spaceID) else { return true }
                    return file.lastPathComponent != copy.sessionID + ".json"
                }.count
            }
            if unsupported > 0 {
                result.issues.append("\(space.name): \(unsupported) Claude Code chat record\(unsupported == 1 ? " could" : "s could") not be read or use an unsupported format. Those chats remain in the original account.")
            }
        }
        let chats = scan(spaces)
        guard !chats.isEmpty else { return result }
        let targetNamespace: URL
        do {
            targetNamespace = try primaryNamespace(in: target)
        } catch {
            result.issues.append(error.localizedDescription)
            return result
        }
        for chat in chats {
            do {
                let transfer = try prepare(chat: chat, target: target, spaces: spaces, targetNamespace: targetNamespace)
                try apply(transfer, backups: backups)
                if transfer.kind != .upToDate { result.transferred += 1 }
                if transfer.kind == .replaceDiverged {
                    result.issues.append("\(chat.title): Both accounts had different messages. The previous copy was backed up in \(backups.path).")
                }
            } catch ChatError.removedInTarget {
                // Respect deliberate deletions and archives in this account.
                continue
            } catch {
                result.issues.append("\(chat.title): \(error.localizedDescription) Open this chat in its original Claude space, then try again.")
            }
        }
        return result
    }

    static func prepare(chat: Chat, target: SpaceFolders, spaces: [SpaceFolders], targetNamespace: URL? = nil) throws -> ChatTransfer {
        func isDestination(_ copy: ChatCopy) -> Bool {
            copy.spaceID == target.spaceID && (targetNamespace == nil || copy.namespace == targetNamespace)
        }
        let copies = chat.copies.sorted {
            if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
            return $0.namespace.path < $1.namespace.path
        }
        var selected: (copy: ChatCopy, transcript: Data)?
        var unreadable: Error = ChatError.transcriptMissing
        // A continued transcript can outgrow its imported record's activity timestamp.
        // Prefer compatible extensions; use activity time to choose between divergent copies.
        for copy in copies {
            do {
                guard let space = spaces.first(where: { $0.spaceID == copy.spaceID }),
                      let url = transcriptURL(for: copy, in: space) else { throw ChatError.transcriptMissing }
                let transcript = try normalizedTranscript(Data(contentsOf: url), cliSessionID: copy.cliSessionID, cwd: copy.cwd)
                if selected == nil || (transcript.count > selected!.transcript.count && transcript.starts(with: selected!.transcript)) {
                    selected = (copy, transcript)
                }
            } catch {
                // A damaged destination can be backed up and repaired from a healthy source.
                // Don't silently downgrade a damaged latest source to an older version.
                if !isDestination(copy) && copy.lastActivityAt == copies[0].lastActivityAt { throw error }
                unreadable = error
            }
        }
        guard let (source, sourceTranscript) = selected else { throw unreadable }

        let existing = chat.copies.first(where: isDestination)
        let namespace = try targetNamespace ?? existing?.namespace ?? primaryNamespace(in: target)
        var transfer = ChatTransfer(
            kind: .add, chatID: chat.id, source: source, targetSpaceID: target.spaceID,
            targetNamespace: namespace, transcript: sourceTranscript
        )
        guard let existing else {
            let record = namespace.appendingPathComponent(source.sessionID + ".json")
            let tombstone = namespace.appendingPathComponent("deleted_" + source.sessionID.dropFirst("local_".count))
            if FileManager.default.fileExists(atPath: tombstone.path) { throw ChatError.removedInTarget }
            if FileManager.default.fileExists(atPath: record.path) {
                let object = (try? Data(contentsOf: record)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                if object?["isArchived"] as? Bool == true { throw ChatError.removedInTarget }
                throw ChatError.unreadableTarget
            }
            return transfer
        }
        transfer.targetRecord = namespace.appendingPathComponent(existing.sessionID + ".json")
        transfer.targetTranscript = transcriptURL(for: existing, in: target)
        if existing == source {
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
        guard safeIdentifier(transfer.source.sessionID), safeIdentifier(transfer.source.cliSessionID),
              transfer.chatID == transfer.source.sessionID else { throw ChatError.unsupported }
        let manager = FileManager.default
        if transfer.kind == .add {
            let record = transfer.targetNamespace.appendingPathComponent(transfer.source.sessionID + ".json")
            let tombstone = transfer.targetNamespace.appendingPathComponent("deleted_" + transfer.source.sessionID.dropFirst("local_".count))
            guard !manager.fileExists(atPath: record.path), !manager.fileExists(atPath: tombstone.path) else { throw ChatError.removedInTarget }
        }
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
