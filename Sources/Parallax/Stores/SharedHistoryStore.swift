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
        switch try files.read(named: Self.name, maximumBytes: 4 * 1_024 * 1_024) {
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
                      replacement.knownConversationIDs.count <= 2_000,
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
            guard bytes.count <= 4 * 1_024 * 1_024 else { throw SharedHistoryError.unavailable }
            try files.replace(bytes, named: Self.name)
        }
    }

    private func validate(_ groups: [SharedHistoryGroup]) throws {
        guard groups.count <= 128, Set(groups.map(\.id)).count == groups.count else {
            throw SharedHistoryError.unavailable
        }
        var members = Set<String>()
        for group in groups {
            guard ["claude", "codex"].contains(group.provider),
                  (2...8).contains(group.profileStorageIDs.count),
                  group.knownConversationIDs.count <= 2_000,
                  Set(group.rootPaths.keys) == Set(group.profileStorageIDs.map(\.uuidString)),
                  group.rootPaths.values.allSatisfy(ClaudeConversationCopyService.validWorkingDirectory),
                  Set(group.baselines.keys) == group.knownConversationIDs,
                  group.baselines.values.allSatisfy({
                      $0.byteCount > 0 && $0.byteCount <= SharedHistoryService.maximumTotalBytes
                          && $0.digest.count == 64 && $0.digest.allSatisfy { "0123456789abcdef".contains($0) }
                  }) else { throw SharedHistoryError.unavailable }
            for member in group.profileStorageIDs {
                guard members.insert(group.applicationStorageID.uuidString + member.uuidString).inserted else {
                    throw SharedHistoryError.unavailable
                }
            }
        }
    }

}
