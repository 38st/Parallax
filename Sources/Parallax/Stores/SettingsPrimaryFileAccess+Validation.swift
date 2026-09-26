import Darwin
import Foundation

extension SettingsPrimaryFileAccess {
    func validatePinnedParent(
        descriptor: Int32,
        expected: SettingsPrimaryFileMetadata,
        call: SettingsPrimarySystemCall,
        operation: String
    ) throws {
        try validateParent(expected)
        let actual = try metadata(
            descriptor: descriptor,
            item: .parent,
            operation: operation,
            call: call
        )
        try validateParent(actual)
        try validateNoExtendedACL(
            descriptor: descriptor,
            item: .parent,
            operation: "\(operation) ACL"
        )
        guard actual == expected else {
            throw SettingsPrimaryFileAccessError.changedDuringRead
        }
    }

    func openParent(
        call: SettingsPrimarySystemCall
    ) -> (descriptor: Int32, errorCode: Int32) {
        if let code = systemCallHook(call) {
            return (-1, code)
        }
        guard let settingsDirectoryURL else {
            return (-1, EBADF)
        }
        let descriptor = open(
            settingsDirectoryURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        return (descriptor, descriptor < 0 ? errno : 0)
    }

    func openPrimary(
        parent: Int32
    ) -> (descriptor: Int32, errorCode: Int32) {
        if let code = systemCallHook(.openPrimary) {
            return (-1, code)
        }
        let descriptor = openat(
            parent,
            Self.primaryName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        return (descriptor, descriptor < 0 ? errno : 0)
    }

    func inspectPrimaryPath(
        parent: Int32,
        status: inout stat,
        call: SettingsPrimarySystemCall
    ) -> (status: Int32, errorCode: Int32) {
        if let code = systemCallHook(call) {
            return (-1, code)
        }
        let result = fstatat(
            parent,
            Self.primaryName,
            &status,
            AT_SYMLINK_NOFOLLOW
        )
        return (result, result < 0 ? errno : 0)
    }

    func validateParentPath(
        descriptor: Int32,
        expected: SettingsPrimaryFileMetadata
    ) throws {
        let reopenResult = openParent(call: .reopenParent)
        let reopened = reopenResult.descriptor
        guard reopened >= 0 else {
            throw SettingsPrimaryFileAccessError.changedDuringRead
        }
        defer { close(reopened) }
        let actual = try metadata(
            descriptor: reopened,
            item: .parent,
            operation: "reinspect settings directory path",
            call: .reinspectReopenedParent
        )
        try validateNoExtendedACL(
            descriptor: reopened,
            item: .parent,
            operation: "reinspect settings directory path ACL"
        )
        let pinned = try metadata(
            descriptor: descriptor,
            item: .parent,
            operation: "reinspect pinned settings directory",
            call: .reinspectPinnedParent
        )
        try validateNoExtendedACL(
            descriptor: descriptor,
            item: .parent,
            operation: "reinspect pinned settings directory ACL"
        )
        guard actual == expected, pinned == expected else {
            throw SettingsPrimaryFileAccessError.changedDuringRead
        }
    }

    func validateParent(
        _ metadata: SettingsPrimaryFileMetadata
    ) throws {
        guard metadata.kind == .directory else {
            throw unsafe(.parent, .unsupportedType)
        }
        try validateOwnershipAndMode(metadata, item: .parent)
    }

    func validatePrimary(
        _ metadata: SettingsPrimaryFileMetadata
    ) throws {
        if metadata.kind == .symbolicLink {
            throw unsafe(.primary, .symbolicLink)
        }
        guard metadata.kind == .regularFile else {
            throw unsafe(.primary, .unsupportedType)
        }
        guard metadata.linkCount == 1 else {
            throw unsafe(.primary, .multipleHardLinks)
        }
        try validateOwnershipAndMode(metadata, item: .primary)
    }

    private func validateOwnershipAndMode(
        _ metadata: SettingsPrimaryFileMetadata,
        item: SettingsPrimaryFileItem
    ) throws {
        if let reason =
            SettingsPrimaryDescriptorSecurity.ownershipAndModeReason(metadata)
        {
            throw unsafe(item, reason)
        }
    }

    func unsafe(
        _ item: SettingsPrimaryFileItem,
        _ reason: SettingsPrimaryFileUnsafeReason
    ) -> SettingsPrimaryFileAccessError {
        .unsafeItem(item: item, reason: reason)
    }
}
