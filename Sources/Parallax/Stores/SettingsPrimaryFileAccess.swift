import Darwin
import Foundation

enum SettingsPrimaryFileItem: Sendable, Equatable {
    case parent
    case primary
}

enum SettingsPrimaryFileUnsafeReason: Sendable, Equatable {
    case symbolicLink
    case wrongOwner
    case permissiveMode
    case specialMode
    case extendedACL
    case unsupportedType
    case multipleHardLinks
}

enum SettingsPrimaryFileAccessError: Error, Sendable, Equatable {
    case unsafeItem(
        item: SettingsPrimaryFileItem,
        reason: SettingsPrimaryFileUnsafeReason
    )
    case invalidMaximumBytes(Int)
    case inputTooLarge(actual: UInt64, maximum: Int)
    case changedDuringRead
    case systemCall(operation: String, code: Int32)
}

enum SettingsPrimaryFileReadResult: Sendable, Equatable {
    case missing
    case bytes(Data)
}

protocol SettingsPrimaryFileAccessing: Sendable {
    func read(
        maximumBytes: Int
    ) -> Result<SettingsPrimaryFileReadResult, SettingsPrimaryFileAccessError>
}

enum SettingsPrimaryFileBoundary: Sendable, Equatable {
    case beforeParentOpen
    case afterParentOpen
    case afterLeafPreflight
    case afterLeafOpen
    case beforeRead(totalBytes: Int)
    case afterRead(totalBytes: Int)
    case beforePostflight
    case beforeFinalPathValidation
}

enum SettingsPrimaryReadDirective: Sendable, Equatable {
    case system
    case failure(code: Int32)
    case limit(Int)
}

enum SettingsPrimarySystemCall: Sendable, Equatable {
    case openParent
    case inspectParent
    case inspectPinnedParentBeforeRead
    case inspectPinnedParentAfterRead
    case inspectPrimaryPath
    case openPrimary
    case inspectPrimary
    case reinspectPrimary
    case reinspectPrimaryPath
    case reopenParent
    case reinspectReopenedParent
    case reinspectPinnedParent
}

extension SettingsPrimaryDescriptorSecurity {
    static func ownershipAndModeReason(
        _ metadata: SettingsPrimaryFileMetadata
    ) -> SettingsPrimaryFileUnsafeReason? {
        switch ownershipAndModeViolation(metadata) {
        case .wrongOwner:
            return .wrongOwner
        case .permissiveMode:
            return .permissiveMode
        case .specialMode:
            return .specialMode
        case nil:
            return nil
        }
    }
}

struct SettingsPrimaryFileAccess: SettingsPrimaryFileAccessing,
    @unchecked Sendable
{
    typealias BoundaryHook = @Sendable (SettingsPrimaryFileBoundary) -> Void
    typealias ReadHook = @Sendable (
        Int32,
        Int
    ) -> SettingsPrimaryReadDirective
    typealias MetadataHook = @Sendable (
        SettingsPrimaryFileItem,
        SettingsPrimaryFileMetadata
    ) -> SettingsPrimaryFileMetadata
    typealias ACLHook = @Sendable (
        SettingsPrimaryFileItem,
        Int32
    ) -> SettingsPrimaryACLDirective
    typealias SystemCallHook = @Sendable (
        SettingsPrimarySystemCall
    ) -> Int32?

    static let primaryName = SettingsPrimaryLocation.fileName

    static let maximumLockedInspectionBytes = 4 * 1_024 * 1_024
    static let defaultMaximumConsecutiveInterruptedReads = 64

    private let settingsDirectoryURL: URL?
    private let readChunkBytes: Int
    private let maximumConsecutiveInterruptedReads: Int
    private let boundaryHook: BoundaryHook
    private let readHook: ReadHook
    private let metadataHook: MetadataHook
    private let aclHook: ACLHook
    private let systemCallHook: SystemCallHook

    init(
        settingsDirectoryURL: URL,
        readChunkBytes: Int = 64 * 1_024,
        maximumConsecutiveInterruptedReads: Int =
            Self.defaultMaximumConsecutiveInterruptedReads,
        boundaryHook: @escaping BoundaryHook = { _ in },
        readHook: @escaping ReadHook = { _, _ in .system },
        metadataHook: @escaping MetadataHook = { _, metadata in metadata },
        aclHook: @escaping ACLHook = { _, _ in .system },
        systemCallHook: @escaping SystemCallHook = { _ in nil }
    ) {
        precondition(readChunkBytes > 0)
        precondition(maximumConsecutiveInterruptedReads >= 0)
        precondition(settingsDirectoryURL.isFileURL)
        precondition(settingsDirectoryURL.path.hasPrefix("/"))
        self.settingsDirectoryURL = settingsDirectoryURL
        self.readChunkBytes = readChunkBytes
        self.maximumConsecutiveInterruptedReads =
            maximumConsecutiveInterruptedReads
        self.boundaryHook = boundaryHook
        self.readHook = readHook
        self.metadataHook = metadataHook
        self.aclHook = aclHook
        self.systemCallHook = systemCallHook
    }

    init(
        pinnedReadChunkBytes: Int = 64 * 1_024,
        maximumConsecutiveInterruptedReads: Int =
            Self.defaultMaximumConsecutiveInterruptedReads,
        boundaryHook: @escaping BoundaryHook = { _ in },
        readHook: @escaping ReadHook = { _, _ in .system },
        metadataHook: @escaping MetadataHook = { _, metadata in metadata },
        aclHook: @escaping ACLHook = { _, _ in .system },
        systemCallHook: @escaping SystemCallHook = { _ in nil }
    ) {
        precondition(pinnedReadChunkBytes > 0)
        precondition(maximumConsecutiveInterruptedReads >= 0)
        settingsDirectoryURL = nil
        readChunkBytes = pinnedReadChunkBytes
        self.maximumConsecutiveInterruptedReads =
            maximumConsecutiveInterruptedReads
        self.boundaryHook = boundaryHook
        self.readHook = readHook
        self.metadataHook = metadataHook
        self.aclHook = aclHook
        self.systemCallHook = systemCallHook
    }

    func read(
        maximumBytes: Int
    ) -> Result<SettingsPrimaryFileReadResult, SettingsPrimaryFileAccessError> {
        guard maximumBytes >= 0 else {
            return .failure(.invalidMaximumBytes(maximumBytes))
        }
        do {
            return .success(try readThrowing(maximumBytes: maximumBytes))
        } catch let error as SettingsPrimaryFileAccessError {
            return .failure(error)
        } catch {
            return .failure(
                .systemCall(operation: "unexpected settings read", code: EIO)
            )
        }
    }

    private func readThrowing(
        maximumBytes: Int
    ) throws -> SettingsPrimaryFileReadResult {
        boundaryHook(.beforeParentOpen)
        let parentResult = openParent(call: .openParent)
        let parent = parentResult.descriptor
        guard parent >= 0 else {
            if parentResult.errorCode == ENOENT {
                return .missing
            }
            if parentResult.errorCode == ELOOP {
                throw unsafe(.parent, .symbolicLink)
            }
            if parentResult.errorCode == ENOTDIR {
                throw unsafe(.parent, .unsupportedType)
            }
            throw system(
                "open settings directory",
                parentResult.errorCode
            )
        }
        defer { close(parent) }

        let parentBefore = try metadata(
            descriptor: parent,
            item: .parent,
            operation: "inspect settings directory",
            call: .inspectParent
        )
        try validateParent(parentBefore)
        try validateNoExtendedACL(
            descriptor: parent,
            item: .parent,
            operation: "inspect settings directory ACL"
        )
        boundaryHook(.afterParentOpen)

        return try readPinnedThrowing(
            parent: parent,
            parentBefore: parentBefore,
            maximumBytes: maximumBytes
        ) {
            try validateParentPath(
                descriptor: parent,
                expected: parentBefore
            )
        }
    }

    func readPinnedThrowing(
        parent: Int32,
        parentBefore: SettingsPrimaryFileMetadata,
        maximumBytes: Int,
        parentPostflight: () throws -> Void
    ) throws -> SettingsPrimaryFileReadResult {
        guard maximumBytes >= 0 else {
            throw SettingsPrimaryFileAccessError
                .invalidMaximumBytes(maximumBytes)
        }
        try validatePinnedParent(
            descriptor: parent,
            expected: parentBefore,
            call: .inspectPinnedParentBeforeRead,
            operation: "inspect pinned settings directory before read"
        )

        var leafStatus = stat()
        let leafPreflight = inspectPrimaryPath(
            parent: parent,
            status: &leafStatus,
            call: .inspectPrimaryPath
        )
        guard leafPreflight.status == 0 else {
            if leafPreflight.errorCode == ENOENT {
                try validatePinnedParent(
                    descriptor: parent,
                    expected: parentBefore,
                    call: .inspectPinnedParentAfterRead,
                    operation: "reinspect pinned settings directory after read"
                )
                try parentPostflight()
                return .missing
            }
            throw system(
                "inspect settings primary",
                leafPreflight.errorCode
            )
        }
        let leafBefore = metadataHook(
            .primary,
            SettingsPrimaryDescriptorSecurity.metadata(from: leafStatus)
        )
        try validatePrimary(leafBefore)
        boundaryHook(.afterLeafPreflight)

        let leafResult = openPrimary(parent: parent)
        let leaf = leafResult.descriptor
        guard leaf >= 0 else {
            if leafResult.errorCode == ELOOP {
                throw unsafe(.primary, .symbolicLink)
            }
            if leafResult.errorCode == ENOENT {
                throw SettingsPrimaryFileAccessError.changedDuringRead
            }
            throw system("open settings primary", leafResult.errorCode)
        }
        defer { close(leaf) }

        let descriptorBefore = try metadata(
            descriptor: leaf,
            item: .primary,
            operation: "inspect opened settings primary",
            call: .inspectPrimary
        )
        try validatePrimary(descriptorBefore)
        try validateNoExtendedACL(
            descriptor: leaf,
            item: .primary,
            operation: "inspect settings primary ACL"
        )
        guard descriptorBefore == leafBefore else {
            throw SettingsPrimaryFileAccessError.changedDuringRead
        }
        boundaryHook(.afterLeafOpen)

        guard descriptorBefore.size >= 0 else {
            throw unsafe(.primary, .unsupportedType)
        }
        let announcedSize = UInt64(descriptorBefore.size)
        guard announcedSize <= UInt64(maximumBytes) else {
            throw SettingsPrimaryFileAccessError.inputTooLarge(
                actual: announcedSize,
                maximum: maximumBytes
            )
        }

        var data = Data()
        data.reserveCapacity(Int(announcedSize))
        var buffer = [UInt8](
            repeating: 0,
            count: min(readChunkBytes, max(1, maximumBytes))
        )
        var consecutiveInterruptedReads = 0
        while true {
            boundaryHook(.beforeRead(totalBytes: data.count))
            let remaining = maximumBytes - data.count
            let allowed =
                remaining == 0
                ? 1
                : min(buffer.count, remaining)
            let directive = readHook(leaf, allowed)
            let count: Int
            let readError: Int32
            if case .limit(let limit) = directive {
                let requested = min(allowed, max(1, limit))
                count = Darwin.read(leaf, &buffer, requested)
                readError = count < 0 ? errno : 0
            } else if case .failure(let code) = directive {
                count = -1
                readError = code
            } else {
                count = Darwin.read(leaf, &buffer, allowed)
                readError = count < 0 ? errno : 0
            }
            if count < 0 {
                if readError == EINTR {
                    let (next, overflow) =
                        consecutiveInterruptedReads
                            .addingReportingOverflow(1)
                    guard !overflow,
                          next <= maximumConsecutiveInterruptedReads
                    else {
                        throw system("read settings primary", EINTR)
                    }
                    consecutiveInterruptedReads = next
                    continue
                }
                throw system("read settings primary", readError)
            }
            consecutiveInterruptedReads = 0
            if count == 0 {
                break
            }
            data.append(buffer, count: count)
            boundaryHook(.afterRead(totalBytes: data.count))
            guard data.count <= maximumBytes else {
                throw SettingsPrimaryFileAccessError.inputTooLarge(
                    actual: UInt64(data.count),
                    maximum: maximumBytes
                )
            }
        }

        boundaryHook(.beforePostflight)
        let descriptorAfter = try metadata(
            descriptor: leaf,
            item: .primary,
            operation: "reinspect settings primary",
            call: .reinspectPrimary
        )
        try validateNoExtendedACL(
            descriptor: leaf,
            item: .primary,
            operation: "reinspect settings primary ACL"
        )
        guard descriptorAfter == descriptorBefore,
              Int64(data.count) == descriptorBefore.size
        else {
            throw SettingsPrimaryFileAccessError.changedDuringRead
        }

        boundaryHook(.beforeFinalPathValidation)
        var finalLeafStatus = stat()
        let finalLeafInspection = inspectPrimaryPath(
            parent: parent,
            status: &finalLeafStatus,
            call: .reinspectPrimaryPath
        )
        guard finalLeafInspection.status == 0 else {
            if finalLeafInspection.errorCode == ENOENT {
                throw SettingsPrimaryFileAccessError.changedDuringRead
            }
            throw system(
                "reinspect settings primary path",
                finalLeafInspection.errorCode
            )
        }
        let finalLeaf = metadataHook(
            .primary,
            SettingsPrimaryDescriptorSecurity.metadata(from: finalLeafStatus)
        )
        guard finalLeaf == descriptorAfter else {
            throw SettingsPrimaryFileAccessError.changedDuringRead
        }
        try validatePinnedParent(
            descriptor: parent,
            expected: parentBefore,
            call: .inspectPinnedParentAfterRead,
            operation: "reinspect pinned settings directory after read"
        )
        try parentPostflight()
        return .bytes(data)
    }

    private func validatePinnedParent(
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

    private func openParent(
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

    private func openPrimary(
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

    private func inspectPrimaryPath(
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

    private func validateParentPath(
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

    private func validateNoExtendedACL(
        descriptor: Int32,
        item: SettingsPrimaryFileItem,
        operation: String
    ) throws {
        let directive = aclHook(item, descriptor)
        let result = SettingsPrimaryDescriptorSecurity.extendedACL(
            descriptor: descriptor,
            directive: directive
        )
        switch result {
        case .absent:
            return
        case .present:
            throw unsafe(item, .extendedACL)
        case .failure(let code):
            throw system(operation, code)
        }
    }

    private func metadata(
        descriptor: Int32,
        item: SettingsPrimaryFileItem,
        operation: String,
        call: SettingsPrimarySystemCall
    ) throws -> SettingsPrimaryFileMetadata {
        if let code = systemCallHook(call) {
            throw system(operation, code)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw system(operation, errno)
        }
        return metadataHook(
            item,
            SettingsPrimaryDescriptorSecurity.metadata(from: status)
        )
    }

    private func validateParent(
        _ metadata: SettingsPrimaryFileMetadata
    ) throws {
        guard metadata.kind == .directory else {
            throw unsafe(.parent, .unsupportedType)
        }
        try validateOwnershipAndMode(metadata, item: .parent)
    }

    private func validatePrimary(
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

    private func unsafe(
        _ item: SettingsPrimaryFileItem,
        _ reason: SettingsPrimaryFileUnsafeReason
    ) -> SettingsPrimaryFileAccessError {
        .unsafeItem(item: item, reason: reason)
    }

    private func system(
        _ operation: String,
        _ code: Int32
    ) -> SettingsPrimaryFileAccessError {
        .systemCall(operation: operation, code: code)
    }
}
