import Foundation

struct ConversationAccountCandidate: Identifiable, Equatable, Sendable {
    let namespace: [String]
    let conversationCount: Int
    var id: String { namespace.joined(separator: "/") }
    var label: String {
        let count: Int = conversationCount
        let account: String = String(namespace[2].prefix(8))
        let organization: String = String(namespace[3].prefix(8))
        return String(localized: "\(count) chats · \(account) / \(organization)")
    }
}

enum ConversationLibraryClaudeAdapter {
    static func artifactReview(files: SecureManagedFileSystem, namespace: [String]) throws -> (Set<String>, Int) {
        let path = try SecureManagedPath(namespace)
        guard try candidates(files).contains(where: { $0.namespace == namespace }) else { throw ConversationLibraryError.accountChanged }
        var urls = Set<String>()
        var unavailable = 0
        for name in try files.directoryNames(at: path) where isRecord(name) {
            try Task.checkCancellation()
            do {
                let record = try path.appending(name)
                let native = try ClaudeConversationCopyService.conversation(data: files.readFile(at: record), path: record)
                let transcript = try files.readFile(at: ClaudeConversationCopyService(files: files).transcriptPath(for: native))
                urls.formUnion(ClaudeArtifactReferenceScanner.scan(transcript).map(\.url))
            } catch { unavailable += 1 }
        }
        return (urls, unavailable)
    }

    static func candidates(_ files: SecureManagedFileSystem) throws -> [ConversationAccountCandidate] {
        try ClaudeConversationCopyService(files: files).accountNamespaces().map { path in
            ConversationAccountCandidate(namespace: path.components,
                conversationCount: try files.directoryNames(at: path).filter(isRecord).count)
        }.sorted { $0.id < $1.id }
    }

    static func bind(profileID: UUID, label: String, namespace: [String],
                     files: SecureManagedFileSystem) throws -> ConversationAccountBinding {
        guard try candidates(files).contains(where: { $0.namespace == namespace }) else {
            throw ConversationLibraryError.accountChanged
        }
        guard case .present(let identity) = try files.itemState(at: SecureManagedPath(namespace)), identity.kind == .directory else {
            throw ConversationLibraryError.accountChanged
        }
        return ConversationAccountBinding(profileStorageID: profileID, rootPath: files.rootPath,
            namespace: namespace, rootFileID: UInt64(files.rootIdentity.inode),
            rootVolumeID: UInt64(bitPattern: Int64(files.rootIdentity.device)), namespaceFileID: identity.fileID,
            label: label, foreignRecords: try foreignRecords(files, excluding: namespace))
    }

    static func validate(_ binding: ConversationAccountBinding, files: SecureManagedFileSystem) throws {
        guard files.rootPath == binding.rootPath,
              UInt64(files.rootIdentity.inode) == binding.rootFileID,
              UInt64(bitPattern: Int64(files.rootIdentity.device)) == binding.rootVolumeID,
              case .present(let identity) = try files.itemState(at: SecureManagedPath(binding.namespace)),
              identity.kind == .directory, identity.fileID == binding.namespaceFileID,
              try candidates(files).contains(where: { $0.namespace == binding.namespace }),
              try foreignRecords(files, excluding: binding.namespace) == binding.foreignRecords else {
            throw ConversationLibraryError.accountChanged
        }
    }

    private static func foreignRecords(_ files: SecureManagedFileSystem, excluding namespace: [String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for candidate in try candidates(files) where candidate.namespace != namespace {
            let path = try SecureManagedPath(candidate.namespace)
            for name in try files.directoryNames(at: path) where isRecord(name) {
                let record = try path.appending(name)
                result[record.components.joined(separator: "/")] = try LibraryPersistence.sha256(files.readFile(at: record))
            }
        }
        return result
    }

    static func isRecord(_ name: String) -> Bool { name.hasPrefix("local_") && name.hasSuffix(".json") }

    /// The last capture must still describe the inactive source immediately
    /// before destination publication. A separate process is never a lease.
    static func validateCapture(binding: ConversationAccountBinding, files: SecureManagedFileSystem,
                                library: ConversationLibrary) throws {
        try validate(binding, files: files)
        let key = binding.profileStorageID.uuidString
        let namespace = try SecureManagedPath(binding.namespace)
        var expectedNames = Set(library.unavailableRecords[key, default: [:]].keys)
        for conversation in library.conversations.values {
            guard let projection = conversation.projections[key], projection.disposition != .missing,
                  conversation.problems[key] != .unavailable else { continue }
            let name = conversation.id + ".json"
            // An explicit restore of a removed record is allowed to be absent.
            let path = try namespace.appending(name)
            if projection.restoreRequested, try files.itemState(at: path) == .missing { continue }
            expectedNames.insert(name)
            let bytes = try files.readFile(at: path)
            guard LibraryPersistence.sha256(bytes) == projection.recordDigest else { throw ConversationLibraryError.changed }
            let native = try ClaudeConversationCopyService.conversation(data: bytes, path: path)
            let transcript = try files.readFile(at: ClaudeConversationCopyService(files: files).transcriptPath(for: native))
            guard LibraryPersistence.sha256(transcript) == projection.transcriptDigest else { throw ConversationLibraryError.changed }
        }
        guard Set(try files.directoryNames(at: namespace).filter(isRecord)) == expectedNames else {
            throw ConversationLibraryError.changed
        }
    }

    /// Only this binding is scanned. Missing files become local removal state,
    /// never a request to restore or delete a conversation in another account.
    static func capture(binding: ConversationAccountBinding, files: SecureManagedFileSystem,
                        library: inout ConversationLibrary, store: ConversationLibraryStore) throws {
        try validate(binding, files: files)
        let profile = binding.profileStorageID.uuidString
        let namespace = try SecureManagedPath(binding.namespace)
        let names = try files.directoryNames(at: namespace).filter(isRecord).sorted()
        var seen = Set<String>()
        library.unavailableRecords[profile] = [:]
        for name in names {
            try Task.checkCancellation()
            let id = String(name.dropLast(5))
            seen.insert(id)
            try autoreleasepool {
                let path = try namespace.appending(name)
                let bytes: Data
                do { bytes = try files.readFile(at: path) }
                catch {
                    library.unavailableRecords[profile, default: [:]][name] = "unreadable"
                    library.conversations[id]?.problems[profile] = .unavailable
                    return
                }
                // Session records may contain permissions or spawn secrets.
                // Keep only their digest, never their raw bytes, in the library.
                let rawRecordDigest = LibraryPersistence.sha256(bytes)
                let snapshot: (ClaudeConversation, Data, Data, Bool)
                do {
                    let conversation = try ClaudeConversationCopyService.conversation(data: bytes, path: path)
                    let original = try files.readFile(at: ClaudeConversationCopyService(files: files).transcriptPath(for: conversation))
                    let projection = library.conversations[id]?.projections[profile]
                    let normalized: Data
                    if projection?.recordDigest == conversation.recordDigest,
                       projection?.transcriptDigest == LibraryPersistence.sha256(original),
                       projection?.disposition == .present,
                       library.conversations[id]?.problems[profile] != .unavailable,
                       library.conversations[id]?.problems[profile] != .missing {
                        // Hashes are rechecked; mtime is never a trust signal.
                        return
                    } else {
                        normalized = try ClaudeConversationCopyService.importTranscript(original, conversation: conversation)
                    }
                    guard try files.readFile(at: path) == bytes else { throw ConversationLibraryError.changed }
                    let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                    snapshot = (conversation, original, normalized, object?["isArchived"] as? Bool == true)
                } catch {
                    library.unavailableRecords[profile, default: [:]][name] = rawRecordDigest
                    library.conversations[id]?.problems[profile] = .unavailable
                    return
                }
                try ingest(snapshot.0, original: snapshot.1, normalized: snapshot.2, archived: snapshot.3,
                    binding: binding, library: &library, store: store)
            }
        }
        for id in library.conversations.keys where !seen.contains(id) {
            guard var conversation = library.conversations[id], var projection = conversation.projections[profile] else { continue }
            if projection.restoreRequested { continue }
            projection.disposition = .missing
            conversation.projections[profile] = projection
            conversation.problems[profile] = .missing
            library.conversations[id] = conversation
        }
        try validate(binding, files: files)
    }

    private static func ingest(_ native: ClaudeConversation, original: Data, normalized: Data, archived: Bool,
                               binding: ConversationAccountBinding, library: inout ConversationLibrary,
                               store: ConversationLibraryStore) throws {
        let profile = binding.profileStorageID.uuidString
        let digest = try store.saveBlob(normalized)
        let originalDigest = try store.saveBlob(original)
        var conversation = library.conversations[native.sessionID]
        let oldProjection = conversation?.projections[profile]
        if oldProjection?.recordDigest == native.recordDigest, oldProjection?.transcriptDigest == originalDigest,
           oldProjection?.disposition == .present, conversation?.problems[profile] != .unavailable,
           conversation?.problems[profile] != .missing {
            return
        }
        let revision = ConversationRevision(digest: digest, originalDigest: originalDigest,
            parent: oldProjection?.revision == digest ? nil : oldProjection?.revision,
            sourceProfileID: binding.profileStorageID, sourceAccountID: binding.namespace[2],
            sourceOrganizationID: binding.namespace[3], cliSessionID: native.cliSessionID,
            workingDirectory: native.workingDirectory, createdAt: native.createdAt, lastActivityAt: native.lastActivityAt)
        if conversation == nil {
            conversation = LibraryConversation(id: native.sessionID, title: native.title, head: digest,
                revisions: [digest: revision], archived: archived)
        }
        guard var value = conversation, let head = value.revisions[value.head] else { throw ConversationLibraryError.corrupt }
        var compatible = head.cliSessionID == native.cliSessionID && head.workingDirectory == native.workingDirectory
        if compatible, value.head != digest {
            let previous = try store.blob(value.head)
            if normalized.starts(with: previous) {
                value.head = digest
            } else if previous.starts(with: normalized) {
                // An unchanged old account is an out-of-date working copy. A
                // writer that truncated its own latest revision is a conflict.
                compatible = oldProjection == nil || oldProjection?.revision == digest
            } else if oldProjection?.revision == value.head,
                      library.activeProfileID == binding.profileStorageID,
                      try supportedCompaction(previous: previous, next: normalized) {
                value.head = digest
            } else { compatible = false }
        }
        if value.revisions[digest] == nil { value.revisions[digest] = revision }
        if !archived { value.archived = false }
        if compatible, value.head == digest { value.title = native.title }
        value.projections[profile] = ConversationProjection(revision: digest, recordDigest: native.recordDigest,
            transcriptDigest: originalDigest, disposition: archived ? .archived : .present,
            restoreRequested: oldProjection?.restoreRequested ?? false)
        if !compatible { value.problems[profile] = .conflict }
        else if archived { value.problems[profile] = .archived }
        else if value.problems[profile] != .conflict { value.problems[profile] = nil }
        library.conversations[value.id] = value
    }

    /// Admit only a compaction explicitly anchored to the prior final message.
    /// Other rewrites retain a branch for review, even from the active account.
    static func supportedCompaction(previous: Data, next: Data) throws -> Bool {
        var lastMessage: String?
        try HistoryFileBuffer.forEachLine(in: previous) { line in
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if ["user", "assistant"].contains(object["type"] as? String ?? ""), object["isSidechain"] as? Bool != true {
                lastMessage = object["uuid"] as? String
            }
        }
        guard let lastMessage else { return false }
        var first: [String: Any]?
        try HistoryFileBuffer.forEachLine(in: next) { line in
            if first == nil { first = try JSONSerialization.jsonObject(with: line) as? [String: Any] }
        }
        return first?["type"] as? String == "system" && first?["subtype"] as? String == "compact_boundary"
            && first?["logicalParentUuid"] as? String == lastMessage
    }
}
