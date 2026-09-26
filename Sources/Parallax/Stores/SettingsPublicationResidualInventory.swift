import Darwin
import Foundation

struct SettingsPublicationResidualInventory: Sendable {
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

    let systemCallHook: SystemCallHook
    let boundaryHook: BoundaryHook
    let readHook: ReadHook
    let trailingReadHook: ReadHook
    let metadataHook: MetadataHook
    let aclHook: ACLHook
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
}
