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
