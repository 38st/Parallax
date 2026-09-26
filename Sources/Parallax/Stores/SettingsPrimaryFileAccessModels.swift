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
