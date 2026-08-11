import Foundation

struct LibraryBackupStorePublication {
    let access: LibraryBackupStoreFileAccess
    let inspection: LibraryBackupStoreInspection
    let makeIdentifier: () -> UUID

    func publish(
        _ bytes: Data,
        kind: LibraryRecoveryArtifactKind,
        reason: LibraryBackupReason,
        content: LibraryRecoveryArtifactContent,
        date: Date,
        id: UUID
    ) throws -> LibraryRecoveryArtifact {
        let root = try access.kindRoot(kind, create: true)
        let name = access.bundleName(kind: kind, date: date, id: id)
        let finalBundle = root.appendingPathComponent(
            name,
            isDirectory: true
        )
        guard !access.fileSystem.fileExists(at: finalBundle) else {
            throw LibraryBackupStoreError.invalidArtifact
        }
        let staging = root.appendingPathComponent(
            ".staging-\(id.uuidString.lowercased())",
            isDirectory: true
        )
        guard !access.fileSystem.fileExists(at: staging) else {
            throw LibraryBackupStoreError.invalidArtifact
        }

        let metadata = LibraryRecoveryArtifactMetadata(
            version: LibraryRecoveryArtifactMetadata.currentVersion,
            id: id,
            kind: kind,
            reason: reason,
            content: content,
            createdAt: date,
            byteCount: bytes.count,
            sha256: LibraryPersistence.sha256(bytes)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadataBytes = try encoder.encode(metadata)
        let payloadURL = staging.appendingPathComponent(
            LibraryBackupStoreFileAccess.payloadName,
            isDirectory: false
        )
        let metadataURL = staging.appendingPathComponent(
            LibraryBackupStoreFileAccess.metadataName,
            isDirectory: false
        )

        do {
            try access.fileSystem.createDirectory(
                at: staging,
                withIntermediateDirectories: false
            )
            try access.fileSystem.setPOSIXPermissions(0o700, at: staging)
            try access.fileSystem.writeData(bytes, to: payloadURL)
            try access.fileSystem.setPOSIXPermissions(0o600, at: payloadURL)
            try access.fileSystem.writeData(metadataBytes, to: metadataURL)
            try access.fileSystem.setPOSIXPermissions(0o600, at: metadataURL)
            try access.fileSystem.synchronize(at: payloadURL)
            try access.fileSystem.synchronize(at: metadataURL)
            try access.fileSystem.synchronize(at: staging)
            try access.fileSystem.moveItem(at: staging, to: finalBundle)
            try access.fileSystem.synchronize(at: root)
        } catch {
            if access.fileSystem.fileExists(at: staging) {
                try? access.fileSystem.removeItem(at: staging)
            }
            throw error
        }

        let verified = try inspection.verifiedArtifact(
            at: finalBundle,
            expectedKind: kind,
            expectedID: id
        )
        return verified.artifact
    }

    @discardableResult
    func export(
        _ artifact: LibraryRecoveryArtifact,
        to destinationURL: URL
    ) throws -> URL {
        let verified = try inspection.verifiedArtifact(
            at: artifact.libraryURL.deletingLastPathComponent(),
            expectedKind: artifact.kind,
            expectedID: artifact.id
        )
        let destination = destinationURL.standardizedFileURL
        guard !access.fileSystem.fileExists(at: destination) else {
            throw LibraryBackupStoreError.destinationExists
        }
        let parent = destination.deletingLastPathComponent()
        if access.fileSystem.fileExists(at: parent) {
            try access.requireDirectory(parent)
        } else {
            try access.fileSystem.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            try access.requireDirectory(parent)
            try access.fileSystem.setPOSIXPermissions(0o700, at: parent)
        }
        let temporary = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).\(makeIdentifier().uuidString).tmp",
            isDirectory: false
        )
        do {
            try access.fileSystem.writeData(verified.bytes, to: temporary)
            try access.fileSystem.setPOSIXPermissions(0o600, at: temporary)
            try access.fileSystem.synchronize(at: temporary)
            try access.fileSystem.moveItem(at: temporary, to: destination)
            try access.fileSystem.synchronize(at: parent)
        } catch {
            if access.fileSystem.fileExists(at: temporary) {
                try? access.fileSystem.removeItem(at: temporary)
            }
            throw error
        }
        guard
            try access.fileSystem.readData(at: destination) == verified.bytes
        else {
            throw LibraryBackupStoreError.hashMismatch
        }
        return destination
    }

    func pruneBackups(retentionLimit: Int) throws {
        let backupRoot = try access.kindRoot(.backup, create: true)
        let bundles = try access.fileSystem.contentsOfDirectory(at: backupRoot)
            .compactMap {
                bundleURL -> (URL, LibraryRecoveryArtifactMetadata)? in
                guard
                    !bundleURL.lastPathComponent.hasPrefix(".staging-"),
                    let metadata = try? access.readMetadata(at: bundleURL),
                    metadata.kind == .backup,
                    bundleURL.lastPathComponent == access.bundleName(
                        kind: metadata.kind,
                        date: metadata.createdAt,
                        id: metadata.id
                    ),
                    let inspected = try? inspection.inspectBundle(
                        at: bundleURL,
                        expectedKind: .backup
                    ),
                    inspected.isVerified
                else {
                    return nil
                }
                return (bundleURL, metadata)
            }
            .sorted {
                if $0.1.createdAt != $1.1.createdAt {
                    return $0.1.createdAt > $1.1.createdAt
                }
                return $0.1.id.uuidString > $1.1.id.uuidString
            }
        for expired in bundles.dropFirst(retentionLimit) {
            try access.requireOwnedBundle(
                expired.0,
                expectedKind: .backup
            )
            try access.fileSystem.removeItem(at: expired.0)
        }
        try access.fileSystem.synchronize(at: backupRoot)
    }
}
