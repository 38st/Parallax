import Foundation

enum ConversationLibraryService {
    /// Add accounts without replacing the catalog or losing retained revisions.
    /// Repeating after catalog publication but before receipt publication is safe.
    static func includeAccounts(store: ConversationLibraryStore, bindings: [ConversationAccountBinding],
                                participants: [SharedHistoryParticipant], allowRebinding: Bool = false) throws {
        guard Set(bindings.map(\.profileStorageID)).count == bindings.count,
              Set(bindings.map(\.profileStorageID)) == Set(participants.map(\.storageID)),
              participants.count == bindings.count, participants.allSatisfy({ $0.provider == "claude" }) else {
            throw ConversationLibraryError.changed
        }
        let next = Dictionary(uniqueKeysWithValues: bindings.map { ($0.profileStorageID.uuidString, $0) })
        try store.transaction { document in
            guard var library = document, library.handoff == nil,
                  Set(library.bindings.keys).isSubset(of: Set(next.keys)) else { throw ConversationLibraryError.changed }
            for (key, old) in library.bindings {
                guard let binding = next[key] else { throw ConversationLibraryError.changed }
                guard allowRebinding || old == binding else { throw ConversationLibraryError.accountChanged }
                if old.namespace != binding.namespace || old.rootFileID != binding.rootFileID
                    || old.rootVolumeID != binding.rootVolumeID || old.namespaceFileID != binding.namespaceFileID {
                    if library.activeProfileID == binding.profileStorageID { library.activeProfileID = nil }
                    for id in library.conversations.keys {
                        library.conversations[id]?.projections[key] = nil
                        library.conversations[id]?.problems[key] = nil
                        library.conversations[id]?.reviewedSourceFailures?[key] = nil
                    }
                }
            }
            library.bindings = next
            for participant in participants {
                guard let binding = next[participant.storageID.uuidString] else { throw ConversationLibraryError.changed }
                try ConversationLibraryClaudeAdapter.capture(binding: binding, files: participant.files, library: &library, store: store)
            }
            document = library
        }
    }

    static func messagePreview(_ transcript: Data) throws -> String {
        var messages: [String] = []
        try HistoryFileBuffer.forEachLine(in: transcript) { line in
            guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any],
                  ["user", "assistant"].contains(object["type"] as? String ?? ""),
                  object["isSidechain"] as? Bool != true,
                  let message = object["message"] as? [String: Any] else { return }
            let content = message["content"] as? String
                ?? (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
            if let content, !content.isEmpty {
                messages.append(String(content.prefix(2_000)))
                if messages.count > 4 { messages.removeFirst() }
            }
        }
        return messages.joined(separator: "\n\n")
    }

    static func rebind(store: ConversationLibraryStore, bindings: [ConversationAccountBinding]) throws {
        try store.transaction { document in
            guard var library = document, library.handoff == nil,
                  Set(bindings.map { $0.profileStorageID.uuidString }) == Set(library.bindings.keys) else {
                throw ConversationLibraryError.changed
            }
            for binding in bindings {
                let key = binding.profileStorageID.uuidString
                guard let old = library.bindings[key] else { throw ConversationLibraryError.changed }
                if old.namespace != binding.namespace || old.rootFileID != binding.rootFileID
                    || old.rootVolumeID != binding.rootVolumeID || old.namespaceFileID != binding.namespaceFileID {
                    if library.activeProfileID == binding.profileStorageID { library.activeProfileID = nil }
                    for id in library.conversations.keys {
                        library.conversations[id]?.projections[key] = nil
                        library.conversations[id]?.problems[key] = nil
                        library.conversations[id]?.reviewedSourceFailures?[key] = nil
                    }
                }
                library.bindings[key] = binding
            }
            document = library
        }
    }

    static func beginSwitch(store: ConversationLibraryStore, targetID: UUID, selectedID: String?, requestID: UUID) throws {
        try store.transaction { document in
            guard var library = document, library.bindings[targetID.uuidString] != nil else { throw ConversationLibraryError.changed }
            if let pending = library.handoff {
                // A confirmed override retries the same request. It continues
                // the waiting handoff its first attempt entered.
                guard pending.id == requestID, pending.targetProfileID == targetID,
                      pending.conversationID == selectedID, pending.phase == .waiting else { throw ConversationLibraryError.busy }
                return
            }
            library.handoff = ConversationHandoff(id: requestID, sourceProfileID: library.activeProfileID,
                targetProfileID: targetID, conversationID: selectedID, phase: .waiting)
            document = library
        }
    }

    /// Nothing is captured or published while a handoff waits, so a launch
    /// that stops there can release it without reconciliation.
    @discardableResult
    static func releaseWaiting(store: ConversationLibraryStore, requestID: UUID) throws -> Bool {
        try store.transaction { document in
            guard var library = document, let pending = library.handoff,
                  pending.id == requestID, pending.phase == .waiting else { return false }
            library.handoff = nil
            document = library
            return true
        }
    }
    /// Migration writes only to the new library. Provider histories and legacy
    /// sharing receipts are not touched until the caller publishes enrollment.
    static func enroll(store: ConversationLibraryStore, applicationID: UUID,
                       bindings: [ConversationAccountBinding], participants: [SharedHistoryParticipant],
                       previouslySharedIDs: Set<String> = [], previousMembers: Set<UUID> = []) throws -> ConversationLibrary {
        guard Set(bindings.map(\.profileStorageID)) == Set(participants.map(\.storageID)),
              Set(bindings.map(\.profileStorageID)).count == bindings.count,
              participants.allSatisfy({ $0.provider == "claude" }) else { throw ConversationLibraryError.changed }
        try store.transaction { document in
            guard document == nil else {
                guard document?.applicationStorageID == applicationID,
                      document?.bindings == Dictionary(uniqueKeysWithValues: bindings.map { ($0.profileStorageID.uuidString, $0) }) else {
                    throw ConversationLibraryError.changed
                }
                return
            }
            var library = ConversationLibrary(id: store.id, applicationStorageID: applicationID,
                bindings: Dictionary(uniqueKeysWithValues: bindings.map { ($0.profileStorageID.uuidString, $0) }))
            for participant in participants {
                guard let binding = library.bindings[participant.storageID.uuidString] else { throw ConversationLibraryError.changed }
                try ConversationLibraryClaudeAdapter.capture(binding: binding, files: participant.files, library: &library, store: store)
            }
            // A legacy receipt proves these IDs had already been shared with
            // its members. Their absence there is a local removal; an account
            // that joins now was never part of that group and is seeded.
            let memberKeys = Set(previousMembers.map(\.uuidString))
            for id in previouslySharedIDs where library.conversations[id] != nil {
                for key in library.bindings.keys where memberKeys.contains(key)
                    && library.conversations[id]?.projections[key] == nil {
                    library.conversations[id]?.problems[key] = library.unavailableRecords[key]?[id + ".json"] == nil
                        ? .missing : .unavailable
                }
            }
            document = library
        }
        guard let library = try store.read() else { throw ConversationLibraryError.unavailable }
        return library
    }

    static func prepare(store: ConversationLibraryStore, targetID: UUID, selectedID: String?,
                        participants: [SharedHistoryParticipant], requestID: UUID? = nil,
                        beforePublication: () throws -> Void = {}) throws -> ConversationLibrary {
        // Catalog mutations are serialized across every window and process.
        // Profile reservations, held by the caller, cover native file writes.
        let handoffID = try store.transaction { document -> UUID in
            guard var library = document, library.bindings[targetID.uuidString] != nil,
                  Set(participants.map(\.storageID)) == Set(library.bindings.values.map(\.profileStorageID)),
                  participants.allSatisfy({ $0.provider == "claude" }) else { throw ConversationLibraryError.changed }
            if let pending = library.handoff {
                guard pending.targetProfileID == targetID, pending.conversationID == selectedID,
                      requestID == nil || pending.id == requestID else { throw ConversationLibraryError.busy }
            } else {
                // A cancelled/recovered launch cannot resurrect its request.
                guard requestID == nil else { throw ConversationLibraryError.changed }
                library.handoff = ConversationHandoff(id: UUID(), sourceProfileID: library.activeProfileID,
                    targetProfileID: targetID, conversationID: selectedID, phase: .capturing)
            }
            guard let pending = library.handoff, pending.phase != .opening else { throw ConversationLibraryError.busy }
            library.handoff?.phase = .capturing
            document = library
            return pending.id
        }
        // Save capture independently of publication. A full target disk cannot
        // make newly captured source messages disappear on the next retry.
        try store.transaction { document in
            guard var library = document, library.handoff?.id == handoffID,
                  library.handoff?.targetProfileID == targetID else { throw ConversationLibraryError.changed }
            for participant in participants where library.activeProfileID == nil
                || participant.storageID == library.activeProfileID || participant.storageID == targetID {
                guard let binding = library.bindings[participant.storageID.uuidString] else { throw ConversationLibraryError.changed }
                try ConversationLibraryClaudeAdapter.capture(binding: binding, files: participant.files, library: &library, store: store)
            }
            library.handoff?.phase = .preparing
            document = library
        }
        try beforePublication()
        try store.transaction { document in
            guard var library = document, let target = participants.first(where: { $0.storageID == targetID }),
                  let binding = library.bindings[targetID.uuidString], library.handoff?.id == handoffID,
                  library.handoff?.targetProfileID == targetID else {
                throw ConversationLibraryError.changed
            }
            for participant in participants where library.activeProfileID == nil
                || participant.storageID == library.activeProfileID || participant.storageID == targetID {
                guard let capturedBinding = library.bindings[participant.storageID.uuidString] else { throw ConversationLibraryError.changed }
                try ConversationLibraryClaudeAdapter.validateCapture(binding: capturedBinding, files: participant.files, library: library)
            }
            if let selectedID {
                guard let conversation = library.conversations[selectedID], !conversation.archived,
                      sourcesAllowPublication(conversation, library: library),
                      conversation.problems[targetID.uuidString] == nil else { throw ConversationLibraryError.selectedConversation }
            }
            for id in library.conversations.keys.sorted() {
                guard var conversation = library.conversations[id], !conversation.archived,
                      sourcesAllowPublication(conversation, library: library),
                      conversation.problems[targetID.uuidString] == nil else { continue }
                try publish(&conversation, binding: binding, files: target.files, store: store)
                library.conversations[id] = conversation
            }
            library.selectedConversationID = selectedID
            library.handoff?.phase = .ready
            document = library
        }
        guard let result = try store.read() else { throw ConversationLibraryError.unavailable }
        return result
    }

    static func markOpening(store: ConversationLibraryStore, targetID: UUID, requestID: UUID) throws {
        try store.transaction { document in
            guard var library = document, let handoff = library.handoff,
                  handoff.targetProfileID == targetID, handoff.phase == .ready,
                  handoff.id == requestID else { throw ConversationLibraryError.changed }
            library.handoff = ConversationHandoff(id: requestID, sourceProfileID: handoff.sourceProfileID,
                targetProfileID: targetID, conversationID: handoff.conversationID, phase: .opening)
            document = library
        }
    }

    /// A verified tracked process is evidence of launch, not of provider login
    /// or successful native resume. Those remain separate UI/manual evidence.
    static func completeOpening(store: ConversationLibraryStore, targetID: UUID, requestID: UUID) throws {
        try store.transaction { document in
            guard var library = document, let handoff = library.handoff,
                  handoff.phase == .opening, handoff.targetProfileID == targetID,
                  handoff.id == requestID else { throw ConversationLibraryError.changed }
            library.activeProfileID = targetID
            library.handoff = nil
            document = library
        }
    }

    /// Cancel only while all participants are confirmed inactive. Published
    /// copies and immutable revisions stay intact and will be reconciled later.
    static func recover(store: ConversationLibraryStore, expectedRequestID: UUID? = nil) throws {
        try store.transaction { document in
            guard var library = document else { throw ConversationLibraryError.unavailable }
            guard expectedRequestID == nil || library.handoff?.id == expectedRequestID else { throw ConversationLibraryError.changed }
            // An opening target may have run. Capture every account next time
            // instead of trusting the account that was active before it.
            if library.handoff?.phase == .opening { library.activeProfileID = nil }
            library.handoff = nil
            document = library
        }
    }

    static func chooseRevision(store: ConversationLibraryStore, conversationID: String, revisionID: String,
                               restoringTo profileID: UUID?) throws {
        try store.transaction { document in
            guard var library = document, library.handoff == nil,
                  var conversation = library.conversations[conversationID],
                  conversation.revisions[revisionID] != nil else { throw ConversationLibraryError.changed }
            _ = try store.blob(revisionID)
            conversation.head = revisionID
            conversation.archived = false
            // Changing the chosen version is explicit. Native bytes are still
            // checked against each projection before the next publication.
            conversation.problems = conversation.problems.filter { $0.value != .conflict }
            conversation.reviewedSourceFailures = Dictionary(uniqueKeysWithValues: conversation.problems.compactMap { key, problem in
                guard problem == .unavailable, let fingerprint = library.unavailableRecords[key]?[conversationID + ".json"] else { return nil }
                return (key, fingerprint)
            })
            if let profileID {
                guard library.bindings[profileID.uuidString] != nil else { throw ConversationLibraryError.changed }
                conversation.problems[profileID.uuidString] = nil
                conversation.projections[profileID.uuidString]?.disposition = .present
                conversation.projections[profileID.uuidString]?.restoreRequested = true
            }
            library.conversations[conversationID] = conversation
            document = library
        }
    }

    private static func sourcesAllowPublication(_ conversation: LibraryConversation, library: ConversationLibrary) -> Bool {
        for (key, problem) in conversation.problems {
            if problem == .conflict { return false }
            if problem == .unavailable {
                guard let fingerprint = library.unavailableRecords[key]?[conversation.id + ".json"],
                      conversation.reviewedSourceFailures?[key] == fingerprint else { return false }
            }
        }
        return true
    }

    private static func publish(_ conversation: inout LibraryConversation, binding: ConversationAccountBinding,
                                files: SecureManagedFileSystem, store: ConversationLibraryStore) throws {
        try ConversationLibraryClaudeAdapter.validate(binding, files: files)
        guard let revision = conversation.revisions[conversation.head] else { throw ConversationLibraryError.corrupt }
        let profile = binding.profileStorageID.uuidString
        let namespace = try SecureManagedPath(binding.namespace)
        let recordPath = try namespace.appending(conversation.id + ".json")
        let oldRecord: Data?
        if try files.itemState(at: recordPath) == .missing {
            guard conversation.projections[profile] == nil || conversation.projections[profile]?.restoreRequested == true else {
                throw ConversationLibraryError.changed
            }
            oldRecord = nil
        } else {
            let bytes = try files.readFile(at: recordPath)
            guard let projection = conversation.projections[profile], LibraryPersistence.sha256(bytes) == projection.recordDigest else {
                throw ConversationLibraryError.changed
            }
            let native = try ClaudeConversationCopyService.conversation(data: bytes, path: recordPath)
            let transcript = try files.readFile(at: ClaudeConversationCopyService(files: files).transcriptPath(for: native))
            guard LibraryPersistence.sha256(transcript) == projection.transcriptDigest else { throw ConversationLibraryError.changed }
            if projection.revision == conversation.head && !projection.restoreRequested { return }
            oldRecord = bytes
        }
        let data = try store.blob(revision.digest)
        let staging = try namespace.appending("imported-staging")
        if try files.itemState(at: staging) == .missing { try files.createDirectory(at: staging) }
        let directory = try staging.appending(revision.cliSessionID + "-" + revision.digest)
        if try files.itemState(at: directory) == .missing { try files.createDirectory(at: directory) }
        let path = try directory.appending(revision.cliSessionID + ".jsonl")
        guard try files.publishStagedHistoryFile(data, at: path),
              try files.readFile(at: path) == data else { throw ConversationLibraryError.corrupt }
        let record: [String: Any] = ["sessionId": conversation.id, "cliSessionId": revision.cliSessionID,
            "cwd": revision.workingDirectory, "originCwd": revision.workingDirectory, "title": conversation.title,
            "createdAt": revision.createdAt, "lastActivityAt": revision.lastActivityAt, "isArchived": false,
            "importedFrom": "local-1p-code", "stagedTranscriptPath": files.rootPath + "/" + path.components.joined(separator: "/")]
        let bytes = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        try ConversationLibraryClaudeAdapter.validate(binding, files: files)
        try files.replaceHistoryFile(at: recordPath, expected: oldRecord, with: bytes)
        conversation.projections[profile] = ConversationProjection(revision: revision.digest,
            recordDigest: LibraryPersistence.sha256(bytes), transcriptDigest: revision.digest)
    }
}
