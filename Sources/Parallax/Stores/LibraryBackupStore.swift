import Foundation

/// Owns exact-byte metadata backups and corrupt-library quarantine artifacts.
///
/// Each artifact is assembled in a private sibling staging directory, synced,
/// and published with one rename. Preparing a restore only returns verified
/// bytes; the caller remains responsible for a separately coordinated primary
/// library replacement.
struct LibraryBackupStore {
    private let access: LibraryBackupStoreFileAccess
    private let inspection: LibraryBackupStoreInspection
    private let publication: LibraryBackupStorePublication
    private let retentionLimit: Int
    private let now: () -> Date
    private let makeIdentifier: () -> UUID

    init(
        fileSystem: any FileSystem = LocalFileSystem(),
        recoveryRoot: URL,
        retentionLimit: Int = 5,
        now: @escaping () -> Date = Date.init,
        makeIdentifier: @escaping () -> UUID = UUID.init
    ) {
        precondition(retentionLimit > 0, "Backup retention must be positive")
        let access = LibraryBackupStoreFileAccess(
            fileSystem: fileSystem,
            recoveryRoot: recoveryRoot.standardizedFileURL
        )
        let inspection = LibraryBackupStoreInspection(access: access)
        self.access = access
        self.inspection = inspection
        publication = LibraryBackupStorePublication(
            access: access,
            inspection: inspection,
            makeIdentifier: makeIdentifier
        )
        self.retentionLimit = retentionLimit
        self.now = now
        self.makeIdentifier = makeIdentifier
    }

    func createBackup(
        of bytes: Data,
        reason: LibraryBackupReason
    ) throws -> LibraryRecoveryArtifact {
        let content = try access.classifyBackup(bytes, reason: reason)
        let artifact = try publication.publish(
            bytes,
            kind: .backup,
            reason: reason,
            content: content,
            date: now(),
            id: makeIdentifier()
        )
        try publication.pruneBackups(retentionLimit: retentionLimit)
        return artifact
    }

    /// Copies a primary into quarantine. The source is deliberately not moved
    /// or removed so recovery UI can preserve the original failure evidence.
    func quarantineFile(at primaryURL: URL) throws -> LibraryRecoveryArtifact {
        try quarantine(access.stableBytes(at: primaryURL))
    }

    func quarantine(_ bytes: Data) throws -> LibraryRecoveryArtifact {
        try publication.publish(
            bytes,
            kind: .quarantine,
            reason: .corruptPrimary,
            content: .unvalidatedQuarantine,
            date: now(),
            id: makeIdentifier()
        )
    }

    func inspectArtifacts(
        kind: LibraryRecoveryArtifactKind? = nil
    ) throws -> [LibraryRecoveryInspection] {
        try inspection.inspectArtifacts(kind: kind)
    }

    func prepareRestore(
        from artifact: LibraryRecoveryArtifact
    ) throws -> LibraryRestorePreparation {
        try inspection.prepareRestore(from: artifact)
    }

    func prepareLatestBackupRestore() throws -> LibraryRestorePreparation {
        try inspection.prepareLatestBackupRestore()
    }

    /// Captures the exact, stable primary bytes for a pre-save backup. Invalid,
    /// legacy, and unsupported documents are rejected rather than mislabeled as
    /// last known good.
    func backupCurrentPrimary(
        at primaryURL: URL,
        reason: LibraryBackupReason
    ) throws -> LibraryRecoveryArtifact {
        try createBackup(
            of: access.stableBytes(at: primaryURL),
            reason: reason
        )
    }

    /// Verifies the restore source first, then preserves the exact current
    /// primary without replacing or deleting it. Valid current bytes become a
    /// backup; every other readable primary is quarantined.
    func preparePrimaryRestore(
        from artifact: LibraryRecoveryArtifact,
        replacing primaryURL: URL
    ) throws -> LibraryPrimaryRestorePreparation {
        let restore = try prepareRestore(from: artifact)
        let preservedPrimary: LibraryRecoveryArtifact?
        if access.fileSystem.fileExists(at: primaryURL) {
            let bytes = try access.stableBytes(at: primaryURL)
            if (try? LibraryPersistence.decodeCurrentDocument(from: bytes))
                != nil
            {
                preservedPrimary = try createBackup(
                    of: bytes,
                    reason: .destructiveRewrite
                )
            } else {
                preservedPrimary = try quarantine(bytes)
            }
        } else {
            preservedPrimary = nil
        }
        return LibraryPrimaryRestorePreparation(
            restore: restore,
            preservedPrimary: preservedPrimary
        )
    }

    /// Preserves a failed primary exactly and prepares an empty supported v2
    /// document. The caller must still obtain destructive authorization and
    /// perform the primary replacement transaction.
    func prepareQuarantineAndStartOver(
        primaryAt primaryURL: URL
    ) throws -> LibraryStartOverPreparation {
        let bytes = try access.stableBytes(at: primaryURL)
        let artifact = try quarantine(bytes)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let emptyLibraryBytes = try encoder.encode(
            LibraryDocument(
                revision: .initial,
                applications: []
            )
        )
        return LibraryStartOverPreparation(
            quarantine: artifact,
            originalSHA256: LibraryPersistence.sha256(bytes),
            emptyLibraryBytes: emptyLibraryBytes
        )
    }

    @discardableResult
    func export(
        _ artifact: LibraryRecoveryArtifact,
        to destinationURL: URL
    ) throws -> URL {
        try publication.export(artifact, to: destinationURL)
    }
}
