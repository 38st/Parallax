import Foundation

struct LibraryImportReplacementExecutor {
    let repository: any LibraryRepositoryPersisting
    let backupStore: LibraryBackupStore
    let recovery: LibraryImportReplacementRecovery

    func replace(
        using evidence: LibraryImportReplacementEvidence
    ) throws -> LibraryImportReplacementExecutionOutcome {
        let backup = try backupStore.createBackup(
            of: evidence.priorLibraryBytes,
            reason: .importReplacement
        )
        let verified = try backupStore.prepareRestore(from: backup)
        guard verified.bytes == evidence.priorLibraryBytes else {
            throw LibraryImportReplacementError(
                .backupVerificationFailed
            )
        }

        do {
            let snapshot = try repository.withExclusiveMutation(
                expectedVersion: evidence.expectedVersion
            ) { capability in
                guard
                    capability.applications == evidence.priorApplications,
                    capability.versionToken == evidence.expectedVersion
                else {
                    throw LibraryImportReplacementError(.invalidPreview)
                }
                return try capability.commit(
                    evidence.preparedCommit
                ).snapshot
            }
            guard
                snapshot.versionToken
                    == evidence.preparedCommit.targetVersion,
                snapshot.applications
                    == evidence.preparedCommit.applications
            else {
                throw LibraryImportReplacementError(.recoveryRequired)
            }
            return LibraryImportReplacementExecutionOutcome(
                snapshot: snapshot,
                backup: backup
            )
        } catch {
            try recovery.recoverFailedReplacementIfNeeded(
                evidence: evidence,
                originalError: error
            )
            throw error
        }
    }
}
