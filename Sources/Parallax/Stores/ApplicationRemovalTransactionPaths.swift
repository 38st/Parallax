import Foundation

enum ApplicationRemovalTransactionPaths {
    static func secureFileSystem(
        for entry: ApplicationRemovalTransactionEntry
    ) throws -> SecureManagedFileSystem {
        try SecureManagedFileSystem(
            rootURL: URL(
                fileURLWithPath: entry.baseRootPath,
                isDirectory: true
            )
        )
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
