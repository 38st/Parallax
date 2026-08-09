import Darwin
import Foundation

enum SettingsPublicationResidualNaming {
    static let prefix = ".settings.publish-"
    static let prefixBytes = Data(prefix.utf8)

    static func generatedName(_ value: UInt64) -> String {
        prefix + String(value, radix: 16)
    }

    static func isReserved(_ rawName: Data) -> Bool {
        rawName.starts(with: prefixBytes)
    }

    static func isCanonical(_ rawName: Data) -> Bool {
        guard isReserved(rawName) else {
            return false
        }
        let suffix = rawName.dropFirst(prefixBytes.count)
        guard 1 ... 16 ~= suffix.count else {
            return false
        }
        return suffix.allSatisfy {
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains($0)
                || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains($0)
        }
    }
}
enum SettingsPublicationResidualNameValidity: Equatable, Sendable {
    case canonical
    case malformedReservedName
}

enum SettingsPublicationResidualRetainedContent: Equatable, Sendable {
    case current(token: SettingsVersionToken)
    case future(schemaVersion: UInt64)
    case corrupt(SettingsDocumentCodecFailure)
}

enum SettingsPublicationResidualUnsafeReason: Equatable, Sendable {
    case symbolicLink
    case wrongOwner
    case incorrectMode(actual: UInt16)
    case extendedACL
    case unsupportedType
    case multipleHardLinks
}

enum SettingsPublicationResidualEntryFailure: Equatable, Sendable {
    case unsafe(SettingsPublicationResidualUnsafeReason)
    case inputTooLarge(actual: UInt64, maximum: Int)
    case aggregateByteLimit(maximum: Int)
    case changedDuringRead
    case systemCall(SettingsPrimaryMutationLockSystemFailure)
}

enum SettingsPublicationResidualEntryObservation: Equatable, Sendable {
    case retained(
        bytes: Data,
        sourceSHA256: SettingsSourceSHA256,
        content: SettingsPublicationResidualRetainedContent
    )
    case unavailable(SettingsPublicationResidualEntryFailure)
}

enum SettingsPublicationResidualCloseTarget: Equatable, Sendable {
    case directoryStream
    case entry(rawName: Data)
}

struct SettingsPublicationResidualCloseFailure: Equatable, Sendable {
    let target: SettingsPublicationResidualCloseTarget
    let failure: SettingsPrimaryMutationLockSystemFailure
}

struct SettingsPublicationResidualEntry: Equatable, Sendable {
    let rawName: Data
    let nameValidity: SettingsPublicationResidualNameValidity
    let observation: SettingsPublicationResidualEntryObservation
}

enum SettingsPublicationResidualInventoryPartialReason:
    Equatable,
    Sendable
{
    case directoryEntryLimit(maximum: Int)
    case reservedEntryLimit(actual: Int, maximum: Int)
    case directoryChangedDuringScan
    case directorySystemCall(SettingsPrimaryMutationLockSystemFailure)
    case entryIncomplete(rawName: Data)
    case closeFailure(SettingsPublicationResidualCloseFailure)
    case authorityPostflight(SettingsPrimaryLockedInspectionError)
}

enum SettingsPublicationResidualInventoryCompletion: Equatable, Sendable {
    case complete
    case partial([SettingsPublicationResidualInventoryPartialReason])
}

struct SettingsPublicationResidualInventorySnapshot: Equatable, Sendable {
    let scannedDirectoryEntryCount: Int
    let retainedByteCount: Int
    let entries: [SettingsPublicationResidualEntry]
    let completion: SettingsPublicationResidualInventoryCompletion
    let closeFailures: [SettingsPublicationResidualCloseFailure]

    func appendingPartial(
        _ reason: SettingsPublicationResidualInventoryPartialReason
    ) -> Self {
        var reasons: [SettingsPublicationResidualInventoryPartialReason]
        switch completion {
        case .complete:
            reasons = []
        case .partial(let existing):
            reasons = existing
        }
        if !reasons.contains(reason) {
            reasons.append(reason)
        }
        return .init(
            scannedDirectoryEntryCount: scannedDirectoryEntryCount,
            retainedByteCount: retainedByteCount,
            entries: entries,
            completion: .partial(reasons),
            closeFailures: closeFailures
        )
    }
}

enum SettingsPublicationResidualInventorySystemCall: Equatable, Sendable {
    case inspectPinnedDirectoryBefore
    case openDirectoryStream
    case inspectDirectoryStreamBefore
    case createDirectoryStream
    case readDirectory
    case inspectDirectoryStreamAfter
    case inspectPinnedDirectoryAfter
    case inspectPinnedDirectoryFinal
    case inspectEntryPathBefore
    case openEntry
    case inspectEntryBefore
    case inspectEntryPathAfter
    case inspectEntryAfter
    case closeEntry
    case closeDirectory
}

enum SettingsPublicationResidualInventoryBoundary: Equatable, Sendable {
    case afterDirectoryStreamOpen(descriptor: Int32)
    case afterDirectoryEnumeration
    case beforeEntryOpen(rawName: Data)
    case afterEntryOpen(rawName: Data, descriptor: Int32)
    case beforeEntryRead(rawName: Data, totalBytes: Int)
    case beforeEntryPostflight(rawName: Data)
}

enum SettingsPublicationResidualInventoryReadDirective:
    Equatable,
    Sendable
{
    case system
    case failure(Int32)
    case limit(Int)
    case zero
}

struct SettingsPublicationResidualInventory: @unchecked Sendable {
    typealias SystemCallHook = @Sendable (
        SettingsPublicationResidualInventorySystemCall,
        Data?
    ) -> Int32?
    typealias BoundaryHook = @Sendable (
        SettingsPublicationResidualInventoryBoundary
    ) -> Void
    typealias ReadHook = @Sendable (
        Data,
        Int,
        Int
    ) -> SettingsPublicationResidualInventoryReadDirective
    typealias MetadataHook = @Sendable (
        SettingsPublicationResidualInventorySystemCall,
        Data?,
        SettingsPrimaryFileMetadata
    ) -> SettingsPrimaryFileMetadata
    typealias ACLHook = @Sendable (
        Data,
        Int32
    ) -> SettingsPrimaryACLDirective
    typealias DirectoryEntryHook = @Sendable (Data) -> Data

    static let maximumDirectoryEntries = 4_096
    static let maximumReservedEntries = 64
    static let maximumEntryBytes = 4 * 1_024 * 1_024
    static let maximumAggregateBytes = 16 * 1_024 * 1_024
    static let maximumConsecutiveInterrupts = 64

    private let systemCallHook: SystemCallHook
    private let boundaryHook: BoundaryHook
    private let readHook: ReadHook
    private let trailingReadHook: ReadHook
    private let metadataHook: MetadataHook
    private let aclHook: ACLHook
    private let directoryEntryHook: DirectoryEntryHook

    init(
        systemCallHook: @escaping SystemCallHook = { _, _ in nil },
        boundaryHook: @escaping BoundaryHook = { _ in },
        readHook: @escaping ReadHook = { _, _, _ in .system },
        trailingReadHook: @escaping ReadHook = { _, _, _ in .system },
        metadataHook: @escaping MetadataHook = {
            _, _, metadata in metadata
        },
        aclHook: @escaping ACLHook = { _, _ in .system },
        directoryEntryHook: @escaping DirectoryEntryHook = { $0 }
    ) {
        self.systemCallHook = systemCallHook
        self.boundaryHook = boundaryHook
        self.readHook = readHook
        self.trailingReadHook = trailingReadHook
        self.metadataHook = metadataHook
        self.aclHook = aclHook
        self.directoryEntryHook = directoryEntryHook
    }

    func inspect(
        settingsDescriptor: Int32
    ) -> SettingsPublicationResidualInventorySnapshot {
        var partial: [SettingsPublicationResidualInventoryPartialReason] = []
        var closeFailures: [SettingsPublicationResidualCloseFailure] = []
        var directoryEntryCount = 0
        var rawNames: [Data] = []

        let pinnedBefore: SettingsPrimaryFileMetadata
        do {
            pinnedBefore = try metadata(
                settingsDescriptor,
                call: .inspectPinnedDirectoryBefore,
                rawName: nil,
                operation: "inspect pinned Settings before residual inventory"
            )
            try validateDirectory(pinnedBefore)
        } catch let failure as InventoryFailure {
            append(failure.partialReason, to: &partial)
            return snapshot(
                scanned: 0,
                retainedBytes: 0,
                entries: [],
                partial: partial,
                closeFailures: closeFailures
            )
        } catch {
            append(
                .directorySystemCall(
                    .init(
                        operation:
                            "unexpected residual inventory directory validation",
                        code: EIO
                    )
                ),
                to: &partial
            )
            return snapshot(
                scanned: 0,
                retainedBytes: 0,
                entries: [],
                partial: partial,
                closeFailures: closeFailures
            )
        }

        let streamDescriptor: Int32
        if let code = systemCallHook(.openDirectoryStream, nil) {
            append(
                .directorySystemCall(
                    .init(
                        operation:
                            "open residual inventory directory stream",
                        code: code
                    )
                ),
                to: &partial
            )
            return snapshot(
                scanned: 0,
                retainedBytes: 0,
                entries: [],
                partial: partial,
                closeFailures: closeFailures
            )
        } else {
            streamDescriptor = openat(
                settingsDescriptor,
                ".",
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
        }
        guard streamDescriptor >= 0 else {
            append(
                .directorySystemCall(
                    .init(
                        operation:
                            "open residual inventory directory stream",
                        code: errno
                    )
                ),
                to: &partial
            )
            return snapshot(
                scanned: 0,
                retainedBytes: 0,
                entries: [],
                partial: partial,
                closeFailures: closeFailures
            )
        }
        boundaryHook(
            .afterDirectoryStreamOpen(descriptor: streamDescriptor)
        )

        let streamBefore: SettingsPrimaryFileMetadata
        do {
            streamBefore = try metadata(
                streamDescriptor,
                call: .inspectDirectoryStreamBefore,
                rawName: nil,
                operation: "inspect residual inventory directory stream"
            )
            try validateDirectory(streamBefore)
            guard sameIdentity(streamBefore, pinnedBefore) else {
                throw InventoryFailure.directoryChanged
            }
        } catch let failure as InventoryFailure {
            append(failure.partialReason, to: &partial)
            closeRawDirectoryDescriptor(
                streamDescriptor,
                closeFailures: &closeFailures,
                partial: &partial
            )
            return snapshot(
                scanned: 0,
                retainedBytes: 0,
                entries: [],
                partial: partial,
                closeFailures: closeFailures
            )
        } catch {
            append(.directoryChangedDuringScan, to: &partial)
            closeRawDirectoryDescriptor(
                streamDescriptor,
                closeFailures: &closeFailures,
                partial: &partial
            )
            return snapshot(
                scanned: 0,
                retainedBytes: 0,
                entries: [],
                partial: partial,
                closeFailures: closeFailures
            )
        }

        if let code = systemCallHook(.createDirectoryStream, nil) {
            append(
                .directorySystemCall(
                    .init(
                        operation:
                            "create residual inventory directory stream",
                        code: code
                    )
                ),
                to: &partial
            )
            closeRawDirectoryDescriptor(
                streamDescriptor,
                closeFailures: &closeFailures,
                partial: &partial
            )
            return snapshot(
                scanned: 0,
                retainedBytes: 0,
                entries: [],
                partial: partial,
                closeFailures: closeFailures
            )
        }
        guard let stream = fdopendir(streamDescriptor) else {
            let code = errno
            append(
                .directorySystemCall(
                    .init(
                        operation:
                            "create residual inventory directory stream",
                        code: code
                    )
                ),
                to: &partial
            )
            closeRawDirectoryDescriptor(
                streamDescriptor,
                closeFailures: &closeFailures,
                partial: &partial
            )
            return snapshot(
                scanned: 0,
                retainedBytes: 0,
                entries: [],
                partial: partial,
                closeFailures: closeFailures
            )
        }

        var exceededDirectoryLimit = false
        while true {
            if let code = systemCallHook(.readDirectory, nil) {
                append(
                    .directorySystemCall(
                        .init(
                            operation: "read residual inventory directory",
                            code: code
                        )
                    ),
                    to: &partial
                )
                break
            }
            errno = 0
            guard let entry = readdir(stream) else {
                let code = errno
                if code != 0 {
                    append(
                        .directorySystemCall(
                            .init(
                                operation:
                                    "read residual inventory directory",
                                code: code
                            )
                        ),
                        to: &partial
                    )
                }
                break
            }
            let rawName = directoryEntryHook(directoryEntryName(entry))
            if rawName == Data(".".utf8)
                || rawName == Data("..".utf8)
            {
                continue
            }
            guard directoryEntryCount < Self.maximumDirectoryEntries else {
                exceededDirectoryLimit = true
                append(
                    .directoryEntryLimit(
                        maximum: Self.maximumDirectoryEntries
                    ),
                    to: &partial
                )
                break
            }
            directoryEntryCount += 1
            if SettingsPublicationResidualNaming.isReserved(rawName) {
                rawNames.append(rawName)
            }
        }

        boundaryHook(.afterDirectoryEnumeration)

        do {
            let streamAfter = try metadata(
                dirfd(stream),
                call: .inspectDirectoryStreamAfter,
                rawName: nil,
                operation:
                    "reinspect residual inventory directory stream"
            )
            let pinnedAfter = try metadata(
                settingsDescriptor,
                call: .inspectPinnedDirectoryAfter,
                rawName: nil,
                operation:
                    "reinspect pinned Settings after residual inventory"
            )
            try validateDirectory(streamAfter)
            try validateDirectory(pinnedAfter)
            guard streamAfter == streamBefore,
                  pinnedAfter == pinnedBefore,
                  sameIdentity(streamAfter, pinnedAfter)
            else {
                throw InventoryFailure.directoryChanged
            }
        } catch let failure as InventoryFailure {
            append(failure.partialReason, to: &partial)
        } catch {
            append(.directoryChangedDuringScan, to: &partial)
        }

        closeDirectoryStream(
            stream,
            closeFailures: &closeFailures,
            partial: &partial
        )

        guard !exceededDirectoryLimit else {
            validatePinnedDirectoryFinal(
                settingsDescriptor,
                pinnedBefore: pinnedBefore,
                partial: &partial
            )
            return snapshot(
                scanned: directoryEntryCount,
                retainedBytes: 0,
                entries: [],
                partial: partial,
                closeFailures: closeFailures
            )
        }

        rawNames.sort(by: rawByteLess)
        if rawNames.count > Self.maximumReservedEntries {
            append(
                .reservedEntryLimit(
                    actual: rawNames.count,
                    maximum: Self.maximumReservedEntries
                ),
                to: &partial
            )
        }

        var retainedBytes = 0
        var entries: [SettingsPublicationResidualEntry] = []
        for rawName in rawNames.prefix(Self.maximumReservedEntries) {
            let entry = inspectEntry(
                rawName,
                settingsDescriptor: settingsDescriptor,
                retainedBytes: &retainedBytes,
                closeFailures: &closeFailures
            )
            entries.append(entry)
            if case .unavailable = entry.observation {
                append(.entryIncomplete(rawName: rawName), to: &partial)
            }
        }

        validatePinnedDirectoryFinal(
            settingsDescriptor,
            pinnedBefore: pinnedBefore,
            partial: &partial
        )

        for failure in closeFailures {
            append(.closeFailure(failure), to: &partial)
        }
        return snapshot(
            scanned: directoryEntryCount,
            retainedBytes: retainedBytes,
            entries: entries,
            partial: partial,
            closeFailures: closeFailures
        )
    }

    private func inspectEntry(
        _ rawName: Data,
        settingsDescriptor: Int32,
        retainedBytes: inout Int,
        closeFailures: inout [SettingsPublicationResidualCloseFailure]
    ) -> SettingsPublicationResidualEntry {
        let validity: SettingsPublicationResidualNameValidity =
            SettingsPublicationResidualNaming.isCanonical(rawName)
            ? .canonical
            : .malformedReservedName

        boundaryHook(.beforeEntryOpen(rawName: rawName))
        let pathBefore: SettingsPrimaryFileMetadata
        do {
            pathBefore = try pathMetadata(
                settingsDescriptor,
                rawName: rawName,
                call: .inspectEntryPathBefore,
                operation: "inspect residual entry path"
            )
            if let reason = unsafeReason(pathBefore) {
                return .init(
                    rawName: rawName,
                    nameValidity: validity,
                    observation: .unavailable(.unsafe(reason))
                )
            }
        } catch let failure as EntryFailure {
            return .init(
                rawName: rawName,
                nameValidity: validity,
                observation: .unavailable(failure.evidence)
            )
        } catch {
            return unexpectedEntry(rawName, validity: validity)
        }

        let descriptor: Int32
        if let code = systemCallHook(.openEntry, rawName) {
            return failedEntry(
                rawName,
                validity: validity,
                operation: "open residual entry",
                code: code
            )
        } else {
            descriptor = withFileSystemName(rawName) {
                openat(
                    settingsDescriptor,
                    $0,
                    O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC
                )
            }
        }
        guard descriptor >= 0 else {
            let code = errno
            let reason: SettingsPublicationResidualUnsafeReason?
            switch code {
            case ELOOP:
                reason = .symbolicLink
            default:
                reason = nil
            }
            if let reason {
                return .init(
                    rawName: rawName,
                    nameValidity: validity,
                    observation: .unavailable(.unsafe(reason))
                )
            }
            return failedEntry(
                rawName,
                validity: validity,
                operation: "open residual entry",
                code: code
            )
        }
        boundaryHook(
            .afterEntryOpen(rawName: rawName, descriptor: descriptor)
        )

        let observation: SettingsPublicationResidualEntryObservation
        do {
            let before = try metadata(
                descriptor,
                call: .inspectEntryBefore,
                rawName: rawName,
                operation: "inspect opened residual entry"
            )
            guard before == pathBefore else {
                throw EntryFailure.changed
            }
            if let reason = unsafeReason(before) {
                throw EntryFailure.unsafe(reason)
            }
            try validateACL(descriptor, rawName: rawName)
            guard before.size >= 0 else {
                throw EntryFailure.changed
            }
            guard before.size <= Int64(Self.maximumEntryBytes) else {
                throw EntryFailure.tooLarge(
                    actual: UInt64(before.size),
                    maximum: Self.maximumEntryBytes
                )
            }
            let byteCount = Int(before.size)
            guard byteCount
                    <= Self.maximumAggregateBytes - retainedBytes
            else {
                throw EntryFailure.aggregateLimit
            }
            let bytes = try readExact(
                descriptor,
                rawName: rawName,
                byteCount: byteCount
            )
            boundaryHook(.beforeEntryPostflight(rawName: rawName))
            let after = try metadata(
                descriptor,
                call: .inspectEntryAfter,
                rawName: rawName,
                operation: "reinspect residual entry"
            )
            let pathAfter = try pathMetadata(
                settingsDescriptor,
                rawName: rawName,
                call: .inspectEntryPathAfter,
                operation: "reinspect residual entry path"
            )
            try validateACL(descriptor, rawName: rawName)
            guard after == before,
                  pathAfter == before,
                  after.size == Int64(bytes.count)
            else {
                throw EntryFailure.changed
            }
            let sha = SettingsSourceSHA256(bytes)
            let content: SettingsPublicationResidualRetainedContent
            switch SettingsDocumentCodec().decode(bytes) {
            case .current(let document):
                content = .current(
                    token: .init(
                        revision: document.revision,
                        sourceSHA256: sha
                    )
                )
            case .future(let schemaVersion, _):
                content = .future(schemaVersion: schemaVersion)
            case .invalid(let failure):
                content = .corrupt(failure)
            }
            retainedBytes += bytes.count
            observation = .retained(
                bytes: bytes,
                sourceSHA256: sha,
                content: content
            )
        } catch let failure as EntryFailure {
            observation = .unavailable(failure.evidence)
        } catch {
            observation = .unavailable(
                .systemCall(
                    .init(
                        operation: "unexpected residual entry inspection",
                        code: EIO
                    )
                )
            )
        }

        closeEntry(
            descriptor,
            rawName: rawName,
            closeFailures: &closeFailures
        )
        return .init(
            rawName: rawName,
            nameValidity: validity,
            observation: observation
        )
    }

    private func validatePinnedDirectoryFinal(
        _ settingsDescriptor: Int32,
        pinnedBefore: SettingsPrimaryFileMetadata,
        partial: inout [SettingsPublicationResidualInventoryPartialReason]
    ) {
        do {
            let pinnedFinal = try metadata(
                settingsDescriptor,
                call: .inspectPinnedDirectoryFinal,
                rawName: nil,
                operation:
                    "finalize pinned Settings residual inventory"
            )
            try validateDirectory(pinnedFinal)
            guard pinnedFinal == pinnedBefore else {
                throw InventoryFailure.directoryChanged
            }
        } catch let failure as InventoryFailure {
            append(failure.partialReason, to: &partial)
        } catch {
            append(.directoryChangedDuringScan, to: &partial)
        }
    }

    private func readExact(
        _ descriptor: Int32,
        rawName: Data,
        byteCount: Int
    ) throws -> Data {
        var bytes = Data(count: byteCount)
        var offset = 0
        var interrupts = 0
        while offset < byteCount {
            boundaryHook(
                .beforeEntryRead(
                    rawName: rawName,
                    totalBytes: offset
                )
            )
            let directive = readHook(
                rawName,
                offset,
                byteCount - offset
            )
            let count: Int
            let code: Int32
            switch directive {
            case .system:
                count = bytes.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else {
                        return 0
                    }
                    return pread(
                        descriptor,
                        base.advanced(by: offset),
                        byteCount - offset,
                        off_t(offset)
                    )
                }
                code = count < 0 ? errno : 0
            case .failure(let injected):
                count = -1
                code = injected
            case .limit(let maximum):
                let requested = min(
                    max(0, maximum),
                    byteCount - offset
                )
                count = bytes.withUnsafeMutableBytes { raw in
                    guard let base = raw.baseAddress else {
                        return 0
                    }
                    return pread(
                        descriptor,
                        base.advanced(by: offset),
                        requested,
                        off_t(offset)
                    )
                }
                code = count < 0 ? errno : 0
            case .zero:
                count = 0
                code = 0
            }
            if count < 0 {
                if code == EINTR {
                    interrupts += 1
                    guard interrupts
                            <= Self.maximumConsecutiveInterrupts
                    else {
                        throw EntryFailure.system(
                            "read residual entry",
                            EIO
                        )
                    }
                    continue
                }
                throw EntryFailure.system(
                    "read residual entry",
                    code
                )
            }
            guard count > 0 else {
                throw EntryFailure.changed
            }
            interrupts = 0
            offset += count
        }
        var trailing: UInt8 = 0
        var trailingCount = -1
        var trailingInterrupts = 0
        repeat {
            let directive = trailingReadHook(
                rawName,
                byteCount,
                1
            )
            let code: Int32
            switch directive {
            case .system:
                trailingCount = pread(
                    descriptor,
                    &trailing,
                    1,
                    off_t(byteCount)
                )
                code = trailingCount < 0 ? errno : 0
            case .failure(let injected):
                trailingCount = -1
                code = injected
            case .limit(let maximum):
                let requested = min(max(0, maximum), 1)
                trailingCount = pread(
                    descriptor,
                    &trailing,
                    requested,
                    off_t(byteCount)
                )
                code = trailingCount < 0 ? errno : 0
            case .zero:
                trailingCount = 0
                code = 0
            }
            if trailingCount < 0, code == EINTR {
                trailingInterrupts += 1
                guard trailingInterrupts
                        <= Self.maximumConsecutiveInterrupts
                else {
                    throw EntryFailure.system(
                        "verify residual entry bound",
                        EIO
                    )
                }
                continue
            }
            if trailingCount < 0 {
                throw EntryFailure.system(
                    "verify residual entry bound",
                    code
                )
            }
        } while trailingCount < 0
        guard trailingCount == 0 else {
            throw EntryFailure.changed
        }
        return bytes
    }

    private func metadata(
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

    private func pathMetadata(
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

    private func validateDirectory(
        _ metadata: SettingsPrimaryFileMetadata
    ) throws {
        guard metadata.kind == .directory,
              metadata.owner == geteuid(),
              metadata.mode == 0o700
        else {
            throw InventoryFailure.directoryChanged
        }
    }

    private func unsafeReason(
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
        guard metadata.owner == geteuid() else {
            return .wrongOwner
        }
        guard metadata.mode == 0o600 else {
            return .incorrectMode(actual: metadata.mode)
        }
        guard metadata.linkCount == 1 else {
            return .multipleHardLinks
        }
        return nil
    }

    private func validateACL(
        _ descriptor: Int32,
        rawName: Data
    ) throws {
        let result: SettingsPrimaryDescriptorACLResult
        switch aclHook(rawName, descriptor) {
        case .system:
            result = SettingsPrimaryDescriptorSecurity.extendedACL(
                descriptor: descriptor
            )
        case .absent:
            result = .absent
        case .present:
            result = .present
        case .failure(let code):
            result = .failure(code: code)
        }
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

    private func closeEntry(
        _ descriptor: Int32,
        rawName: Data,
        closeFailures: inout [SettingsPublicationResidualCloseFailure]
    ) {
        let injected = systemCallHook(.closeEntry, rawName)
        let result = Darwin.close(descriptor)
        if let code = injected {
            closeFailures.append(
                .init(
                    target: .entry(rawName: rawName),
                    failure: .init(
                        operation: "close residual entry",
                        code: code
                    )
                )
            )
        } else if result != 0 {
            closeFailures.append(
                .init(
                    target: .entry(rawName: rawName),
                    failure: .init(
                        operation: "close residual entry",
                        code: errno
                    )
                )
            )
        }
    }

    private func closeDirectoryStream(
        _ stream: UnsafeMutablePointer<DIR>,
        closeFailures: inout [SettingsPublicationResidualCloseFailure],
        partial: inout [SettingsPublicationResidualInventoryPartialReason]
    ) {
        let injected = systemCallHook(.closeDirectory, nil)
        let result = closedir(stream)
        let failure: SettingsPublicationResidualCloseFailure?
        if let code = injected {
            failure = .init(
                target: .directoryStream,
                failure: .init(
                    operation: "close residual inventory directory stream",
                    code: code
                )
            )
        } else if result != 0 {
            failure = .init(
                target: .directoryStream,
                failure: .init(
                    operation: "close residual inventory directory stream",
                    code: errno
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

    private func closeRawDirectoryDescriptor(
        _ descriptor: Int32,
        closeFailures: inout [SettingsPublicationResidualCloseFailure],
        partial: inout [SettingsPublicationResidualInventoryPartialReason]
    ) {
        let injected = systemCallHook(.closeDirectory, nil)
        let result = Darwin.close(descriptor)
        let failure: SettingsPublicationResidualCloseFailure?
        if let code = injected {
            failure = .init(
                target: .directoryStream,
                failure: .init(
                    operation:
                        "close unopened residual inventory directory stream",
                    code: code
                )
            )
        } else if result != 0 {
            failure = .init(
                target: .directoryStream,
                failure: .init(
                    operation:
                        "close unopened residual inventory directory stream",
                    code: errno
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

    private func snapshot(
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

    private func failedEntry(
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

    private func unexpectedEntry(
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

    private func append(
        _ reason: SettingsPublicationResidualInventoryPartialReason,
        to reasons: inout [SettingsPublicationResidualInventoryPartialReason]
    ) {
        if !reasons.contains(reason) {
            reasons.append(reason)
        }
    }

    private func sameIdentity(
        _ lhs: SettingsPrimaryFileMetadata,
        _ rhs: SettingsPrimaryFileMetadata
    ) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode
    }

    private func directoryEntryName(
        _ entry: UnsafeMutablePointer<dirent>
    ) -> Data {
        let count = Int(entry.pointee.d_namlen)
        return withUnsafeBytes(of: &entry.pointee.d_name) {
            Data($0.prefix(count))
        }
    }

    private func rawByteLess(_ lhs: Data, _ rhs: Data) -> Bool {
        lhs.lexicographicallyPrecedes(rhs)
    }

    private func withFileSystemName<T>(
        _ rawName: Data,
        _ body: (UnsafePointer<CChar>) -> T
    ) -> T {
        var terminated = [UInt8](rawName)
        terminated.append(0)
        return terminated.withUnsafeBytes { raw in
            body(raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}

private enum InventoryFailure: Error {
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

private enum EntryFailure: Error {
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
