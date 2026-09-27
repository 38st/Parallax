import Darwin
import Foundation

/// A validated path relative to a pinned managed-root descriptor.
///
/// Paths intentionally cannot be initialized from an untrusted joined string.
/// Each component is checked before it can reach a descriptor-relative system
/// call.
struct SecureManagedPath: Sendable, Equatable, Hashable {
    let components: [String]

    init(_ components: [String]) throws {
        guard !components.isEmpty else {
            throw SecureManagedFileSystemError.invalidPathComponent
        }
        for component in components {
            guard
                !component.isEmpty,
                component != ".",
                component != "..",
                !component.contains("/"),
                !component.contains(":"),
                !component.contains("\0")
            else {
                throw SecureManagedFileSystemError.invalidPathComponent
            }
        }
        self.components = components
    }

    func appending(_ component: String) throws -> SecureManagedPath {
        try SecureManagedPath(components + [component])
    }
}

enum SecureManagedFileSystemError: LocalizedError, CustomNSError, Sendable, Equatable {
    case invalidRoot
    case rootNotDirectory
    case rootIdentityChanged
    case invalidPathComponent
    case symbolicLinkEncountered
    case hardLinkEncountered
    case unsupportedItem
    case unexpectedDestination
    case sourceMissing
    case sourceAndDestinationMatch
    case itemIdentityChanged
    case manifestMismatch
    case invalidFileName
    case systemCall(operation: String, code: Int32)
    case differentVolume
    case unsafeDirectory(path: String)
    case permissionsRestoreFailed(path: String, code: Int32)

    var errorUserInfo: [String: Any] {
        switch self {
        case .systemCall(let operation, let code):
            return filesystemErrorUserInfo(description: errorDescription, operation: operation, code: code)
        case .permissionsRestoreFailed(_, let code):
            return filesystemErrorUserInfo(description: errorDescription,
                operation: "restore managed directory permissions", code: code)
        default:
            return filesystemErrorUserInfo(description: errorDescription)
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidRoot:
            String(localized: "The managed storage folder is unavailable. Reconnect its volume or choose an available folder.")
        case .rootNotDirectory:
            String(localized: "The managed storage location is not a folder.")
        case .rootIdentityChanged, .itemIdentityChanged:
            String(localized: "The managed folder or file changed during the operation. Review it before trying again.")
        case .differentVolume:
            String(localized: "The managed folder contains another mounted volume. Unmount it before trying again.")
        case .unsafeDirectory(let path):
            String(localized: "Parallax cannot safely use the folder “\(path)”. Choose a folder you own without extended access rules, or repair its permissions in Finder and try again.")
        case .permissionsRestoreFailed(let path, _):
            String(localized: "Parallax could not restore permissions for “\(path)” after removal failed. Check the folder’s permissions before trying again.")
        case .invalidPathComponent, .invalidFileName:
            String(localized: "The managed path contains an invalid folder or file name.")
        case .symbolicLinkEncountered:
            String(localized: "The managed folder contains a symbolic link. Quit the application and review the link before trying again.")
        case .hardLinkEncountered:
            String(localized: "The managed folder contains a hard link. Review the linked item before trying again.")
        case .unsupportedItem:
            String(localized: "The managed folder contains an unsupported file type or protected file flags.")
        case .unexpectedDestination:
            String(localized: "The destination already exists. Parallax did not replace it.")
        case .sourceMissing:
            String(localized: "The managed folder or file no longer exists. Refresh and try again.")
        case .sourceAndDestinationMatch:
            String(localized: "The source and destination must be separate folders, with neither inside the other.")
        case .manifestMismatch:
            String(localized: "The managed data no longer matches the verified contents. Review it before trying again.")
        case .systemCall(_, let code) where code == EMFILE || code == ENFILE:
            String(localized: "The managed folder tree exceeds the available file descriptor limit. Close other applications or use a shallower folder tree.")
        case .systemCall(let operation, let code):
            systemCallFailureDescription(operation: operation, code: code)
        }
    }

}

enum SecureManagedFileSystemBoundary: Sendable, Equatable {
    case beforeOpenComponent(String)
    case beforeOpenFile(String, flags: Int32)
    case afterCopyDestinationCreation(String)
    case beforeRemoveOwnedTree
    case beforeRename
    case afterRename
}

struct SecureManagedItemIdentity: Sendable, Equatable, Hashable {
    enum Kind: String, Sendable, Equatable, Hashable {
        case directory
        case regularFile
    }

    let volumeID: UInt64
    let fileID: UInt64
    let kind: Kind
}

enum SecureManagedItemState: Sendable, Equatable {
    case missing
    case present(SecureManagedItemIdentity)
}

struct SecureManagedManifest: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let relativeComponents: [String]
        let kind: SecureManagedItemIdentity.Kind
        let byteCount: UInt64
        let permissions: UInt16
        let sha256: String?
    }

    let entries: [Entry]
}

struct SecureManagedFileSystemCalls: Sendable {
    var status: @Sendable (Int32, UnsafeMutablePointer<stat>) -> Int32 = { fstat($0, $1) }
    var statusAt: @Sendable (Int32, String, UnsafeMutablePointer<stat>, Int32) -> Int32 = {
        fstatat($0, $1, $2, $3)
    }
    var changeMode: @Sendable (Int32, mode_t) -> Int32 = { fchmod($0, $1) }
    var sync: @Sendable (Int32, Bool) -> Int32 = {
        $1 ? synchronizeFileDescriptor($0) : fsync($0)
    }
}
