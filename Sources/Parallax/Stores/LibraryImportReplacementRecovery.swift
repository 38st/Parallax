import Foundation

struct LibraryImportReplacementRecovery {
    let repository: any LibraryRepositoryPersisting

    func recoverFailedReplacementIfNeeded(
        evidence: LibraryImportReplacementEvidence,
        originalError: Error
    ) throws {
        let current: LibraryRepositorySnapshot
        switch repository.load() {
        case let .loaded(snapshot):
            current = snapshot
        case .missing:
            if evidence.expectedVersion == .missing {
                return
            }
            throw LibraryImportReplacementError(
                .recoveryRequired,
                detail: String(reflecting: type(of: originalError))
            )
        case .migrationRequired, .recoveryRequired, .readOnly:
            throw LibraryImportReplacementError(
                .recoveryRequired,
                detail: String(reflecting: type(of: originalError))
            )
        }

        if current.versionToken == evidence.expectedVersion {
            return
        }
        guard
            current.versionToken == evidence.preparedCommit.targetVersion,
            current.applications == evidence.preparedCommit.applications
        else {
            // A stale competing writer is not rollback authority.
            if case LibraryRepositoryError.staleWriter = originalError {
                return
            }
            throw LibraryImportReplacementError(
                .recoveryRequired,
                detail: String(reflecting: type(of: originalError))
            )
        }

        do {
            let rollback = try repository.prepare(
                evidence.priorApplications,
                expectedVersion: current.versionToken
            )
            _ = try repository.withExclusiveMutation(
                expectedVersion: current.versionToken
            ) { capability in
                try capability.commit(rollback)
            }
        } catch {
            if case let .loaded(snapshot) = repository.load(),
               snapshot.applications == evidence.priorApplications {
                throw LibraryImportReplacementError(
                    .replacementFailedAndRolledBack,
                    detail: String(reflecting: type(of: originalError))
                )
            }
            throw LibraryImportReplacementError(
                .recoveryRequired,
                detail: String(reflecting: type(of: error))
            )
        }
        throw LibraryImportReplacementError(
            .replacementFailedAndRolledBack,
            detail: String(reflecting: type(of: originalError))
        )
    }
}
