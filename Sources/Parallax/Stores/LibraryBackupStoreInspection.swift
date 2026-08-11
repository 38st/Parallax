import Foundation

struct LibraryBackupStoreInspection {
    let access: LibraryBackupStoreFileAccess

    func inspectArtifacts(
        kind: LibraryRecoveryArtifactKind? = nil
    ) throws -> [LibraryRecoveryInspection] {
        let kinds = kind.map { [$0] } ?? [.backup, .quarantine]
        var inspections: [LibraryRecoveryInspection] = []
        for artifactKind in kinds {
            let root = try access.kindRoot(artifactKind, create: false)
            guard access.fileSystem.fileExists(at: root) else { continue }
            try access.requireDirectory(root)
            for bundleURL in try access.fileSystem.contentsOfDirectory(
                at: root
            ) {
                guard !bundleURL.lastPathComponent.hasPrefix(".staging-") else {
                    continue
                }
                guard
                    let inspection = try inspectBundle(
                        at: bundleURL,
                        expectedKind: artifactKind
                    )
                else {
                    continue
                }
                inspections.append(inspection)
            }
        }
        return inspections.sorted {
            if $0.artifact.createdAt != $1.artifact.createdAt {
                return $0.artifact.createdAt > $1.artifact.createdAt
            }
            return $0.artifact.id.uuidString > $1.artifact.id.uuidString
        }
    }

    func prepareRestore(
        from artifact: LibraryRecoveryArtifact
    ) throws -> LibraryRestorePreparation {
        guard
            artifact.kind == .backup,
            artifact.content == .currentLibrary
        else {
            throw LibraryBackupStoreError.notRestorable
        }
        let verified = try verifiedArtifact(
            at: artifact.libraryURL.deletingLastPathComponent(),
            expectedKind: .backup,
            expectedID: artifact.id
        )
        return LibraryRestorePreparation(
            artifact: verified.artifact,
            bytes: verified.bytes
        )
    }

    func prepareLatestBackupRestore() throws -> LibraryRestorePreparation {
        for inspection in try inspectArtifacts(kind: .backup)
        where inspection.isRestorable {
            do {
                return try prepareRestore(from: inspection.artifact)
            } catch {
                continue
            }
        }
        throw LibraryBackupStoreError.noVerifiedBackup
    }

    func inspectBundle(
        at bundleURL: URL,
        expectedKind: LibraryRecoveryArtifactKind
    ) throws -> LibraryRecoveryInspection? {
        guard
            let metadata = try? access.readMetadata(at: bundleURL),
            metadata.kind == expectedKind,
            bundleURL.lastPathComponent == access.bundleName(
                kind: metadata.kind,
                date: metadata.createdAt,
                id: metadata.id
            )
        else {
            return nil
        }
        let artifact = access.makeArtifact(
            metadata: metadata,
            bundleURL: bundleURL
        )
        guard (try? access.hasExpectedBundleContents(bundleURL)) == true else {
            return LibraryRecoveryInspection(
                artifact: artifact,
                problem: .invalidMetadata
            )
        }
        let payload = artifact.libraryURL
        guard access.fileSystem.fileExists(at: payload) else {
            return LibraryRecoveryInspection(
                artifact: artifact,
                problem: .missingPayload
            )
        }
        guard
            (try? access.fileSystem.attributesOfItem(at: payload).kind)
                == .regularFile,
            let bytes = try? access.fileSystem.readData(at: payload)
        else {
            return LibraryRecoveryInspection(
                artifact: artifact,
                problem: .missingPayload
            )
        }
        let matches = bytes.count == metadata.byteCount
            && LibraryPersistence.sha256(bytes) == metadata.sha256
        let problem: LibraryRecoveryArtifactProblem?
        if !matches {
            problem = .hashMismatch
        } else if !access.isValidContent(bytes, metadata: metadata) {
            problem = .invalidLibrary
        } else {
            problem = nil
        }
        return LibraryRecoveryInspection(
            artifact: artifact,
            problem: problem
        )
    }

    func verifiedArtifact(
        at bundleURL: URL,
        expectedKind: LibraryRecoveryArtifactKind,
        expectedID: UUID
    ) throws -> VerifiedLibraryRecoveryArtifact {
        try access.requireOwnedBundle(
            bundleURL,
            expectedKind: expectedKind
        )
        let metadata = try access.readMetadata(at: bundleURL)
        guard
            metadata.version
                == LibraryRecoveryArtifactMetadata.currentVersion,
            metadata.kind == expectedKind,
            metadata.id == expectedID,
            bundleURL.lastPathComponent == access.bundleName(
                kind: metadata.kind,
                date: metadata.createdAt,
                id: metadata.id
            )
        else {
            throw LibraryBackupStoreError.invalidMetadata
        }
        guard try access.hasExpectedBundleContents(bundleURL) else {
            throw LibraryBackupStoreError.invalidMetadata
        }
        let artifact = access.makeArtifact(
            metadata: metadata,
            bundleURL: bundleURL
        )
        guard access.fileSystem.fileExists(at: artifact.libraryURL) else {
            throw LibraryBackupStoreError.missingPayload
        }
        let attributes = try access.fileSystem.attributesOfItem(
            at: artifact.libraryURL
        )
        guard attributes.kind == .regularFile else {
            throw LibraryBackupStoreError.missingPayload
        }
        let bytes = try access.fileSystem.readData(at: artifact.libraryURL)
        guard
            bytes.count == metadata.byteCount,
            LibraryPersistence.sha256(bytes) == metadata.sha256
        else {
            throw LibraryBackupStoreError.hashMismatch
        }
        guard access.isValidContent(bytes, metadata: metadata) else {
            throw LibraryBackupStoreError.invalidLibrary
        }
        return VerifiedLibraryRecoveryArtifact(
            artifact: artifact,
            bytes: bytes
        )
    }
}
