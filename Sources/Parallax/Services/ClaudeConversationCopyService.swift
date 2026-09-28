import Foundation

/// Adapter for inspected Claude Desktop local Code session import formats.
/// Reads only session records and transcripts. Never reads the app's config,
/// cookies, Keychain, provider credentials, or account-tracker directories.
struct ClaudeConversationCopyService: Sendable {
    static let maximumTranscriptBytes = 64 * 1_024 * 1_024
    static let maximumRecordBytes = 1_024 * 1_024
    let files: SecureManagedFileSystem

    static var sessionsPath: SecureManagedPath {
        get throws { try SecureManagedPath(["UserData", "claude-code-sessions"]) }
    }

    func accountNamespaces() throws -> [SecureManagedPath] {
        let root = try Self.sessionsPath
        if try files.itemState(at: root) == .missing { return [] }
        var result: [SecureManagedPath] = []
        for account in try boundedNames(at: root) where UUID(uuidString: account) != nil {
            let accountPath = try root.appending(account)
            for organization in try boundedNames(at: accountPath) where UUID(uuidString: organization) != nil {
                let path = try accountPath.appending(organization)
                guard case .present(let identity) = try files.itemState(at: path),
                      identity.kind == .directory else { throw ClaudeConversationCopyError.unsupportedFormat }
                result.append(path)
            }
        }
        return result
    }

    func destinationNamespace() throws -> SecureManagedPath {
        let namespaces = try accountNamespaces()
        guard namespaces.count == 1, let namespace = namespaces.first else {
            throw namespaces.isEmpty ? ClaudeConversationCopyError.unavailable : .ambiguousAccount
        }
        return namespace
    }

    func catalog() throws -> ClaudeConversationCatalog {
        var catalog = ClaudeConversationCatalog()
        for namespace in try accountNamespaces() {
            for name in try boundedNames(at: namespace) where name.hasPrefix("local_") && name.hasSuffix(".json") {
                let path = try namespace.appending(name)
                let data = try files.readFile(at: path, maximumBytes: Self.maximumRecordBytes)
                do {
                    catalog.conversations.append(try Self.conversation(data: data, path: path))
                } catch {
                    catalog.unavailableCount += 1
                }
                guard catalog.conversations.count + catalog.unavailableCount <= 2_000 else {
                    throw ClaudeConversationCopyError.unsupportedFormat
                }
            }
        }
        catalog.conversations.sort {
            $0.lastActivityAt == $1.lastActivityAt ? $0.id < $1.id : $0.lastActivityAt > $1.lastActivityAt
        }
        return catalog
    }

    static func conversation(data: Data, path: SecureManagedPath) throws -> ClaudeConversation {
        guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let session = record["sessionId"] as? String, session.hasPrefix("local_"),
              UUID(uuidString: String(session.dropFirst(6))) != nil,
              path.components.last == session + ".json",
              let cli = record["cliSessionId"] as? String, UUID(uuidString: cli) != nil,
              let cwd = record["cwd"] as? String, validWorkingDirectory(cwd),
              let created = record["createdAt"] as? Double, created.isFinite, created >= 0,
              let activity = record["lastActivityAt"] as? Double, activity.isFinite, activity >= 0,
              record["sshConfig"] == nil || record["sshConfig"] is NSNull,
              record["wslConfig"] == nil || record["wslConfig"] is NSNull else {
            throw ClaudeConversationCopyError.unsupportedFormat
        }
        let title = record["title"] as? String ?? String(localized: "Untitled conversation")
        guard title.utf8.count <= 4_096 else { throw ClaudeConversationCopyError.unsupportedFormat }
        return ClaudeConversation(
            recordPath: path, recordDigest: LibraryPersistence.sha256(data), sessionID: session,
            cliSessionID: cli, title: title, workingDirectory: cwd, createdAt: created,
            lastActivityAt: activity, stagedTranscriptPath: record["stagedTranscriptPath"] as? String
        )
    }

    static func validWorkingDirectory(_ value: String) -> Bool {
        value.hasPrefix("/") && value.utf8.count <= 4_096
            && !value.contains("\0") && !value.contains("\n") && !value.contains("\r")
            && !value.split(separator: "/").contains(where: { $0 == ".." || $0 == "." })
    }

    func boundedNames(at path: SecureManagedPath) throws -> [String] {
        let names = try files.directoryNames(at: path)
        guard names.count <= 5_000 else { throw ClaudeConversationCopyError.unsupportedFormat }
        return names
    }

    func transcriptPath(for conversation: ClaudeConversation) throws -> SecureManagedPath {
        if let staged = conversation.stagedTranscriptPath {
            let prefix = files.rootPath + "/" + conversation.recordPath.components.dropLast().joined(separator: "/") + "/imported-staging/"
            guard staged.hasPrefix(prefix), staged.hasSuffix(".jsonl") else {
                throw ClaudeConversationCopyError.unsupportedFormat
            }
            let relative = String(staged.dropFirst(files.rootPath.count + 1))
            return try SecureManagedPath(relative.components(separatedBy: "/"))
        }
        let projects = try SecureManagedPath(["UserData", "ClaudeConfig", "projects"])
        guard try files.itemState(at: projects) != .missing else {
            throw ClaudeConversationCopyError.missingTranscript
        }
        var matches: [SecureManagedPath] = []
        for project in try boundedNames(at: projects) {
            let directory = try projects.appending(project)
            guard case .present(let identity) = try files.itemState(at: directory),
                  identity.kind == .directory else { continue }
            let transcript = try directory.appending(conversation.cliSessionID + ".jsonl")
            if try files.itemState(at: transcript) != .missing { matches.append(transcript) }
        }
        guard matches.count == 1, let match = matches.first else {
            throw ClaudeConversationCopyError.missingTranscript
        }
        return match
    }
}
