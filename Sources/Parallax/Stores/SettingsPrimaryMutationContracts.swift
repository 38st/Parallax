import Darwin
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

extension SettingsPrimaryMutationLockItem {
    var localizedName: String {
        switch self {
        case .trustedContainer:
            String(localized: "the trusted Parallax container")
        case .settingsDirectory:
            String(localized: "the settings directory")
        case .lock:
            String(localized: "the settings lock file")
        }
    }
}

extension SettingsPrimaryMutationLockUnsafeReason {
    var localizedSummary: String {
        switch self {
        case .symbolicLink:
            String(localized: "it is a symbolic link")
        case .wrongOwner:
            String(localized: "it is not owned by the current user")
        case let .incorrectMode(expected, actual):
            String(
                localized:
                    "its permissions are \(String(format: "%o", actual)) instead of \(String(format: "%o", expected))"
            )
        case .extendedACL:
            String(localized: "it carries an extended access control list")
        case .unsupportedType:
            String(
                localized:
                    "it is not the expected kind of file system item"
            )
        case .multipleHardLinks:
            String(localized: "it has more than one hard link")
        }
    }
}

extension SettingsPrimaryMutationLockSystemFailure {
    var localizedSummary: String {
        String(
            localized:
                "Parallax could not \(operation): \(String(cString: strerror(code)))."
        )
    }
}

extension SettingsPrimaryMutationLockCleanupError {
    var localizedSummary: String {
        guard !failures.isEmpty else {
            return String(
                localized: "Parallax could not release the settings lock."
            )
        }
        return failures
            .map(\.localizedSummary)
            .joined(separator: " ")
    }
}

extension SettingsPrimaryMutationLockError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .missingTrustedContainer:
            String(
                localized:
                    "Parallax could not reach its trusted container while locking settings."
            )
        case let .unsafeItem(item, reason):
            String(
                localized:
                    "Parallax did not lock settings because \(item.localizedName) is unsafe: \(reason.localizedSummary)."
            )
        case let .changedDuringAcquisition(item):
            String(
                localized:
                    "Parallax did not lock settings because \(item.localizedName) changed while the lock was being acquired."
            )
        case let .timedOut(timeout):
            String(
                localized:
                    "Parallax timed out after \(String(format: "%.0f", timeout)) seconds waiting for the settings lock. Another Parallax process may still hold it."
            )
        case let .systemCall(failure):
            failure.localizedSummary
        }
    }
}
