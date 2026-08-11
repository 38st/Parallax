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

enum SecureManagedFileSystemError: Error, Sendable, Equatable {
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
}

enum SecureManagedFileSystemBoundary: Sendable, Equatable {
    case beforeOpenComponent(String)
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
