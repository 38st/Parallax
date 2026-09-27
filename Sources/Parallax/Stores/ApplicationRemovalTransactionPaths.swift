import Darwin
import Foundation

enum ApplicationRemovalTransactionPaths {
    static func secureFileSystem(
        for entry: ApplicationRemovalTransactionEntry,
        identitySource: ApplicationRemovalTransactionIdentitySource =
            ApplicationRemovalTransactionRootIdentity.read
    ) throws -> SecureManagedFileSystem {
        let secure: SecureManagedFileSystem
        do {
            secure = try SecureManagedFileSystem(
                rootURL: URL(fileURLWithPath: entry.baseRootPath, isDirectory: true)
            )
        } catch SecureManagedFileSystemError.invalidRoot {
            var status = stat()
            if lstat(entry.baseRootPath, &status) != 0, errno == ENOENT {
                throw ApplicationRemovalTransactionError(code: .storageUnavailable)
            }
            throw SecureManagedFileSystemError.invalidRoot
        }
        let current = try identitySource(secure)
        guard
            entry.baseRootInode.map({ $0 == current.inode }) ?? true,
            entry.baseRootVolumeUUID.flatMap({ recorded in
                current.volumeUUID.map {
                    recorded.caseInsensitiveCompare($0) == .orderedSame
                }
            }) ?? true
        else {
            throw ApplicationRemovalTransactionError(code: .targetChanged)
        }
        return secure
    }

    static func tombstone(
        _ entry: ApplicationRemovalTransactionEntry,
        transactionID: UUID
    ) throws -> SecureManagedPath {
        try stagingRoot(transactionID).appending(".purging-\(entry.profileStorageID.uuidString.lowercased())")
    }

    static func source(
        _ entry: ApplicationRemovalTransactionEntry,
        applicationStorageID: UUID
    ) throws -> SecureManagedPath {
        try SecureManagedPath([
            ".parallax",
            "Applications",
            applicationStorageID.uuidString.lowercased(),
            "Profiles",
            entry.profileStorageID.uuidString.lowercased(),
        ])
    }

    static func staged(
        _ entry: ApplicationRemovalTransactionEntry,
        transactionID: UUID
    ) throws -> SecureManagedPath {
        try SecureManagedPath([
            ".parallax",
            "ApplicationRemovalTransactions",
            transactionID.uuidString.lowercased(),
            entry.profileStorageID.uuidString.lowercased(),
        ])
    }

    static func stagingRoot(
        _ transactionID: UUID
    ) throws -> SecureManagedPath {
        try SecureManagedPath([
            ".parallax",
            "ApplicationRemovalTransactions",
            transactionID.uuidString.lowercased(),
        ])
    }

    static func archive(
        _ entry: ApplicationRemovalTransactionEntry
    ) throws -> SecureManagedPath {
        try SecureManagedPath([
            ".parallax",
            "Archives",
            URL(fileURLWithPath: entry.archivePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent,
            entry.profileStorageID.uuidString.lowercased(),
            URL(fileURLWithPath: entry.archivePath)
                .lastPathComponent,
        ])
    }

    static func ownerMarkerName(_ transactionID: UUID) -> String {
        ".parallax-owner-\(transactionID.uuidString.lowercased())"
    }

    static func ownerMarker(_ transactionID: UUID) -> String {
        "Parallax application-removal transaction \(transactionID.uuidString.lowercased())"
    }
}
