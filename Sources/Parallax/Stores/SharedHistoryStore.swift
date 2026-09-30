import Foundation

/// Local opt-in receipts, deliberately excluded from portable library imports.
/// An unreadable document blocks sharing; it is never reset to an empty default.
struct SharedHistoryStore: Sendable {
    private struct Document: Codable {
        var schemaVersion = 1
        var groups: [SharedHistoryGroup]
    }
    private let files: TrustedContainerFileStore
    private static let name = "shared-history.json"

    init(applicationSupportURL: URL) throws {
        files = TrustedContainerFileStore(container: try TrustedParallaxContainer.establish(
            applicationSupportURL: applicationSupportURL))
    }

    func groups() throws -> [SharedHistoryGroup] {
        // Required IDs and baselines grow with history; only the optional cache
        // below has a size budget. Receipt size must not cap conversation count.
        switch try files.read(named: Self.name, maximumBytes: .max) {
        case .missing: return []
        case .bytes(let bytes):
            let document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.schemaVersion == 1 else { throw SharedHistoryError.unavailable }
            try validate(document.groups)
            return document.groups
        }
    }

    func replace(_ expected: SharedHistoryGroup?, with replacement: SharedHistoryGroup?) throws {
        try files.withExclusiveLock(named: ".shared-history.lock") {
            var groups = try self.groups()
            if let expected {
                guard groups.first(where: { $0.id == expected.id }) == expected else { throw SharedHistoryError.changed }
                groups.removeAll { $0.id == expected.id }
            }
            if let replacement {
                guard (2...8).contains(replacement.profileStorageIDs.count),
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
            let bytes = try JSONEncoder().encode(Document(groups: groups))
            try files.replace(bytes, named: Self.name)
        }
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
            guard ["claude", "codex"].contains(group.provider),
                  (2...8).contains(group.profileStorageIDs.count),
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
