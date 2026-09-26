import Darwin
import Foundation

extension SettingsPublicationResidualInventory {
    /// Reserved, owner-only regular files in the pinned Settings directory
    /// have publication's shape. Preserve every byte without interpreting an
    /// incomplete file as settings; future-format leftovers remain ambiguous.
    func preserveRecoverableEntries(
        _ inventory: SettingsPublicationResidualInventorySnapshot,
        settingsDescriptor: Int32
    ) throws -> Bool {
        guard inventory.closeFailures.isEmpty else { return false }
        if case .partial(let reasons) = inventory.completion {
            guard reasons.allSatisfy({ reason in
                switch reason {
                case .reservedEntryLimit, .directoryEntryLimit:
                    return true
                case .entryIncomplete(let name):
                    return inventory.entries.contains {
                        $0.rawName == name && $0.observation == .unavailable(
                            .aggregateByteLimit(maximum: Self.maximumAggregateBytes)
                        )
                    }
                default:
                    return false
                }
            }) else { return false }
        }
        let recoverable = inventory.entries.filter { entry in
            guard entry.nameValidity == .canonical,
                  case .retained(_, _, let content) = entry.observation
            else { return false }
            switch content {
            case .current, .corrupt: return true
            case .future: return false
            }
        }
        guard !recoverable.isEmpty else { return false }

        let archiveName = ".settings.preserved"
        if mkdirat(settingsDescriptor, archiveName, 0o700) != 0, errno != EEXIST {
            throw preservationFailure("create preserved settings directory", errno)
        }
        let archive = openat(settingsDescriptor, archiveName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard archive >= 0 else { throw preservationFailure("open preserved settings directory", errno) }
        defer { close(archive) }
        let publication = SettingsPrimaryPublication()
        let archiveFacts = try publication.metadata(archive, call: .inspectTemporary, operation: "inspect preserved directory")
        guard archiveFacts.kind == .directory, archiveFacts.owner == geteuid(), archiveFacts.mode == 0o700 else {
            throw preservationFailure("unsafe preserved settings directory", EPERM)
        }
        try publication.validateACL(archive)
        let archivePath = try publication.pathMetadata(settingsDescriptor, archiveName, call: .inspectTemporaryPath, operation: "inspect preserved directory path")
        guard archivePath == archiveFacts else {
            throw preservationFailure("preserved settings directory changed", EIO)
        }
        for entry in recoverable {
            let name = String(decoding: entry.rawName, as: UTF8.self)
            guard case .retained(let bytes, let sha, _) = entry.observation else { continue }
            let descriptor = openat(settingsDescriptor, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
            guard descriptor >= 0 else { throw preservationFailure("open settings residual for preservation", errno) }
            defer { close(descriptor) }
            let before = try publication.metadata(descriptor, call: .inspectTemporary, operation: "inspect preserved residual")
            let path = try publication.pathMetadata(settingsDescriptor, name, call: .inspectTemporaryPath, operation: "inspect residual path")
            guard before == path, unsafeReason(before) == nil else {
                throw preservationFailure("settings residual changed before preservation", EIO)
            }
            try publication.validateACL(descriptor)
            let token = SettingsVersionToken(revision: .zero, sourceSHA256: sha)
            guard try publication.exactDescriptorBytes(descriptor, expected: bytes, token: token) else {
                throw preservationFailure("settings residual bytes changed", EIO)
            }
            let destination = name + "-" + UUID().uuidString.lowercased()
            guard renameatx_np(settingsDescriptor, name, archive, destination, UInt32(RENAME_EXCL)) == 0 else {
                throw preservationFailure("preserve settings residual", errno)
            }
            let archived = try publication.pathMetadata(archive, destination, call: .inspectTemporaryPath, operation: "verify preserved residual")
            try publication.validateACL(descriptor)
            guard archived.hasSameAuthority(as: before), archived.linkCount == 1,
                  try publication.exactDescriptorBytes(descriptor, expected: bytes, token: token) else {
                throw preservationFailure("settings residual changed during preservation", EIO)
            }
        }
        let finalArchive = try publication.pathMetadata(settingsDescriptor, archiveName, call: .inspectTemporaryPath, operation: "verify preserved directory path")
        guard finalArchive.hasSameAuthority(as: archiveFacts) else {
            throw preservationFailure("preserved settings directory changed", EIO)
        }
        try publication.validateACL(archive)
        try publication.fullSync(archive, call: .syncSettings, operation: "synchronize preserved settings")
        try publication.fullSync(settingsDescriptor, call: .syncSettings, operation: "synchronize settings preservation")
        return true
    }

    private func preservationFailure(_ operation: String, _ code: Int32) -> SettingsPrimaryLockedInspectionError {
        .fileAccess(.systemCall(operation: operation, code: code))
    }
}
