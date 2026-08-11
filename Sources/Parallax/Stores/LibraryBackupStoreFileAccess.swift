import Foundation

/// Keeps recovery-root ownership and stable-read checks behind one filesystem
/// authority boundary shared by inspection and publication operations.
final class LibraryBackupStoreFileAccess {
    static let payloadName = "library.json"
    static let metadataName = "metadata.json"

    let fileSystem: any FileSystem
    let recoveryRoot: URL

    init(
        fileSystem: any FileSystem,
        recoveryRoot: URL
    ) {
        self.fileSystem = fileSystem
        self.recoveryRoot = recoveryRoot
    }

    func kindRoot(
        _ kind: LibraryRecoveryArtifactKind,
        create: Bool
    ) throws -> URL {
        guard recoveryRoot.isFileURL, recoveryRoot.path.hasPrefix("/") else {
            throw LibraryBackupStoreError.invalidRecoveryRoot
        }
        if create {
            try ensureDirectory(recoveryRoot)
        } else if fileSystem.fileExists(at: recoveryRoot) {
            try requireDirectory(recoveryRoot)
        }
        let component = kind == .backup ? "Backups" : "Quarantine"
        let root = recoveryRoot.appendingPathComponent(
            component,
            isDirectory: true
        )
        if create {
            try ensureDirectory(root)
        }
        return root
    }

    func ensureDirectory(_ url: URL) throws {
        if fileSystem.fileExists(at: url) {
            try requireDirectory(url)
        } else {
            try fileSystem.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
            try requireDirectory(url)
        }
        try fileSystem.setPOSIXPermissions(0o700, at: url)
    }

    func requireDirectory(_ url: URL) throws {
        let attributes = try fileSystem.attributesOfItem(at: url)
        guard attributes.kind == .directory else {
            throw LibraryBackupStoreError.invalidRecoveryRoot
        }
    }

    func bundleName(
        kind: LibraryRecoveryArtifactKind,
        date: Date,
        id: UUID
    ) -> String {
        let timestamp = Int64(
            (date.timeIntervalSince1970 * 1_000).rounded(.down)
        )
        let suffix = kind == .backup ? "backup" : "quarantine"
        return "\(timestamp)-\(id.uuidString.lowercased()).\(suffix)"
    }

    func requireOwnedBundle(
        _ bundleURL: URL,
        expectedKind: LibraryRecoveryArtifactKind
    ) throws {
        let expectedRoot = try kindRoot(expectedKind, create: false)
        let suppliedParent = bundleURL.standardizedFileURL
            .deletingLastPathComponent()
        guard suppliedParent == expectedRoot.standardizedFileURL else {
            throw LibraryBackupStoreError.invalidArtifact
        }
        let attributes = try fileSystem.attributesOfItem(at: bundleURL)
        guard attributes.kind == .directory else {
            throw LibraryBackupStoreError.invalidArtifact
        }
    }

    func hasExpectedBundleContents(_ bundleURL: URL) throws -> Bool {
        let contents = try fileSystem.contentsOfDirectory(at: bundleURL)
        guard contents.count == 2 else { return false }
        return Set(contents.map(\.lastPathComponent))
            == [Self.payloadName, Self.metadataName]
    }

    func readMetadata(
        at bundleURL: URL
    ) throws -> LibraryRecoveryArtifactMetadata {
        let attributes = try fileSystem.attributesOfItem(at: bundleURL)
        guard attributes.kind == .directory else {
            throw LibraryBackupStoreError.invalidMetadata
        }
        let metadataURL = bundleURL.appendingPathComponent(
            Self.metadataName,
            isDirectory: false
        )
        guard fileSystem.fileExists(at: metadataURL) else {
            throw LibraryBackupStoreError.invalidMetadata
        }
        let metadataAttributes = try fileSystem.attributesOfItem(
            at: metadataURL
        )
        guard metadataAttributes.kind == .regularFile else {
            throw LibraryBackupStoreError.invalidMetadata
        }
        do {
            let metadata = try JSONDecoder().decode(
                LibraryRecoveryArtifactMetadata.self,
                from: fileSystem.readData(at: metadataURL)
            )
            guard
                metadata.version
                    == LibraryRecoveryArtifactMetadata.currentVersion
            else {
                throw LibraryBackupStoreError.invalidMetadata
            }
            return metadata
        } catch let error as LibraryBackupStoreError {
            throw error
        } catch {
            throw LibraryBackupStoreError.invalidMetadata
        }
    }

    func makeArtifact(
        metadata: LibraryRecoveryArtifactMetadata,
        bundleURL: URL
    ) -> LibraryRecoveryArtifact {
        LibraryRecoveryArtifact(
            id: metadata.id,
            kind: metadata.kind,
            reason: metadata.reason,
            content: metadata.content,
            createdAt: metadata.createdAt,
            libraryURL: bundleURL.appendingPathComponent(
                Self.payloadName,
                isDirectory: false
            ),
            byteCount: metadata.byteCount,
            sha256: metadata.sha256
        )
    }

    func classifyBackup(
        _ bytes: Data,
        reason: LibraryBackupReason
    ) throws -> LibraryRecoveryArtifactContent {
        do {
            switch try LibraryPersistence.decodeLibrary(from: bytes) {
            case .current:
                return .currentLibrary
            case .migrationRequired where reason == .migration:
                return .legacyMigrationSource
            case .migrationRequired:
                throw LibraryBackupStoreError.invalidLibrary
            }
        } catch let error as LibraryBackupStoreError {
            throw error
        } catch {
            throw LibraryBackupStoreError.invalidLibrary
        }
    }

    func isValidContent(
        _ bytes: Data,
        metadata: LibraryRecoveryArtifactMetadata
    ) -> Bool {
        switch (metadata.kind, metadata.content) {
        case (.quarantine, .unvalidatedQuarantine):
            return true
        case (.backup, .currentLibrary):
            return (try? LibraryPersistence.decodeCurrentDocument(from: bytes))
                != nil
        case (.backup, .legacyMigrationSource):
            guard metadata.reason == .migration else { return false }
            guard
                case .migrationRequired = try? LibraryPersistence.decodeLibrary(
                    from: bytes
                )
            else {
                return false
            }
            return true
        default:
            return false
        }
    }

    func stableBytes(at url: URL) throws -> Data {
        let before = try fileSystem.attributesOfItem(at: url)
        guard before.kind == .regularFile else {
            throw LibraryBackupStoreError.invalidArtifact
        }
        let bytes = try fileSystem.readData(at: url)
        let middle = try fileSystem.attributesOfItem(at: url)
        guard
            middle.kind == .regularFile,
            before.identity == middle.identity,
            before.size == middle.size,
            middle.size == UInt64(bytes.count)
        else {
            throw LibraryBackupStoreError.invalidArtifact
        }
        let confirmation = try fileSystem.readData(at: url)
        let after = try fileSystem.attributesOfItem(at: url)
        guard
            after.kind == .regularFile,
            before.identity == after.identity,
            before.size == after.size,
            after.size == UInt64(confirmation.count),
            bytes == confirmation
        else {
            throw LibraryBackupStoreError.invalidArtifact
        }
        return bytes
    }
}
