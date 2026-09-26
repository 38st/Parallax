import Darwin
import Foundation

extension SettingsPublicationResidualInventory {
    func metadata(
        _ descriptor: Int32,
        call: SettingsPublicationResidualInventorySystemCall,
        rawName: Data?,
        operation: String
    ) throws -> SettingsPrimaryFileMetadata {
        if let code = systemCallHook(call, rawName) {
            if rawName == nil {
                throw InventoryFailure.system(operation, code)
            }
            throw EntryFailure.system(operation, code)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            if rawName == nil {
                throw InventoryFailure.system(operation, errno)
            }
            throw EntryFailure.system(operation, errno)
        }
        return metadataHook(
            call,
            rawName,
            SettingsPrimaryDescriptorSecurity.metadata(from: status)
        )
    }

    func pathMetadata(
        _ parent: Int32,
        rawName: Data,
        call: SettingsPublicationResidualInventorySystemCall,
        operation: String
    ) throws -> SettingsPrimaryFileMetadata {
        if let code = systemCallHook(call, rawName) {
            throw EntryFailure.system(operation, code)
        }
        var status = stat()
        let result = withFileSystemName(rawName) {
            fstatat(parent, $0, &status, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            throw EntryFailure.system(operation, errno)
        }
        return metadataHook(
            call,
            rawName,
            SettingsPrimaryDescriptorSecurity.metadata(from: status)
        )
    }

    func validateDirectory(
        _ metadata: SettingsPrimaryFileMetadata
    ) throws {
        guard metadata.kind == .directory,
              metadata.owner == geteuid(),
              metadata.mode == 0o700
        else {
            throw InventoryFailure.directoryChanged
        }
    }

    func unsafeReason(
        _ metadata: SettingsPrimaryFileMetadata
    ) -> SettingsPublicationResidualUnsafeReason? {
        switch metadata.kind {
        case .symbolicLink:
            return .symbolicLink
        case .regularFile:
            break
        default:
            return .unsupportedType
        }
        switch SettingsPrimaryDescriptorSecurity
            .ownershipAndModeViolation(metadata)
        {
        case .wrongOwner:
            return .wrongOwner
        case .permissiveMode, .specialMode:
            return .incorrectMode(actual: metadata.mode)
        case nil:
            break
        }
        guard metadata.mode == 0o600 || metadata.mode == 0o400 else {
            return .incorrectMode(actual: metadata.mode)
        }
        guard metadata.linkCount == 1 else {
            return .multipleHardLinks
        }
        return nil
    }

    func validateACL(
        _ descriptor: Int32,
        rawName: Data
    ) throws {
        let directive = aclHook(rawName, descriptor)
        let result = SettingsPrimaryDescriptorSecurity.extendedACL(
            descriptor: descriptor,
            directive: directive
        )
        switch result {
        case .absent:
            return
        case .present:
            throw EntryFailure.unsafe(.extendedACL)
        case .failure(let code):
            throw EntryFailure.system(
                "inspect residual entry ACL",
                code
            )
        }
    }

    func closeEntry(
        _ descriptor: Int32,
        rawName: Data,
        closeFailures: inout [SettingsPublicationResidualCloseFailure]
    ) {
        let outcome = SettingsDescriptorClose.descriptor(descriptor) {
            systemCallHook(.closeEntry, rawName)
        }
        if case .failure(let code) = outcome {
            closeFailures.append(
                .init(
                    target: .entry(rawName: rawName),
                    failure: .init(
                        operation: "close residual entry",
                        code: code
                    )
                )
            )
        }
    }

    func closeDirectoryStream(
        _ stream: UnsafeMutablePointer<DIR>,
        closeFailures: inout [SettingsPublicationResidualCloseFailure],
        partial: inout [SettingsPublicationResidualInventoryPartialReason]
    ) {
        let outcome = SettingsDescriptorClose.directoryStream(stream) {
            systemCallHook(.closeDirectory, nil)
        }
        let failure: SettingsPublicationResidualCloseFailure?
        if case .failure(let code) = outcome {
            failure = .init(
                target: .directoryStream,
                failure: .init(
                    operation: "close residual inventory directory stream",
                    code: code
                )
            )
        } else {
            failure = nil
        }
        if let failure {
            closeFailures.append(failure)
            append(.closeFailure(failure), to: &partial)
        }
    }

    func closeRawDirectoryDescriptor(
        _ descriptor: Int32,
        closeFailures: inout [SettingsPublicationResidualCloseFailure],
        partial: inout [SettingsPublicationResidualInventoryPartialReason]
    ) {
        let outcome = SettingsDescriptorClose.descriptor(descriptor) {
            systemCallHook(.closeDirectory, nil)
        }
        let failure: SettingsPublicationResidualCloseFailure?
        if case .failure(let code) = outcome {
            failure = .init(
                target: .directoryStream,
                failure: .init(
                    operation:
                        "close unopened residual inventory directory stream",
                    code: code
                )
            )
        } else {
            failure = nil
        }
        if let failure {
            closeFailures.append(failure)
            append(.closeFailure(failure), to: &partial)
        }
    }

    func snapshot(
        scanned: Int,
        retainedBytes: Int,
        entries: [SettingsPublicationResidualEntry],
        partial: [SettingsPublicationResidualInventoryPartialReason],
        closeFailures: [SettingsPublicationResidualCloseFailure]
    ) -> SettingsPublicationResidualInventorySnapshot {
        .init(
            scannedDirectoryEntryCount: scanned,
            retainedByteCount: retainedBytes,
            entries: entries,
            completion: partial.isEmpty ? .complete : .partial(partial),
            closeFailures: closeFailures
        )
    }

    func failedEntry(
        _ rawName: Data,
        validity: SettingsPublicationResidualNameValidity,
        operation: String,
        code: Int32
    ) -> SettingsPublicationResidualEntry {
        .init(
            rawName: rawName,
            nameValidity: validity,
            observation: .unavailable(
                .systemCall(.init(operation: operation, code: code))
            )
        )
    }

    func unexpectedEntry(
        _ rawName: Data,
        validity: SettingsPublicationResidualNameValidity
    ) -> SettingsPublicationResidualEntry {
        failedEntry(
            rawName,
            validity: validity,
            operation: "unexpected residual entry inspection",
            code: EIO
        )
    }

    func append(
        _ reason: SettingsPublicationResidualInventoryPartialReason,
        to reasons: inout [SettingsPublicationResidualInventoryPartialReason]
    ) {
        if !reasons.contains(reason) {
            reasons.append(reason)
        }
    }

    func sameIdentity(
        _ lhs: SettingsPrimaryFileMetadata,
        _ rhs: SettingsPrimaryFileMetadata
    ) -> Bool {
        lhs.identity == rhs.identity
    }

    func directoryEntryName(
        _ entry: UnsafeMutablePointer<dirent>
    ) -> Data {
        let count = Int(entry.pointee.d_namlen)
        return withUnsafeBytes(of: &entry.pointee.d_name) {
            Data($0.prefix(count))
        }
    }

    func rawByteLess(_ lhs: Data, _ rhs: Data) -> Bool {
        lhs.lexicographicallyPrecedes(rhs)
    }

    func withFileSystemName<T>(
        _ rawName: Data,
        _ body: (UnsafePointer<CChar>) -> T
    ) -> T {
        var terminated = [UInt8](rawName)
        terminated.append(0)
        return terminated.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else {
                preconditionFailure("A terminated filesystem name is never empty.")
            }
            return body(base.assumingMemoryBound(to: CChar.self))
        }
    }
}

enum InventoryFailure: Error {
    case directoryChanged
    case system(String, Int32)

    var partialReason:
        SettingsPublicationResidualInventoryPartialReason
    {
        switch self {
        case .directoryChanged:
            return .directoryChangedDuringScan
        case .system(let operation, let code):
            return .directorySystemCall(
                .init(operation: operation, code: code)
            )
        }
    }
}

enum EntryFailure: Error {
    case unsafe(SettingsPublicationResidualUnsafeReason)
    case tooLarge(actual: UInt64, maximum: Int)
    case aggregateLimit
    case changed
    case system(String, Int32)

    var evidence: SettingsPublicationResidualEntryFailure {
        switch self {
        case .unsafe(let reason):
            return .unsafe(reason)
        case .tooLarge(let actual, let maximum):
            return .inputTooLarge(actual: actual, maximum: maximum)
        case .aggregateLimit:
            return .aggregateByteLimit(
                maximum:
                    SettingsPublicationResidualInventory
                        .maximumAggregateBytes
            )
        case .changed:
            return .changedDuringRead
        case .system(let operation, let code):
            return .systemCall(
                .init(operation: operation, code: code)
            )
        }
    }
}
