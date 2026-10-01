import Foundation

/// Immutable transcript blobs plus a compare-and-replace catalog. Orphaned
/// blobs after an interrupted transaction are retained; no automatic GC runs.
struct ConversationLibraryStore: Sendable {
    let files: SecureManagedFileSystem
    private let catalogFiles: TrustedContainerFileStore
    let id: UUID

    init(applicationSupportURL: URL, id: UUID, create: Bool = false) throws {
        self.id = id
        files = try SecureManagedFileSystem(anchorURL: applicationSupportURL,
            rootComponents: ["ConversationLibraries", id.uuidString.lowercased()], createIfMissing: create)
        catalogFiles = TrustedContainerFileStore(container: try TrustedParallaxContainer(
            adoptingValidatedContainer: FileHandle(fileDescriptor: files.rootDescriptor, closeOnDealloc: false),
            url: URL(fileURLWithPath: files.rootPath)))
    }

    func read() throws -> ConversationLibrary? {
        switch try catalogFiles.read(named: "library.json", maximumBytes: .max) {
        case .missing: return nil
        case .bytes(let data):
            let library: ConversationLibrary
            do { library = try JSONDecoder().decode(ConversationLibrary.self, from: data) }
            catch { throw ConversationLibraryError.corrupt }
            try validate(library)
            return library
        }
    }

    func transaction<T>(_ body: (inout ConversationLibrary?) throws -> T) throws -> T {
        try catalogFiles.withExclusiveLock(named: ".conversation-library.lock") {
            let old = try read()
            var next = old
            let result = try body(&next)
            guard var next, next != old else { return result }
            guard next.generation < UInt64.max else { throw ConversationLibraryError.corrupt }
            next.generation = (old?.generation ?? 0) + 1
            try validate(next)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try catalogFiles.replace(encoder.encode(next), named: "library.json")
            return result
        }
    }

    @discardableResult
    func saveBlob(_ data: Data) throws -> String {
        let digest = LibraryPersistence.sha256(data)
        let path = try blobPath(digest)
        if try files.itemState(at: path) == .missing {
            let staged = try SecureManagedPath(["staged-" + UUID().uuidString.lowercased()])
            try files.write(data, to: staged)
            do { try files.rename(from: staged, to: path) }
            catch {
                // An exclusive writer may have finished the identical blob.
                guard (try? files.readFile(at: path)) == data else { throw error }
            }
        }
        guard try files.readFile(at: path) == data else { throw ConversationLibraryError.corrupt }
        return digest
    }

    func blob(_ digest: String) throws -> Data {
        let data = try files.readFile(at: blobPath(digest))
        guard LibraryPersistence.sha256(data) == digest else { throw ConversationLibraryError.corrupt }
        return data
    }

    private func blobPath(_ digest: String) throws -> SecureManagedPath {
        guard Self.isDigest(digest) else { throw ConversationLibraryError.corrupt }
        return try SecureManagedPath([digest + ".jsonl"])
    }

    static func isDigest(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) }
    }

    static func isConversationID(_ value: String) -> Bool {
        value.hasPrefix("local_") && UUID(uuidString: String(value.dropFirst(6))) != nil
    }

    private func validate(_ library: ConversationLibrary) throws {
        guard library.schemaVersion == 1 else { throw ConversationLibraryError.unsupported }
        guard library.id == id, (2...8).contains(library.bindings.count),
              Set(library.bindings.values.map(\.rootPath)).count == library.bindings.count else {
            throw ConversationLibraryError.corrupt
        }
        for (key, binding) in library.bindings {
            guard key == binding.profileStorageID.uuidString,
                  ClaudeConversationCopyService.validWorkingDirectory(binding.rootPath),
                  binding.namespace.count == 4,
                  Array(binding.namespace.prefix(2)) == ["UserData", "claude-code-sessions"],
                  UUID(uuidString: binding.namespace[2]) != nil,
                  UUID(uuidString: binding.namespace[3]) != nil,
                  !binding.label.isEmpty, binding.label.utf8.count <= 4096 else {
                throw ConversationLibraryError.corrupt
            }
            _ = try SecureManagedPath(binding.namespace)
            for (path, digest) in binding.foreignRecords {
                _ = try SecureManagedPath(path.components(separatedBy: "/"))
                guard Self.isDigest(digest) else { throw ConversationLibraryError.corrupt }
            }
        }
        for (key, conversation) in library.conversations {
            guard key == conversation.id, Self.isConversationID(key),
                  conversation.title.utf8.count <= 4096,
                  conversation.revisions[conversation.head] != nil,
                  Set(conversation.projections.keys).isSubset(of: Set(library.bindings.keys)),
                  Set(conversation.problems.keys).isSubset(of: Set(library.bindings.keys)) else {
                throw ConversationLibraryError.corrupt
            }
            for (digest, revision) in conversation.revisions {
                guard digest == revision.digest, Self.isDigest(digest), Self.isDigest(revision.originalDigest),
                      revision.parent == nil || (revision.parent != digest && conversation.revisions[revision.parent ?? ""] != nil),
                      library.bindings[revision.sourceProfileID.uuidString] != nil,
                      UUID(uuidString: revision.sourceAccountID) != nil, UUID(uuidString: revision.sourceOrganizationID) != nil,
                      UUID(uuidString: revision.cliSessionID) != nil,
                      ClaudeConversationCopyService.validWorkingDirectory(revision.workingDirectory),
                      revision.createdAt.isFinite, revision.createdAt >= 0,
                      revision.lastActivityAt.isFinite, revision.lastActivityAt >= 0 else {
                    throw ConversationLibraryError.corrupt
                }
            }
            for revision in conversation.revisions.values {
                var ancestors = Set<String>([revision.digest])
                var parent = revision.parent
                while let digest = parent {
                    guard ancestors.insert(digest).inserted else { throw ConversationLibraryError.corrupt }
                    parent = conversation.revisions[digest]?.parent
                }
            }
            for projection in conversation.projections.values {
                guard conversation.revisions[projection.revision] != nil,
                      Self.isDigest(projection.recordDigest), Self.isDigest(projection.transcriptDigest) else {
                    throw ConversationLibraryError.corrupt
                }
            }
            for (key, fingerprint) in conversation.reviewedSourceFailures ?? [:] {
                guard library.bindings[key] != nil, fingerprint == "unreadable" || Self.isDigest(fingerprint) else {
                    throw ConversationLibraryError.corrupt
                }
            }
        }
        guard Set(library.unavailableRecords.keys).isSubset(of: Set(library.bindings.keys)) else {
            throw ConversationLibraryError.corrupt
        }
        for records in library.unavailableRecords.values {
            for (name, digest) in records {
                _ = try SecureManagedPath([name])
                guard ConversationLibraryClaudeAdapter.isRecord(name), digest == "unreadable" || Self.isDigest(digest) else {
                    throw ConversationLibraryError.corrupt
                }
            }
        }
        if let active = library.activeProfileID, library.bindings[active.uuidString] == nil { throw ConversationLibraryError.corrupt }
        if let selected = library.selectedConversationID, library.conversations[selected] == nil { throw ConversationLibraryError.corrupt }
        if let handoff = library.handoff {
            guard library.bindings[handoff.targetProfileID.uuidString] != nil,
                  handoff.sourceProfileID == nil || library.bindings[handoff.sourceProfileID?.uuidString ?? ""] != nil,
                  handoff.conversationID == nil || library.conversations[handoff.conversationID ?? ""] != nil else {
                throw ConversationLibraryError.corrupt
            }
        }
    }
}
