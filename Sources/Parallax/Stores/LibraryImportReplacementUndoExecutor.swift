import Foundation

struct LibraryImportReplacementUndoExecutor {
    let repository: any LibraryRepositoryPersisting
    let backupStore: LibraryBackupStore

    func prepareUndo(
        for replacement: LibraryImportReplacementResult,
        replacing primaryURL: URL
    ) throws -> LibraryPrimaryRestorePreparation {
        try backupStore.preparePrimaryRestore(
            from: replacement.backup,
            replacing: primaryURL
        )
    }

    func undo(
        replacement: LibraryImportReplacementResult
    ) throws -> LibraryImportReplacementUndoResult {
        let restore = try backupStore.prepareRestore(
            from: replacement.backup
        )
        let priorApplications = try LibraryPersistence
            .decodeApplications(from: restore.bytes)
        let current: LibraryRepositorySnapshot
        guard
            case let .loaded(loaded) = repository.load(),
            loaded.versionToken == replacement.snapshot.versionToken,
            loaded.applications == replacement.snapshot.applications
        else {
            throw LibraryImportReplacementError(.undoNoLongerValid)
        }
        current = loaded

        let replacementBackup = try backupStore.createBackup(
            of: current.originalBytes,
            reason: .destructiveRewrite
        )
        let verifiedReplacement = try backupStore.prepareRestore(
            from: replacementBackup
        )
        guard verifiedReplacement.bytes == current.originalBytes else {
            throw LibraryImportReplacementError(
                .backupVerificationFailed
            )
        }

        let prepared = try repository.prepare(
            priorApplications,
            expectedVersion: current.versionToken
        )
        let snapshot = try repository.withExclusiveMutation(
            expectedVersion: current.versionToken
        ) { capability in
            guard
                capability.applications == current.applications,
                capability.versionToken == current.versionToken
            else {
                throw LibraryImportReplacementError(
                    .undoNoLongerValid
                )
            }
            return try capability.commit(prepared).snapshot
        }
        return LibraryImportReplacementUndoResult(
            snapshot: snapshot,
            replacementBackup: replacementBackup
        )
    }
}
