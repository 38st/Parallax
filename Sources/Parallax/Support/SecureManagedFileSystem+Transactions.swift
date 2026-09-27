import Darwin
import Foundation

extension SecureManagedFileSystem {
    func createStagingDirectory(
        in parent: SecureManagedPath,
        transactionID: UUID,
        permissions: mode_t = 0o700
    ) throws -> SecureManagedPath {
        let staging = try parent.appending(
            transactionID.uuidString.lowercased()
        )
        try createDirectory(at: staging, permissions: permissions)
        return staging
    }

    func removeOwnedTree(
        at path: SecureManagedPath,
        expectedIdentity: SecureManagedItemIdentity,
        expectedManifest: SecureManagedManifest
    ) throws {
        try verifyRootIdentity()
        let expectedStatus = try preflight(path: path)
        guard try Self.managedIdentity(from: expectedStatus) == expectedIdentity else {
            throw SecureManagedFileSystemError.itemIdentityChanged
        }
        guard try manifest(at: path) == expectedManifest else {
            throw SecureManagedFileSystemError.manifestMismatch
        }
        let removalManifest = try RemovalManifest(expectedManifest)
        try performBoundary(.beforeRemoveOwnedTree)
        let (parent, leaf) = try openParent(of: path, createMissing: false)
        defer { close(parent) }
        try removeItem(
            parent: parent,
            name: leaf,
            expectedStatus: expectedStatus,
            expectedManifest: removalManifest
        )
        try synchronize(parent, operation: "fsync owned removal parent")
        try verifyRootIdentity()
    }

    func relocateTree(
        from source: SecureManagedPath,
        to destination: SecureManagedPath,
        in destinationFileSystem: SecureManagedFileSystem
    ) throws {
        let sourceState = try itemState(at: source)
        guard case let .present(sourceIdentity) = sourceState else {
            throw SecureManagedFileSystemError.sourceMissing
        }
        let sourceManifest = try manifest(at: source)
        try copyTree(
            from: source,
            to: destination,
            in: destinationFileSystem
        )
        try removeOwnedTree(
            at: source,
            expectedIdentity: sourceIdentity,
            expectedManifest: sourceManifest
        )
    }
}
