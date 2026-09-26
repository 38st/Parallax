import Darwin
import Foundation

extension SettingsPrimaryMutationLock {
    func refreshContainerIdentity(
        _ resources: Resources
    ) throws {
        let metadata = try descriptorMetadata(
            resources.container,
            call: .inspectContainer,
            operation: "refresh trusted settings container"
        )
        try validateDirectory(
            metadata,
            item: .trustedContainer,
            exactMode: 0o700
        )
        try validateACL(
            resources.container,
            item: .trustedContainer,
            operation: "refresh trusted settings container ACL"
        )
        resources.containerIdentity = metadata
    }

    func refreshSettingsIdentity(
        _ resources: Resources
    ) throws {
        let metadata = try descriptorMetadata(
            resources.settings,
            call: .reinspectSettings,
            operation: "refresh Settings directory"
        )
        try validateDirectory(
            metadata,
            item: .settingsDirectory,
            exactMode: 0o700
        )
        try validateACL(
            resources.settings,
            item: .settingsDirectory,
            operation: "refresh Settings directory ACL"
        )
        let path = try requiredPathMetadata(
            parent: resources.container,
            name: Self.settingsName,
            call: .reinspectSettingsPath,
            operation: "refresh Settings directory path"
        )
        guard metadata.hasSameAuthority(as: path),
              !resources.locked || metadata == path
        else {
            throw changed(.settingsDirectory)
        }
        resources.settingsIdentity = metadata
    }

    func revalidateAfterFlock(
        _ resources: Resources
    ) throws {
        let reopened = try openContainer(call: .reopenContainer)
        resources.reopenedContainer = reopened
        try validatePinnedState(resources, reopenedContainer: reopened)
    }

    func validatePinnedState(
        _ resources: Resources,
        reopenedContainer: Int32
    ) throws {
        let reopenedMetadata = try descriptorMetadata(
            reopenedContainer,
            call: .inspectReopenedContainer,
            operation: "reinspect trusted settings container path"
        )
        try validateDirectory(
            reopenedMetadata,
            item: .trustedContainer,
            exactMode: 0o700
        )
        try validateACL(
            reopenedContainer,
            item: .trustedContainer,
            operation: "reinspect trusted settings container path ACL"
        )

        let pinnedContainer = try descriptorMetadata(
            resources.container,
            call: .reinspectPinnedContainer,
            operation: "reinspect pinned trusted settings container"
        )
        try validateACL(
            resources.container,
            item: .trustedContainer,
            operation: "reinspect pinned trusted settings container ACL"
        )
        guard reopenedMetadata.hasSameAuthority(as: resources.containerIdentity),
              pinnedContainer.hasSameAuthority(as: resources.containerIdentity)
        else {
            throw changed(.trustedContainer)
        }

        let settings = try descriptorMetadata(
            resources.settings,
            call: .reinspectPinnedSettings,
            operation: "reinspect pinned Settings directory"
        )
        try validateDirectory(
            settings,
            item: .settingsDirectory,
            exactMode: 0o700
        )
        try validateACL(
            resources.settings,
            item: .settingsDirectory,
            operation: "reinspect pinned Settings directory ACL"
        )
        let settingsPath = try requiredPathMetadata(
            parent: resources.container,
            name: Self.settingsName,
            call: .reinspectSettingsPathAfterLock,
            operation: "reinspect Settings directory path after lock"
        )
        guard settings == resources.settingsIdentity,
              settingsPath == resources.settingsIdentity
        else {
            throw changed(.settingsDirectory)
        }

        let lock = try descriptorMetadata(
            resources.lock,
            call: .reinspectPinnedLock,
            operation: "reinspect pinned settings lock"
        )
        try validateLock(lock)
        try validateACL(
            resources.lock,
            item: .lock,
            operation: "reinspect settings lock ACL"
        )
        let lockPath = try requiredPathMetadata(
            parent: resources.settings,
            name: Self.lockName,
            call: .reinspectLockPathAfterLock,
            operation: "reinspect settings lock path after lock"
        )
        guard lock.hasSameLockFacts(as: resources.lockIdentity),
              lockPath.hasSameLockFacts(as: resources.lockIdentity)
        else {
            throw changed(.lock)
        }
    }

    func pathMetadata(
        parent: Int32,
        name: String,
        call: SettingsPrimaryMutationLockSystemCall
    ) -> PathMetadataResult {
        if let code = systemCallHook(call) {
            return .failure(code)
        }
        var status = stat()
        let result = fstatat(
            parent,
            name,
            &status,
            AT_SYMLINK_NOFOLLOW
        )
        guard result == 0 else {
            return .failure(errno)
        }
        return .metadata(
            SettingsPrimaryDescriptorSecurity.metadata(from: status)
        )
    }

    func validateDirectory(
        _ metadata: SettingsPrimaryFileMetadata,
        item: SettingsPrimaryMutationLockItem,
        exactMode: UInt16
    ) throws {
        if metadata.kind == .symbolicLink {
            throw unsafe(item, .symbolicLink)
        }
        guard metadata.kind == .directory else {
            throw unsafe(item, .unsupportedType)
        }
        try validateAuthority(
            metadata,
            item: item,
            exactMode: exactMode
        )
    }

    func validateLock(
        _ metadata: SettingsPrimaryFileMetadata
    ) throws {
        if metadata.kind == .symbolicLink {
            throw unsafe(.lock, .symbolicLink)
        }
        guard metadata.kind == .regularFile else {
            throw unsafe(.lock, .unsupportedType)
        }
        guard metadata.linkCount == 1 else {
            throw unsafe(.lock, .multipleHardLinks)
        }
        try validateAuthority(
            metadata,
            item: .lock,
            exactMode: 0o600
        )
    }

    private func validateAuthority(
        _ metadata: SettingsPrimaryFileMetadata,
        item: SettingsPrimaryMutationLockItem,
        exactMode: UInt16
    ) throws {
        if let violation = SettingsPrimaryDescriptorSecurity
            .ownershipAndModeViolation(metadata)
        {
            switch violation {
            case .wrongOwner:
                throw unsafe(item, .wrongOwner)
            case .permissiveMode:
                throw unsafe(
                    item,
                    .incorrectMode(
                        expected: exactMode,
                        actual: metadata.mode
                    )
                )
            case .specialMode:
                throw unsafe(
                    item,
                    .incorrectMode(
                        expected: exactMode,
                        actual: metadata.mode
                    )
                )
            }
        }
        guard metadata.mode == exactMode else {
            throw unsafe(
                item,
                .incorrectMode(
                    expected: exactMode,
                    actual: metadata.mode
                )
            )
        }
    }
}
