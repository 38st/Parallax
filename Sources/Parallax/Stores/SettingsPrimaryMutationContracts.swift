import Foundation

enum SettingsPrimaryMutationLockItem: Sendable, Equatable {
    case trustedContainer
    case settingsDirectory
    case lock
}

enum SettingsPrimaryMutationLockUnsafeReason: Sendable, Equatable {
    case symbolicLink
    case wrongOwner
    case incorrectMode(expected: UInt16, actual: UInt16)
    case extendedACL
    case unsupportedType
    case multipleHardLinks
}

struct SettingsPrimaryMutationLockSystemFailure: Error, Sendable, Equatable {
    let operation: String
    let code: Int32
}

enum SettingsPrimaryMutationLockError: Error, Sendable, Equatable {
    case missingTrustedContainer
    case unsafeItem(
        item: SettingsPrimaryMutationLockItem,
        reason: SettingsPrimaryMutationLockUnsafeReason
    )
    case changedDuringAcquisition(item: SettingsPrimaryMutationLockItem)
    case timedOut(timeout: TimeInterval)
    case systemCall(SettingsPrimaryMutationLockSystemFailure)
}

struct SettingsPrimaryMutationLockCleanupError: Error, Sendable, Equatable {
    let failures: [SettingsPrimaryMutationLockSystemFailure]
}

struct SettingsPrimaryMutationLockPrimaryAndCleanupError:
    Error,
    @unchecked Sendable
{
    let primary: any Error
    let cleanup: SettingsPrimaryMutationLockCleanupError
}

enum SettingsPrimaryLockedInspectionError: Error, Sendable, Equatable {
    case expiredAuthority
    case reentrantAuthorityOperation
    case lockValidation(SettingsPrimaryMutationLockError)
    case fileAccess(SettingsPrimaryFileAccessError)
    case authorityContainerClose(SettingsPrimaryMutationLockSystemFailure)
    case lockValidationAndAuthorityContainerClose(
        validation: SettingsPrimaryMutationLockError,
        close: SettingsPrimaryMutationLockSystemFailure
    )
}

enum SettingsPrimaryMutationLockBoundary: Sendable, Equatable {
    case afterContainerOpen
    case afterSettingsPreflight
    case afterSettingsCreatedIdentity
    case beforeSettingsPublish
    case afterSettingsPublish
    case afterSettingsOpen
    case afterLockPreflight
    case afterLockOpen
    case beforeFlock
    case afterFlock
}

enum SettingsPrimaryMutationLockSystemCall: Sendable, Equatable {
    case openContainer
    case inspectContainer
    case inspectSettingsPath
    case createSettings
    case inspectCreatedSettingsPath
    case openSettings
    case inspectSettings
    case setSettingsMode
    case reinspectSettings
    case reinspectSettingsPath
    case publishSettings
    case inspectPublishedSettingsPath
    case syncContainer
    case inspectLockPath
    case createLock
    case reopenLock
    case inspectLock
    case setLockMode
    case reinspectLock
    case reinspectLockPath
    case syncSettings
    case flock
    case reopenContainer
    case inspectReopenedContainer
    case reinspectPinnedContainer
    case reinspectPinnedSettings
    case reinspectSettingsPathAfterLock
    case reinspectPinnedLock
    case reinspectLockPathAfterLock
    case closeAuthorityContainer
    case unlock
    case closeLock
    case closeReopenedContainer
    case closeSettings
    case closeContainer
}
