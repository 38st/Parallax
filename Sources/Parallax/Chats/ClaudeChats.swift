import CoreFoundation
import CryptoKit
import Foundation

/// One Claude Code chat as saved in one space.
struct ChatCopy: Codable, Hashable, Sendable {
    var spaceID: UUID
    var namespace: URL
    var sessionID: String
    var cliSessionID: String
    var title: String?
    var cwd: String
    var createdAt: Double
    var lastActivityAt: Double
    var stagedTranscriptPath: String?
    var lastFocusedAt: Double?
    var approvals = ChatApprovals()
    var lineage = ChatLineage()
    var imported = false
    var titleSource: String?
    var originCwd: String?
    var worktreePath: String?
    var routine = false

    var transcriptCwds: Set<String> { Set([cwd, originCwd, worktreePath].compactMap { $0 }) }
}

/// The portable part of Claude's parent/child relationship, validated before crossing accounts.
struct ChatLineage: Codable, Hashable, Sendable {
    static let keys = ["spawnedFrom", "forkedFromSessionId", "forkedAtMessageUuid", "lineageDetached"]
    var present = false
    var json: Data?

    init() {}

    static func has(_ record: [String: Any]) -> Bool {
        keys.contains { record[$0] != nil && !(record[$0] is NSNull) }
    }

    init(record: [String: Any], sessionID: String) {
        present = Self.has(record)
        func parent(_ value: Any?) -> String? {
            guard let id = value as? String, id.hasPrefix("local_"), id != sessionID,
                  ClaudeChats.safeIdentifier(id) else { return nil }
            return id
        }
        func boolean(_ value: Any?) -> Bool? {
            guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
            return value.boolValue
        }
        var kept: [String: Any] = [:]
        if let spawn = record["spawnedFrom"] as? [String: Any], let id = parent(spawn["sessionId"]),
           let task = spawn["taskId"] as? String {
            var clean: [String: Any] = ["sessionId": id, "taskId": task]
            for key in ["title", "name"] { clean[key] = spawn[key] as? String }
            for key in ["sideSession", "userFork", "handOff", "btw", "sharedFolder"] { clean[key] = boolean(spawn[key]) }
            if let deleted = spawn["deletedParent"] as? [String: Any], let id = deleted["sessionId"] as? String {
                var value: [String: Any] = ["sessionId": id]
                value["title"] = deleted["title"] as? String
                clean["deletedParent"] = value
            }
            kept["spawnedFrom"] = clean
            if boolean(record["spawnedFromEndNotified"]) == true { kept["spawnedFromEndNotified"] = true }
        }
        kept["forkedFromSessionId"] = parent(record["forkedFromSessionId"])
        kept["forkedAtMessageUuid"] = record["forkedAtMessageUuid"] as? String
        if boolean(record["lineageDetached"]) == true { kept["lineageDetached"] = true }
        json = kept.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: kept, options: [.sortedKeys])
    }

    func write(to record: inout [String: Any]) {
        guard let json, let values = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
        record.merge(values) { _, new in new }
    }

    /// Keep the destination's private lineage fields, but never re-emit invalid IPC values.
    static func cleanOwn(in record: inout [String: Any], sessionID: String) {
        var clean: [String: Any] = [:]
        ChatLineage(record: record, sessionID: sessionID).write(to: &clean)
        if var spawn = record["spawnedFrom"] as? [String: Any], let valid = clean["spawnedFrom"] as? [String: Any] {
            for key in ["sessionId", "taskId", "title", "name", "sideSession", "userFork", "handOff", "btw", "sharedFolder", "deletedParent"] {
                spawn[key] = valid[key]
            }
            clean["spawnedFrom"] = spawn
        }
        for key in keys + ["spawnedFromEndNotified"] { record[key] = clean[key] }
    }
}

/// Only the user's chat-level choices; never credentials, tool grants, or account policy.
struct ChatApprovals: Codable, Equatable, Hashable, Sendable {
    var trusted = false
    var permissionMode: String?
    var bypassChosenInApp = false
    var autoChosenInApp = false
    var keepsMode = false

    init() {}

    init(record: [String: Any]) {
        trusted = record["importedFrom"] == nil || record["importedFrom"] is NSNull || record["resumeConfirmed"] as? Bool == true
        guard let mode = record["permissionMode"] as? String else { return }
        switch mode {
        case "default", "acceptEdits", "plan", "dontAsk": permissionMode = mode
        case "bypassPermissions" where trusted && record["bypassChosenInApp"] as? Bool == true:
            permissionMode = mode
            bypassChosenInApp = true
        case "auto" where trusted && record["autoChosenInApp"] as? Bool == true:
            permissionMode = mode
            autoChosenInApp = true
        default: keepsMode = trusted
        }
    }

    func write(to record: inout [String: Any]) {
        record["resumeConfirmed"] = trusted ? true : nil
        guard !keepsMode else { return }
        record["permissionMode"] = permissionMode
        record["bypassChosenInApp"] = bypassChosenInApp ? true : nil
        record["autoChosenInApp"] = autoChosenInApp ? true : nil
    }
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
    var title: String { newest.title ?? "Untitled conversation" }
    var project: String { URL(fileURLWithPath: newest.cwd).lastPathComponent }
    var lastActivity: Date { Date(timeIntervalSince1970: newest.lastActivityAt / 1000) }
    var lastFocusedAt: Double? { copies.compactMap(\.lastFocusedAt).max() }
    var lastInteractionAt: Double { max(newest.lastActivityAt, lastFocusedAt ?? 0) }
}

/// What continuing a chat in a space will do.
struct ChatTransfer: Sendable {
    enum Kind: Equatable, Sendable {
        /// The space already has the latest messages.
        case upToDate
        /// Messages are current, but lineage or previously accepted approvals need to catch up.
        case updateMetadata
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
    var targetCwd: String?
    var transcript: Data
    var lastFocusedAt: Double?
    var targetConfig: URL
    var approvals: ChatApprovals
    var promoteTranscript = false
    var lineage = ChatLineage()
    var targetHasOwnMessages = false
    var sourceTranscript: URL?
}

enum ChatError: LocalizedError {
    case noChatFolder(String)
    case transcriptMissing
    case unsupported
    case removedInTarget
    case unreadableTarget
    case conflictingTranscripts

    var errorDescription: String? {
        switch self {
        case .noChatFolder(let space): "Open Claude Code once in \(space) so Claude creates its chat folder, then try again."
        case .transcriptMissing: "This chat's messages couldn't be found."
        case .unsupported: "This chat's file format isn't supported."
        case .removedInTarget: "This chat was deleted or archived in that account. Restore it in Claude there, or continue it in another account."
        case .conflictingTranscripts: "This chat has two different message files in one Claude space, so Parallax left it alone."
        case .unreadableTarget: "The destination has an unreadable or unsupported chat record, so it was left untouched."
        }
    }
}

/// Disposable memo of syncs that changed nothing. Deleting it only causes a full re-check.
struct ChatSyncCache: Codable, Sendable {
    /// Bump when prepare, apply, or normalization decisions change.
    static let logicVersion = 1
    static let currentVersion: String? = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
        .map { "\(logicVersion)-\($0)" }
    var version = ChatSyncCache.currentVersion ?? ""
    var stamps: [String: String] = [:]
    var failed: [String: String] = [:]

    static func key(_ target: UUID, _ chatID: String) -> String { target.uuidString + "/" + chatID }

    static func load(from url: URL) -> ChatSyncCache {
        guard let currentVersion, let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(Self.self, from: data), cache.version == currentVersion else { return Self() }
        return cache
    }

    func save(to url: URL) {
        guard Self.currentVersion != nil else { return }
        try? JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

/// Reads and continues Claude Desktop Code-tab chats across Claude spaces.
enum ClaudeChats {
    struct SyncResult: Sendable {
        var transferred = 0
        var notes: [String] = []
        var issues: [String] = []
        var checked = 0
        var total = 0
        var stopped = false

        var summary: String? { summary() }

        func summary(excluding shown: Set<String> = []) -> String? {
            let unshown = issues.filter { !shown.contains($0) }
            guard !notes.isEmpty || !unshown.isEmpty else { return nil }
            var parts = ["Carried over \(transferred) chat\(transferred == 1 ? "" : "s")."] + notes + Array(unshown.prefix(5))
            if unshown.count > 5 { parts.append("…and \(unshown.count - 5) more. See Last carry-over on the Claude page.") }
            return parts.joined(separator: "\n\n")
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
            if $0.lastInteractionAt != $1.lastInteractionAt { return $0.lastInteractionAt > $1.lastInteractionAt }
            return $0.id < $1.id
        }
    }

    /// `<account>/<organization>` folders inside a space.
    static func namespaces(in space: SpaceFolders) -> [URL] {
        let manager = FileManager.default
        let accounts = (try? manager.contentsOfDirectory(at: space.sessions.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return accounts.flatMap { account in
            ((try? manager.contentsOfDirectory(at: account.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
    }

    /// The folder the signed-in account writes its chats to: the one with the most recent chat.
    static func primaryNamespace(in space: SpaceFolders) throws -> URL {
        var all = namespaces(in: space)
        let config = space.sessions.deletingLastPathComponent().appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: config),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let accountID = object["lastKnownAccountUuid"] as? String, safeIdentifier(accountID) {
            let accounts = ((try? FileManager.default.contentsOfDirectory(at: space.sessions.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            if let account = accounts.first(where: { $0.lastPathComponent == accountID }) ?? (accounts.count == 1 ? accounts.first : nil) {
                all = all.filter { $0.deletingLastPathComponent().resolvingSymlinksInPath() == account.resolvingSymlinksInPath() }
            } else { throw ChatError.noChatFolder(space.name) }
        }
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
            title: (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            cwd: cwd,
            createdAt: (object["createdAt"] as? NSNumber)?.doubleValue ?? 0,
            lastActivityAt: (object["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0,
            stagedTranscriptPath: object["stagedTranscriptPath"] as? String,
            lastFocusedAt: (object["lastFocusedAt"] as? NSNumber)?.doubleValue,
            approvals: ChatApprovals(record: object),
            lineage: ChatLineage(record: object, sessionID: sessionID),
            imported: object["importedFrom"] != nil && !(object["importedFrom"] is NSNull),
            titleSource: object["titleSource"] as? String,
            originCwd: object["originCwd"] as? String,
            worktreePath: object["worktreePath"] as? String,
            routine: (object["scheduledTaskId"] as? String).map { !$0.isEmpty } ?? false
        )
    }

    fileprivate static func safeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && value.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" }
    }

    // MARK: Transcripts

    static func projectFolders(config: URL) -> [URL] {
        let projects = config.appendingPathComponent("projects", isDirectory: true).resolvingSymlinksInPath()
        return ((try? FileManager.default.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [])
            .map { $0.resolvingSymlinksInPath() }
    }

    static func projectFolders(for spaces: [SpaceFolders]) -> [UUID: [URL]] {
        Dictionary(spaces.map { ($0.spaceID, projectFolders(config: $0.config)) }, uniquingKeysWith: { first, _ in first })
    }

    static func nativeTranscripts(cliSessionID: String, in folders: [URL]) -> [URL] {
        Array(Set(folders.map { $0.appendingPathComponent(cliSessionID + ".jsonl") }
            .filter { fileType($0, followingLinks: true) == S_IFREG })).sorted { $0.path < $1.path }
    }

    private static func stagedTranscript(for copy: ChatCopy) -> URL? {
        guard let path = copy.stagedTranscriptPath, path.hasPrefix("/") else { return nil }
        let candidate = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(copy.cliSessionID + ".jsonl")
        let root = copy.namespace.appendingPathComponent("imported-staging").standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(root.path + "/"),
              fileType(candidate, followingLinks: true) == S_IFREG else { return nil }
        return candidate
    }

    private static func fileType(_ url: URL, followingLinks: Bool = false) -> mode_t? {
        var info = stat()
        guard (followingLinks ? stat(url.path, &info) : lstat(url.path, &info)) == 0 else { return nil }
        return info.st_mode & S_IFMT
    }

    static func transcriptURL(for copy: ChatCopy, in space: SpaceFolders, projectFolders: [URL]? = nil) throws -> URL? {
        try transcriptSource(for: copy, in: space, projectFolders: projectFolders) {
            try normalizedTranscript(Data(contentsOf: $0), cwds: $1)
        }?.url
    }

    /// Return the comparison bytes too, including a failed normalization so prepare never retries the same file.
    private static func transcriptSource(for copy: ChatCopy, in space: SpaceFolders, projectFolders: [URL]? = nil,
                                         normalized: (URL, Set<String>) throws -> Data) throws
        -> (url: URL, data: Result<Data, Error>)? {
        let staged = stagedTranscript(for: copy)
        let matches = nativeTranscripts(cliSessionID: copy.cliSessionID, in: projectFolders ?? Self.projectFolders(config: space.config))
        let native: (url: URL, data: Result<Data, Error>)?
        if matches.count > 1 {
            var longest: (url: URL, data: Data)?
            for url in matches {
                guard let data = try? normalized(url, copy.transcriptCwds) else { continue }
                if let current = longest {
                    if hasPrefix(current.data, data) { continue }
                    guard hasPrefix(data, current.data) else { throw ChatError.conflictingTranscripts }
                }
                longest = (url, data)
            }
            guard let longest else { throw ChatError.unsupported }
            native = (longest.url, .success(longest.data))
        } else {
            native = matches.first.map { url in (url, Result { try normalized(url, copy.transcriptCwds) }) }
        }
        guard let staged else { return native }
        let stagedData = Result { try normalized(staged, copy.transcriptCwds) }
        if let native, let stagedBytes = try? stagedData.get(), let nativeBytes = try? native.data.get(),
           hasPrefix(nativeBytes, stagedBytes) { return native }
        // A newer or divergent staged import remains pending until native contains it.
        return (staged, stagedData)
    }

    static func hasPrefix(_ data: Data, _ prefix: Data) -> Bool {
        data.count >= prefix.count && data.prefix(prefix.count) == prefix
    }

    /// Non-empty lines, including the final line without a newline, with Data slice indices preserved.
    static func lineRanges(_ data: Data) -> [Range<Data.Index>] {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> [Range<Data.Index>] in
            guard let base = bytes.baseAddress else { return [] }
            var ranges: [Range<Data.Index>] = []
            var start = 0
            while start < bytes.count {
                let end = memchr(base + start, 0x0A, bytes.count - start).map { UnsafeRawPointer($0) - base } ?? bytes.count
                if end > start { ranges.append(data.startIndex + start ..< data.startIndex + end) }
                start = end + 1
            }
            return ranges
        }
    }

    /// Normalizes a transcript so copies from different accounts can be compared and imported:
    /// rejects unreadable lines, skips metadata without a working directory, removes per-account session ids.
    static func normalizedTranscript(_ data: Data, cwds: Set<String>) throws -> Data {
        var output = Data()
        output.reserveCapacity(data.count + data.count / 8)
        var hasMessage = false
        var hasWorkingDirectory = false
        for range in lineRanges(data) {
            let line = data[range]
            if line.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }) { continue }
            // A detached sync is one job; release Foundation objects after each line.
            try autoreleasepool {
                guard var entry = jsonObject(line) else { throw ChatError.unsupported }
                guard let lineCwd = entry["cwd"] as? String else {
                    if let type = entry["type"] as? String, type == "user" || type == "assistant" { throw ChatError.unsupported }
                    return
                }
                if cwds.contains(lineCwd) { hasWorkingDirectory = true }
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

    static func syncStamp(_ chat: Chat, target: SpaceFolders, targetNamespace: URL, spaces: [SpaceFolders],
                          projectFolders: [UUID: [URL]]) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var others = [target.spaceID.uuidString, target.config.path, targetNamespace.path]
        var own = [fileStamp(targetNamespace.appendingPathComponent("deleted_" + chat.id.dropFirst("local_".count)).path),
                   fileStamp(targetNamespace.appendingPathComponent(chat.id + ".json").path)]
        for copy in chat.copies.sorted(by: { ($0.spaceID.uuidString, $0.namespace.path) < ($1.spaceID.uuidString, $1.namespace.path) }) {
            guard let space = spaces.first(where: { $0.spaceID == copy.spaceID }), let encoded = try? encoder.encode(copy) else { return nil }
            let folders = projectFolders[copy.spaceID] ?? Self.projectFolders(config: space.config)
            var parts = [String(decoding: encoded, as: UTF8.self), space.config.path,
                         fileStamp(copy.namespace.appendingPathComponent(copy.sessionID + ".json").path)]
            let urls = nativeTranscripts(cliSessionID: copy.cliSessionID, in: folders) + [stagedTranscript(for: copy)].compactMap { $0 }
            parts += urls.map(\.path).sorted().map { $0 + "=" + fileStamp($0) }
            if copy.spaceID == target.spaceID { own += parts } else { others += parts }
        }
        func digest(_ parts: [String]) -> String {
            SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return digest(others) + ":" + digest(own)
    }

    private static func fileStamp(_ path: String) -> String {
        var info = stat()
        guard stat(path, &info) == 0 else { return "missing" }
        return "\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec).\(info.st_ctimespec.tv_nsec)"
    }

    private static func unsettled(_ chats: [Chat], target: SpaceFolders, targetNamespace: URL, spaces: [SpaceFolders],
                                  folders: [UUID: [URL]], cache: ChatSyncCache, ignoringFailures: Bool) -> [(chat: Chat, stamp: String?)] {
        chats.filter { !$0.copies.contains(where: \.routine) }.compactMap { chat in
            let stamp = syncStamp(chat, target: target, targetNamespace: targetNamespace, spaces: spaces, projectFolders: folders)
            let key = ChatSyncCache.key(target.spaceID, chat.id)
            if cache.version == ChatSyncCache.currentVersion ?? "", let stamp,
               stamp == cache.stamps[key] || (ignoringFailures && stamp == cache.failed[key]) { return nil }
            return (chat, stamp)
        }
    }

    static func syncAll(to target: SpaceFolders, spaces: [SpaceFolders], backups: URL,
                        read: (URL) throws -> Data = { try Data(contentsOf: $0) },
                        progress: @Sendable (Int, Int) -> Void = { _, _ in }) -> SyncResult {
        var cache = ChatSyncCache()
        return syncAll(to: target, spaces: spaces, backups: backups, cache: &cache, read: read, progress: progress)
    }

    /// The target's Claude must be stopped. Cancellation is observed only between complete chats.
    static func syncAll(to target: SpaceFolders, spaces: [SpaceFolders], backups: URL, cache: inout ChatSyncCache,
                        read: (URL) throws -> Data = { try Data(contentsOf: $0) },
                        progress: @Sendable (Int, Int) -> Void = { _, _ in }) -> SyncResult {
        if cache.version != ChatSyncCache.currentVersion ?? "" { cache = ChatSyncCache() }
        var result = SyncResult()
        for space in spaces where space.spaceID != target.spaceID {
            let unsupported = namespaces(in: space).reduce(0) { count, namespace in
                count + recordFiles(in: namespace).filter { file in
                    let tombstone = namespace.appendingPathComponent("deleted_" + file.deletingPathExtension().lastPathComponent.dropFirst("local_".count))
                    if FileManager.default.fileExists(atPath: tombstone.path) { return false }
                    guard let data = try? Data(contentsOf: file),
                          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return true }
                    if object["isArchived"] as? Bool == true { return false }
                    if ["sshConfig", "wslConfig"].contains(where: { object[$0] != nil && !(object[$0] is NSNull) }) { return false }
                    if object["cliSessionId"] == nil || object["cliSessionId"] is NSNull || object["cliSessionId"] as? String == "" { return false }
                    guard let copy = parseRecord(data, namespace: namespace, spaceID: space.spaceID) else { return true }
                    return file.lastPathComponent != copy.sessionID + ".json"
                }.count
            }
            if unsupported > 0 {
                result.issues.append("\(space.name): \(unsupported) Claude Code chat record\(unsupported == 1 ? " could" : "s could") not be read or use an unsupported format. Those chats remain in the original account.")
            }
        }
        let chats = scan(spaces)
        let targets = Set(spaces.map { $0.spaceID.uuidString })
        let current = Set(chats.map { ChatSyncCache.key(target.spaceID, $0.id) })
        func keep(_ key: String) -> Bool {
            guard let id = key.split(separator: "/").first else { return false }
            return targets.contains(String(id)) && (id != target.spaceID.uuidString || current.contains(key))
        }
        cache.stamps = cache.stamps.filter { keep($0.key) }
        cache.failed = cache.failed.filter { keep($0.key) }
        guard !chats.isEmpty else { return result }
        let targetNamespace: URL
        do {
            targetNamespace = try primaryNamespace(in: target)
        } catch {
            result.issues.append(error.localizedDescription)
            return result
        }
        var folders = projectFolders(for: spaces)
        let work = unsettled(chats, target: target, targetNamespace: targetNamespace, spaces: spaces,
                             folders: folders, cache: cache, ignoringFailures: false)
        result.total = work.count
        for (chat, before) in work {
            if Task.isCancelled { result.stopped = true; break }
            defer { result.checked += 1; progress(result.checked, work.count) }
            let key = ChatSyncCache.key(target.spaceID, chat.id)
            autoreleasepool {
                cache.stamps[key] = nil
                cache.failed[key] = nil
                func unchanged() -> String? {
                    guard let before, before == syncStamp(chat, target: target, targetNamespace: targetNamespace,
                                                         spaces: spaces, projectFolders: folders) else { return nil }
                    return before
                }
                let transfer: ChatTransfer
                do {
                    transfer = try prepare(chat: chat, target: target, spaces: spaces, targetNamespace: targetNamespace,
                                           projectFolders: folders, read: read)
                } catch ChatError.removedInTarget {
                    cache.stamps[key] = unchanged() // Respect deliberate deletions and archives in this account.
                    return
                } catch {
                    cache.failed[key] = unchanged()
                    result.issues.append(issue(error, chat: chat))
                    return
                }
                if transfer.kind == .replaceDiverged && transfer.targetHasOwnMessages {
                    cache.failed[key] = unchanged()
                    result.issues.append("\(chat.title): This chat was continued separately in another account, so \(target.name)'s copy was left unchanged. Use Continue Here on the Chats page to replace it with the most recent copy.")
                    return
                }
                guard transfer.kind != .upToDate else { cache.stamps[key] = unchanged(); return }
                do {
                    try apply(transfer, backups: backups)
                    result.transferred += 1
                    if transfer.kind == .replaceDiverged {
                        result.notes.append("\(chat.title): Both accounts had different messages. The previous copy was backed up in \(backups.path).")
                    }
                    // Apply can create a target project folder; the source listings remain reusable.
                    folders[target.spaceID] = projectFolders(config: target.config)
                    if let before, let after = syncStamp(chat, target: target, targetNamespace: targetNamespace,
                                                         spaces: spaces, projectFolders: folders), after.prefix(64) == before.prefix(64) {
                        cache.stamps[key] = String(before.prefix(64)) + ":applied"
                    }
                } catch ChatError.removedInTarget {
                    // Respect deliberate deletions and archives in this account.
                } catch {
                    result.issues.append(issue(error, chat: chat))
                }
            }
        }
        if result.transferred > 0 { removeUnusedStaging(in: targetNamespace, space: target) }
        return result
    }

    /// Reads records and file metadata only; safe while Claude is running. Failed, unchanged chats do not count.
    static func pendingChatCount(to target: SpaceFolders, spaces: [SpaceFolders], cache: ChatSyncCache,
                                 otherSpacesOnly: Bool = false) throws -> Int {
        let chats = scan(spaces)
        guard !chats.isEmpty else { return 0 }
        let namespace = try primaryNamespace(in: target)
        let work = unsettled(chats, target: target, targetNamespace: namespace, spaces: spaces,
                             folders: projectFolders(for: spaces), cache: cache, ignoringFailures: true)
        guard otherSpacesOnly else { return work.count }
        return work.filter { item in
            guard item.chat.copies.contains(where: { $0.spaceID != target.spaceID }) else { return false }
            guard cache.version == ChatSyncCache.currentVersion ?? "", let stamp = item.stamp else { return true }
            let key = ChatSyncCache.key(target.spaceID, item.chat.id)
            return ![cache.stamps[key], cache.failed[key]].contains { $0?.prefix(64) == stamp.prefix(64) }
        }.count
    }

    private static func issue(_ error: Error, chat: Chat) -> String {
        var message = "\(chat.title): \(error.localizedDescription)"
        if case ChatError.transcriptMissing = error { message += " Open this chat once in its original Claude space, then try again." }
        return message
    }

    static func prepare(chat: Chat, target: SpaceFolders, spaces: [SpaceFolders], targetNamespace: URL? = nil,
                        projectFolders: [UUID: [URL]] = [:], read: (URL) throws -> Data = { try Data(contentsOf: $0) }) throws -> ChatTransfer {
        func isDestination(_ copy: ChatCopy) -> Bool {
            copy.spaceID == target.spaceID && (targetNamespace == nil || copy.namespace == targetNamespace)
        }
        let copies = chat.copies.sorted {
            if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
            return $0.namespace.path < $1.namespace.path
        }
        let existing = chat.copies.first(where: isDestination)
        if existing == nil, let targetNamespace {
            let tombstone = targetNamespace.appendingPathComponent("deleted_" + chat.id.dropFirst("local_".count))
            let record = targetNamespace.appendingPathComponent(chat.id + ".json")
            if FileManager.default.fileExists(atPath: tombstone.path) { throw ChatError.removedInTarget }
            if let data = try? Data(contentsOf: record),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["isArchived"] as? Bool == true {
                throw ChatError.removedInTarget
            }
        }
        let folders = projectFolders.isEmpty ? Self.projectFolders(for: spaces) : projectFolders
        struct TranscriptKey: Hashable { var url: URL; var cwds: Set<String> }
        var uses: [TranscriptKey: Int] = [:]
        for copy in copies {
            let urls = nativeTranscripts(cliSessionID: copy.cliSessionID, in: folders[copy.spaceID] ?? []) + [stagedTranscript(for: copy)].compactMap { $0 }
            for url in Set(urls) { uses[TranscriptKey(url: url, cwds: copy.transcriptCwds), default: 0] += 1 }
        }
        // Only retain shared files until their last use within this chat, never across chats.
        var shared: [TranscriptKey: Result<Data, Error>] = [:]
        func normalized(_ url: URL, _ cwds: Set<String>) throws -> Data {
            let key = TranscriptKey(url: url, cwds: cwds)
            let value = shared[key] ?? Result { try normalizedTranscript(read(url), cwds: cwds) }
            uses[key, default: 1] -= 1
            shared[key] = uses[key, default: 0] > 0 ? value : nil
            return try value.get()
        }
        var existingTranscript: (url: URL, data: Result<Data, Error>)?
        var existingError: Error?
        var selected: (copy: ChatCopy, transcript: Data, url: URL)?
        var unreadable: Error = ChatError.transcriptMissing
        // Prefer compatible extensions; use activity time to choose between divergent copies.
        for copy in copies {
            do {
                guard let space = spaces.first(where: { $0.spaceID == copy.spaceID }),
                      let found = try transcriptSource(for: copy, in: space, projectFolders: folders[copy.spaceID], normalized: normalized) else { throw ChatError.transcriptMissing }
                if copy == existing { existingTranscript = found }
                let transcript = try found.data.get()
                if selected == nil || (transcript.count > selected!.transcript.count && hasPrefix(transcript, selected!.transcript)) {
                    selected = (copy, transcript, found.url)
                } else if transcript == selected!.transcript && copy.cwd == selected!.copy.cwd
                            && copy.approvals.trusted && !selected!.copy.approvals.trusted {
                    selected?.copy.approvals = copy.approvals
                }
            } catch {
                if copy == existing { existingError = error }
                // A damaged target can be repaired; never silently downgrade the newest source.
                if !isDestination(copy) && copy.lastActivityAt == copies[0].lastActivityAt { throw error }
                unreadable = error
            }
        }
        guard let (source, sourceTranscript, sourceURL) = selected else { throw unreadable }
        if let error = existingError as? ChatError {
            if case .conflictingTranscripts = error { throw error }
            if case .unsupported = error, existingTranscript == nil { throw error }
        }

        let namespace = try targetNamespace ?? existing?.namespace ?? primaryNamespace(in: target)
        var approvals = source.approvals
        approvals.keepsMode = false
        // Keep a destination's own selected mode, but only for the same working directory.
        if let existing, existing.cwd == source.cwd, existing.approvals.trusted, existing.approvals.permissionMode != nil || existing.approvals.keepsMode {
            approvals = existing.approvals
            approvals.trusted = source.approvals.trusted
        }
        var transfer = ChatTransfer(
            kind: .add, chatID: chat.id, source: source, targetSpaceID: target.spaceID,
            targetNamespace: namespace, transcript: sourceTranscript, lastFocusedAt: chat.lastFocusedAt,
            targetConfig: target.config, approvals: approvals
        )
        transfer.sourceTranscript = sourceURL
        transfer.lineage = existing.flatMap { $0.lineage.present ? $0.lineage : nil }
            ?? (copies.filter { !$0.imported } + copies).first { $0.lineage.json != nil }?.lineage ?? ChatLineage()
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
        transfer.targetTranscript = existingTranscript?.url
        transfer.targetCwd = existing.cwd
        func currentKind() -> ChatTransfer.Kind {
            // An already trusted copy can vouch for identical messages in this same directory.
            if existing.cwd != source.cwd { transfer.approvals = existing.approvals }
            else if existing.approvals.trusted { transfer.approvals.trusted = true }
            transfer.promoteTranscript = transfer.approvals.trusted && existing.stagedTranscriptPath != nil
            return existing.approvals == transfer.approvals
                && existing.lineage == transfer.lineage && !transfer.promoteTranscript ? .upToDate : .updateMetadata
        }
        if existing == source {
            transfer.kind = currentKind()
            return transfer
        }
        guard let targetTranscript = try? existingTranscript?.data.get()
        else {
            transfer.kind = .update
            return transfer
        }
        if hasPrefix(targetTranscript, sourceTranscript) {
            transfer.kind = currentKind()
        } else if hasPrefix(sourceTranscript, targetTranscript) {
            transfer.kind = .update
        } else {
            transfer.kind = .replaceDiverged
            transfer.targetHasOwnMessages = existing.cliSessionID == source.cliSessionID
                && holdsOwnMessages(targetTranscript, beyond: sourceTranscript)
        }
        return transfer
    }

    private static func holdsOwnMessages(_ target: Data, beyond source: Data) -> Bool {
        let targetLines = lineRanges(target)
        let sourceLines = lineRanges(source)
        var shared = 0
        while shared < min(targetLines.count, sourceLines.count), target[targetLines[shared]] == source[sourceLines[shared]] { shared += 1 }
        return targetLines.dropFirst(shared).contains { range in
            autoreleasepool {
                guard let entry = jsonObject(target[range]), let type = entry["type"] as? String else { return false }
                return (type == "user" || type == "assistant") && entry["isSidechain"] as? Bool != true
            }
        }
    }

    private static func mergeOwnKeys(_ destination: [String: Any], into record: inout [String: Any], transfer: ChatTransfer) {
        let ownKeys = ChatLineage.keys + ["spawnedFromEndNotified", "createdAt", "model", "effort", "effortInherited", "agent",
            "sessionSettings", "spawnSeed", "isStarred", "color", "spaceId", "scheduledTaskId", "autoArchiveExempt",
            "autoArchiveOnPrClose", "prs", "publishedArtifacts", "priorCliSessionIds"]
        let folderKeys = ["originCwd", "permissionMode", "bypassChosenInApp", "autoChosenInApp", "worktreePath", "worktreeName",
            "worktreePinned", "worktreeLazy", "folderWorktrees", "keptDirtyWorktree", "keptDirtyAt", "gitAnchors",
            "gitAnchorsLookupOnly", "gitAnchorsFolderRealpath", "branch", "sourceBranch", "writtenBranches",
            "requestedAdditionalFolders", "sessionPermissionUpdates", "alwaysAllowedReasons", "enabledMcpTools",
            "remoteMcpServersConfig", "withheldConnectorHosts", "chromePermissionMode", "chromeAllowedDomains", "cuAllowedApps", "cuGrantFlags"]
        var keys = ownKeys
        if transfer.targetCwd == transfer.source.cwd { keys += folderKeys }
        if transfer.kind == .update, destination["cliSessionId"] as? String == transfer.source.cliSessionID {
            keys += ["rewindEdges", "transcriptCuts", "transcriptModelStates"]
        }
        for key in keys where destination[key] != nil && !(destination[key] is NSNull) { record[key] = destination[key] }
        record["lastActivityAt"] = max(transfer.source.lastActivityAt, (destination["lastActivityAt"] as? NSNumber)?.doubleValue ?? 0)
        record["lastFocusedAt"] = [transfer.lastFocusedAt, (destination["lastFocusedAt"] as? NSNumber)?.doubleValue].compactMap { $0 }.max()
        if ["user", "tool"].contains(destination["titleSource"] as? String ?? ""),
           !["user", "tool"].contains(transfer.source.titleSource ?? "") {
            record["title"] = destination["title"] as? String
            record["titleSource"] = destination["titleSource"] as? String
        }
        if let imported = destination["importedFrom"] as? String { record["importedFrom"] = imported }
        else if transfer.approvals.trusted { record.removeValue(forKey: "importedFrom") }
        else { record["importedFrom"] = "local-1p-code" }
        if let cli = destination["cliSessionId"] as? String, safeIdentifier(cli), cli != transfer.source.cliSessionID {
            var prior = record["priorCliSessionIds"] as? [String] ?? []
            if !prior.contains(cli) { prior.append(cli) }
            record["priorCliSessionIds"] = prior
        }
    }

    /// Preserve native-only lines on extensions, and never shorten a file already containing these messages.
    private static func nativeBytes(_ transcript: Data, at url: URL, cwds: Set<String>) -> Data? {
        guard fileType(url, followingLinks: true) == S_IFREG, let raw = try? Data(contentsOf: url),
              let normalized = try? normalizedTranscript(raw, cwds: cwds) else { return transcript }
        if hasPrefix(normalized, transcript) { return nil }
        if hasPrefix(transcript, normalized), raw.isEmpty || raw.last == 0x0A {
            var extended = raw
            extended.append(transcript.dropFirst(normalized.count))
            return extended
        }
        return transcript
    }

    /// Writes only the target account. The caller must quit its Claude before applying.
    static func apply(_ transfer: ChatTransfer, backups: URL, now: Date = Date()) throws {
        guard transfer.kind != .upToDate else { return }
        guard safeIdentifier(transfer.source.sessionID), safeIdentifier(transfer.source.cliSessionID),
              transfer.chatID == transfer.source.sessionID else { throw ChatError.unsupported }
        let manager = FileManager.default
        let source = transfer.source
        var destination: [String: Any]?
        if let url = transfer.targetRecord {
            guard fileType(url) == S_IFREG, let data = try? Data(contentsOf: url),
                  let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let copy = parseRecord(data, namespace: transfer.targetNamespace, spaceID: transfer.targetSpaceID),
                  copy.sessionID == transfer.chatID, copy.cwd == transfer.targetCwd else { throw ChatError.unreadableTarget }
            destination = existing
        }
        var record: [String: Any]
        if transfer.kind == .updateMetadata {
            guard let destination else { throw ChatError.unreadableTarget }
            record = destination
            record["lastFocusedAt"] = [transfer.lastFocusedAt, (destination["lastFocusedAt"] as? NSNumber)?.doubleValue].compactMap { $0 }.max()
        } else {
            record = ["cliSessionId": source.cliSessionID, "createdAt": source.createdAt, "cwd": source.cwd,
                      "importedFrom": "local-1p-code", "isArchived": false, "lastActivityAt": source.lastActivityAt,
                      "originCwd": source.originCwd ?? source.cwd, "sessionId": source.sessionID]
            if let title = source.title { record["title"] = title; record["titleSource"] = source.titleSource }
            record["lastFocusedAt"] = transfer.lastFocusedAt
            if let destination { mergeOwnKeys(destination, into: &record, transfer: transfer) }
        }
        let tombstone = transfer.targetNamespace.appendingPathComponent("deleted_" + transfer.chatID.dropFirst("local_".count))
        guard !manager.fileExists(atPath: tombstone.path) else { throw ChatError.removedInTarget }
        if transfer.kind == .add {
            let recordURL = transfer.targetNamespace.appendingPathComponent(source.sessionID + ".json")
            guard !manager.fileExists(atPath: recordURL.path) else { throw ChatError.removedInTarget }
        }
        let hadLineage = ChatLineage.has(record)
        ChatLineage.cleanOwn(in: &record, sessionID: transfer.chatID)
        if !hadLineage { transfer.lineage.write(to: &record) }
        transfer.approvals.write(to: &record)
        let writesTranscript = transfer.kind != .updateMetadata || transfer.promoteTranscript
        guard !writesTranscript || !transfer.transcript.isEmpty else { throw ChatError.transcriptMissing }
        let transcriptURL: URL?
        let transcriptBytes: Data?
        if transfer.approvals.trusted {
            guard let cwd = record["cwd"] as? String, let cli = record["cliSessionId"] as? String else { throw ChatError.unsupported }
            transcriptURL = writesTranscript ? try nativeTranscriptURL(config: transfer.targetConfig, cwd: cwd, cliSessionID: cli) : nil
            let cwds = source.transcriptCwds.union(["cwd", "originCwd", "worktreePath"].compactMap { destination?[$0] as? String })
            transcriptBytes = transcriptURL.flatMap { nativeBytes(transfer.transcript, at: $0, cwds: cwds) }
            record.removeValue(forKey: "stagedTranscriptPath")
        } else if writesTranscript {
            let digest = SHA256.hash(data: transfer.transcript).map { String(format: "%02x", $0) }.joined()
            transcriptURL = transfer.targetNamespace.appendingPathComponent("imported-staging", isDirectory: true)
                .appendingPathComponent("\(source.cliSessionID)-\(digest)", isDirectory: true)
                .appendingPathComponent(source.cliSessionID + ".jsonl")
            transcriptBytes = transfer.transcript
            record["stagedTranscriptPath"] = transcriptURL?.path
            if record["importedFrom"] == nil { record["importedFrom"] = "local-1p-code" }
        } else {
            transcriptURL = nil
            transcriptBytes = nil
        }
        if let transcriptURL {
            guard fileType(transcriptURL) == nil || fileType(transcriptURL) == S_IFREG else { throw ChatError.unsupported }
            if !transfer.approvals.trusted {
                for folder in [transcriptURL.deletingLastPathComponent(), transfer.targetNamespace.appendingPathComponent("imported-staging")] {
                    guard fileType(folder) == nil || fileType(folder) == S_IFDIR else { throw ChatError.unsupported }
                }
            }
        }
        let files = [transfer.targetRecord, transcriptBytes != nil ? transfer.targetTranscript : nil,
                     transcriptBytes != nil ? transcriptURL : nil].compactMap { $0 }.filter { manager.fileExists(atPath: $0.path) }
        if !files.isEmpty {
            let stamp = ISO8601DateFormatter().string(from: now).replacingOccurrences(of: ":", with: "-")
            let unique = UUID().uuidString.prefix(8).lowercased()
            let folder = backups.appendingPathComponent("\(stamp)-\(transfer.chatID)-\(unique)", isDirectory: true)
            try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var saved: Set<URL> = []
            for file in files where saved.insert(file.standardizedFileURL.resolvingSymlinksInPath()).inserted {
                // Compare against exactly what will be written, including retained native-only lines.
                if file != transfer.targetRecord, let transcriptBytes,
                   let old = try? Data(contentsOf: file), hasPrefix(transcriptBytes, old) { continue }
                var backup = folder.appendingPathComponent(file.lastPathComponent)
                if manager.fileExists(atPath: backup.path) { backup = folder.appendingPathComponent("native-" + file.lastPathComponent) }
                try manager.copyItem(at: file, to: backup)
            }
        }
        if let transcriptURL, let transcriptBytes {
            try manager.createDirectory(at: transcriptURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try writeAtomically(transcriptBytes, to: transcriptURL)
        }
        if transfer.approvals.trusted, let transcriptURL { copySubagents(transfer, to: transcriptURL) }
        let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .withoutEscapingSlashes])
        try writeAtomically(data, to: transfer.targetNamespace.appendingPathComponent(source.sessionID + ".json"))
    }

    private static func copySubagents(_ transfer: ChatTransfer, to native: URL) {
        guard let source = transfer.sourceTranscript else { return }
        let cli = transfer.source.cliSessionID
        let sourceChat = source.deletingLastPathComponent().appendingPathComponent(cli)
        let sourceFolder = sourceChat.appendingPathComponent("subagents")
        let targetChat = native.deletingLastPathComponent().appendingPathComponent(cli)
        let targetFolder = targetChat.appendingPathComponent("subagents")
        guard fileType(sourceChat) == S_IFDIR, fileType(sourceFolder) == S_IFDIR,
              fileType(targetChat) == nil || fileType(targetChat) == S_IFDIR,
              fileType(targetFolder) == nil || fileType(targetFolder) == S_IFDIR,
              let files = try? FileManager.default.contentsOfDirectory(at: sourceFolder, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("agent-"), name.hasSuffix(".jsonl") || name.hasSuffix(".meta.json"), fileType(file) == S_IFREG else { continue }
            let target = targetFolder.appendingPathComponent(name)
            guard fileType(target) == nil else { continue }
            if name.hasSuffix(".jsonl") {
                guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
                defer { try? handle.close() }
                guard let size = try? handle.seekToEnd(), size > 0,
                      (try? handle.seek(toOffset: size - 1)) != nil,
                      (try? handle.read(upToCount: 1)) == Data([0x0A]) else { continue }
            }
            try? FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? FileManager.default.copyItem(at: file, to: target)
        }
    }

    /// Remove only unreferenced digest folders whose bytes provably survive in the current transcript.
    static func removeUnusedStaging(in namespace: URL, space: SpaceFolders) {
        let manager = FileManager.default
        let staging = namespace.appendingPathComponent("imported-staging")
        guard fileType(staging) == S_IFDIR,
              let entries = try? manager.contentsOfDirectory(at: namespace, includingPropertiesForKeys: nil),
              let candidates = try? manager.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil) else { return }
        var references: [Data] = []
        for entry in entries {
            if fileType(entry) == S_IFDIR { continue }
            guard fileType(entry) == S_IFREG, let data = try? Data(contentsOf: entry) else { return }
            if entry.lastPathComponent.hasPrefix("local_"), entry.pathExtension == "json",
               (try? JSONSerialization.jsonObject(with: data)) == nil { return }
            references.append(data)
        }
        let visible = records(in: namespace, spaceID: space.spaceID)
        let folders = projectFolders(config: space.config)
        for folder in candidates where fileType(folder) == S_IFDIR {
            let name = folder.lastPathComponent
            guard name.count > 65 else { continue }
            let cli = String(name.dropLast(65))
            let suffix = name.suffix(65)
            guard safeIdentifier(cli), suffix.first == "-", suffix.dropFirst().allSatisfy({ "0123456789abcdef".contains($0) }),
                  !references.contains(where: { $0.range(of: Data(name.utf8)) != nil }),
                  let children = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            if children.isEmpty { _ = rmdir(folder.path); continue }
            guard children.count == 1, let file = children.first, file.lastPathComponent == cli + ".jsonl",
                  fileType(file) == S_IFREG else { continue }
            let copies = visible.filter { $0.cliSessionID == cli }
            guard copies.count == 1, let copy = copies.first,
                  let current = try? transcriptURL(for: copy, in: space, projectFolders: folders),
                  fileType(current, followingLinks: true) == S_IFREG,
                  let oldSize = (try? manager.attributesOfItem(atPath: file.path)[.size]) as? NSNumber,
                  let newSize = (try? manager.attributesOfItem(atPath: current.path)[.size]) as? NSNumber,
                  oldSize.uint64Value <= newSize.uint64Value,
                  let old = try? Data(contentsOf: file), let data = try? Data(contentsOf: current), hasPrefix(data, old) else { continue }
            if unlink(file.path) == 0 { _ = rmdir(folder.path) }
        }
    }

    static func nativeTranscriptURL(config: URL, cwd: String, cliSessionID: String) throws -> URL {
        guard cwd.hasPrefix("/"), safeIdentifier(cliSessionID) else { throw ChatError.unsupported }
        // Claude uses NFC, then replaces every non-ASCII-alphanumeric UTF-16 unit with a dash.
        let slug = String(cwd.precomposedStringWithCanonicalMapping.utf16.map {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) ? Character(UnicodeScalar($0)!) : "-"
        })
        guard !slug.isEmpty, slug.count <= 200 else { throw ChatError.unsupported }
        let projects = config.appendingPathComponent("projects", isDirectory: true).resolvingSymlinksInPath()
        let project = projects.appendingPathComponent(slug, isDirectory: true).resolvingSymlinksInPath()
        guard project.path.hasPrefix(projects.path + "/") else { throw ChatError.unsupported }
        return project.appendingPathComponent(cliSessionID + ".jsonl")
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
