import Foundation

/// Local opt-in receipts, deliberately excluded from portable library imports.
/// An unreadable document blocks sharing; it is never reset to an empty default.
struct SharedHistoryStore: Sendable {
    private struct Document: Codable {
        var schemaVersion = 1
        var groups: [SharedHistoryGroup]
        var allAccountApplicationIDs: Set<UUID>?
    }
    private let files: TrustedContainerFileStore
    private static let name = "shared-history.json"

    init(applicationSupportURL: URL) throws {
        files = TrustedContainerFileStore(container: try TrustedParallaxContainer.establish(
            applicationSupportURL: applicationSupportURL))
    }

    func groups() throws -> [SharedHistoryGroup] {
        try document().groups
    }

    func includesAllAccounts(applicationID: UUID) throws -> Bool {
        try document().allAccountApplicationIDs?.contains(applicationID) == true
    }

    /// The application setting is independent of today's membership. It can
    /// be enabled before a newly added account has created any local history.
    func setIncludesAllAccounts(_ enabled: Bool, applicationID: UUID, expected: Bool) throws {
        try files.withExclusiveLock(named: ".shared-history.lock") {
            var current = try document()
            let previous = current.allAccountApplicationIDs?.contains(applicationID) == true
            guard previous == expected else { throw SharedHistoryError.changed }
            guard previous != enabled else { return }
            var ids = current.allAccountApplicationIDs ?? []
            if enabled { ids.insert(applicationID) } else { ids.remove(applicationID) }
            current.allAccountApplicationIDs = ids.isEmpty ? nil : ids
            try validatePolicy(current)
            try publish(current)
        }
    }

    private func document() throws -> Document {
        // Required IDs and baselines grow with history; only the optional cache
        // below has a size budget. Receipt size must not cap conversation count.
        switch try files.read(named: Self.name, maximumBytes: .max) {
        case .missing: return Document(groups: [])
        case .bytes(let bytes):
            let document = try JSONDecoder().decode(Document.self, from: bytes)
            guard [1, 2, 3].contains(document.schemaVersion),
                  document.schemaVersion >= 2 || document.groups.allSatisfy({ $0.conversationLibraryID == nil }),
                  document.schemaVersion >= 3 || (document.allAccountApplicationIDs == nil
                    && document.groups.allSatisfy({ (2...8).contains($0.profileStorageIDs.count) })) else {
                throw SharedHistoryError.unavailable
            }
            try validate(document.groups)
            try validatePolicy(document)
            return document
        }
    }

    func replace(_ expected: SharedHistoryGroup?, with replacement: SharedHistoryGroup?,
                 requiringAllAccountsFor applicationID: UUID? = nil) throws {
        try files.withExclusiveLock(named: ".shared-history.lock") {
            var current = try document()
            if let applicationID {
                guard current.allAccountApplicationIDs?.contains(applicationID) == true else { throw SharedHistoryError.changed }
            }
            var groups = current.groups
            if let expected {
                guard groups.first(where: { $0.id == expected.id }) == expected else { throw SharedHistoryError.changed }
                groups.removeAll { $0.id == expected.id }
            }
            if let replacement {
                guard validMemberCount(replacement),
                      ["claude", "codex"].contains(replacement.provider),
                      groups.count < 128,
                      Set(replacement.profileStorageIDs).count == replacement.profileStorageIDs.count,
                      !groups.contains(where: {
                          $0.applicationStorageID == replacement.applicationStorageID
                              && !Set($0.profileStorageIDs).isDisjoint(with: replacement.profileStorageIDs)
                      }) else { throw SharedHistoryError.invalidSelection }
                groups.append(replacement)
            }
            try validate(groups)
            current.groups = groups
            // An explicit disconnect must not silently re-link on the next open.
            if replacement == nil, let expected {
                current.allAccountApplicationIDs?.remove(expected.applicationStorageID)
                if current.allAccountApplicationIDs?.isEmpty == true { current.allAccountApplicationIDs = nil }
            }
            try validatePolicy(current)
            try publish(current)
        }
    }

    private func publish(_ document: Document) throws {
        var document = document
        let migrated = document.groups.contains { $0.conversationLibraryID != nil }
        let allAccounts = document.allAccountApplicationIDs?.isEmpty == false
            || document.groups.contains { !(2...8).contains($0.profileStorageIDs.count) }
        document.schemaVersion = max(document.schemaVersion, allAccounts ? 3 : migrated ? 2 : 1)
        if document.schemaVersion >= 2, case .bytes(let old) = try files.read(named: Self.name, maximumBytes: .max),
           (try? JSONDecoder().decode(Document.self, from: old).schemaVersion) == 1 {
            let backup = "shared-history-v1-" + LibraryPersistence.sha256(old) + ".json"
            switch try files.read(named: backup, maximumBytes: .max) {
            case .missing: try files.replace(old, named: backup)
            case .bytes(let existing): guard existing == old else { throw SharedHistoryError.changed }
            }
        }
        // Older binaries must not silently ignore the all-accounts setting.
        let bytes = try JSONEncoder().encode(document)
        try files.replace(bytes, named: Self.name)
    }

    private func validatePolicy(_ document: Document) throws {
        for id in document.allAccountApplicationIDs ?? [] {
            let groups = document.groups.filter { $0.applicationStorageID == id }
            guard groups.count <= 1, groups.allSatisfy({ $0.provider == "claude" }) else {
                throw AllAccountHistoryError.multipleLibraries
            }
        }
    }

    private func validMemberCount(_ group: SharedHistoryGroup) -> Bool {
        group.conversationLibraryID != nil ? !group.profileStorageIDs.isEmpty : (2...8).contains(group.profileStorageIDs.count)
    }

    /// Bound the optional speed-up independently of required IDs and baselines.
    func fittingValidationCache(_ proposed: SharedHistoryGroup, replacing expected: SharedHistoryGroup) throws -> SharedHistoryGroup {
        guard proposed.claudeValidation != nil else { return proposed }
        var groups = try self.groups()
        guard let index = groups.firstIndex(of: expected) else { throw SharedHistoryError.changed }
        groups[index] = proposed
        if try JSONEncoder().encode(Document(groups: groups)).count <= 4 * 1_024 * 1_024 { return proposed }
        var uncached = proposed
        uncached.claudeValidation = nil
        return uncached
    }

    private func validate(_ groups: [SharedHistoryGroup]) throws {
        guard groups.count <= 128, Set(groups.map(\.id)).count == groups.count else {
            throw SharedHistoryError.unavailable
        }
        var members = Set<String>()
        for group in groups {
            if let libraryID = group.conversationLibraryID {
                guard group.provider == "claude", libraryID == group.id else { throw SharedHistoryError.unavailable }
            }
            guard ["claude", "codex"].contains(group.provider),
                  validMemberCount(group),
                  Set(group.rootPaths.keys) == Set(group.profileStorageIDs.map(\.uuidString)),
                  group.rootPaths.values.allSatisfy(ClaudeConversationCopyService.validWorkingDirectory),
                  Set(group.baselines.keys) == group.knownConversationIDs,
                  group.baselines.values.allSatisfy({
                      $0.byteCount > 0
                          && $0.digest.count == 64 && $0.digest.allSatisfy { "0123456789abcdef".contains($0) }
                  }) else { throw SharedHistoryError.unavailable }
            for member in group.profileStorageIDs {
                guard members.insert(group.applicationStorageID.uuidString + member.uuidString).inserted else {
                    throw SharedHistoryError.unavailable
                }
            }
            if let validation = group.claudeValidation {
                guard group.provider == "claude", Set(validation.keys) == Set(group.rootPaths.keys) else {
                    throw SharedHistoryError.unavailable
                }
                for records in validation.values {
                    guard Set(records.keys) == group.knownConversationIDs else { throw SharedHistoryError.unavailable }
                    for (id, entry) in records {
                        guard entry.baseline == group.baselines[id],
                              entry.recordPath.count <= 32, entry.transcriptPath.count <= 32,
                              entry.recordPath.last == id + ".json",
                              [entry.recordDigest, entry.transcriptDigest].allSatisfy({
                                  $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) }
                              }) else { throw SharedHistoryError.unavailable }
                        _ = try SecureManagedPath(entry.recordPath)
                        _ = try SecureManagedPath(entry.transcriptPath)
                    }
                }
            }
        }
    }

}
