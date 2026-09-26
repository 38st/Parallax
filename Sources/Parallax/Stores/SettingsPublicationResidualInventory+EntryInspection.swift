import Darwin
import Foundation

extension SettingsPublicationResidualInventory {
    func inspectEntry(
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

    func validatePinnedDirectoryFinal(
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
        let result = SettingsExactPread.read(
            byteCount: byteCount,
            retryPolicy: .init(
                interruptedCode: EINTR,
                content: .retry(
                    maximumConsecutive: Self.maximumConsecutiveInterrupts
                ),
                trailingByte: .retry(
                    maximumConsecutive: Self.maximumConsecutiveInterrupts
                )
            ),
            read: { destination, offset, requested in
                boundaryHook(
                    .beforeEntryRead(
                        rawName: rawName,
                        totalBytes: offset
                    )
                )
                let directive = readHook(rawName, offset, requested)
                let count: Int
                switch directive {
                case .system:
                    count = pread(
                        descriptor,
                        destination,
                        requested,
                        off_t(offset)
                    )
                case .failure(let code):
                    return .failure(code: code)
                case .limit(let maximum):
                    count = pread(
                        descriptor,
                        destination,
                        min(max(0, maximum), requested),
                        off_t(offset)
                    )
                case .zero:
                    return .bytes(0)
                }
                guard count >= 0 else {
                    return .failure(code: errno)
                }
                return .bytes(count)
            },
            trailingRead: { destination, offset, requested in
                let directive = trailingReadHook(
                    rawName,
                    offset,
                    requested
                )
                let count: Int
                switch directive {
                case .system:
                    count = pread(
                        descriptor,
                        destination,
                        requested,
                        off_t(offset)
                    )
                case .failure(let code):
                    return .failure(code: code)
                case .limit(let maximum):
                    count = pread(
                        descriptor,
                        destination,
                        min(max(0, maximum), requested),
                        off_t(offset)
                    )
                case .zero:
                    return .bytes(0)
                }
                guard count >= 0 else {
                    return .failure(code: errno)
                }
                return .bytes(count)
            }
        )
        switch result {
        case .success(let bytes):
            return bytes
        case .failure(
            .system(stage: .content, let code)
        ):
            throw EntryFailure.system("read residual entry", code)
        case .failure(
            .system(stage: .trailingByte, let code)
        ):
            throw EntryFailure.system(
                "verify residual entry bound",
                code
            )
        case .failure(
            .interruptLimitExceeded(stage: .content, _, _)
        ):
            throw EntryFailure.system("read residual entry", EIO)
        case .failure(
            .interruptLimitExceeded(stage: .trailingByte, _, _)
        ):
            throw EntryFailure.system(
                "verify residual entry bound",
                EIO
            )
        case .failure:
            throw EntryFailure.changed
        }
    }
}
