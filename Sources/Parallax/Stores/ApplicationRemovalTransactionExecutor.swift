import Foundation

struct ApplicationRemovalTransactionExecutor {
    let journal: ApplicationRemovalTransactionJournal
    let transactionBoundary:
        (@Sendable (ApplicationRemovalTransactionBoundary) throws -> Void)?

    func execute(
        _ manifest: inout ApplicationRemovalTransactionManifest,
        preparedCommit: PreparedLibraryCommit,
        expectedVersion: LibraryVersionToken,
        repository: any LibraryRepositoryPersisting,
        finishCommitted: (
            ApplicationRemovalTransactionManifest
        ) throws -> ApplicationRemovalTransactionOutcome
    ) throws -> ApplicationRemovalTransactionOutcome {
        try repository.withExclusiveMutation(
            expectedVersion: expectedVersion
        ) { capability in
            if manifest.dataChoice != .keep {
                for index in manifest.entries.indices {
                    let effect = ApplicationRemovalTransactionEffect
                        .stageProfile(
                            manifest.entries[index].profileStorageID,
                            index
                        )
                    try boundary(.beforeEffect(effect))
                    try stage(
                        &manifest.entries[index],
                        manifest: manifest
                    )
                    try boundary(.afterEffectBeforeRecord(effect))
                    try journal.persist(manifest)
                    try boundary(.afterRecord(effect))
                }
            }

            if manifest.dataChoice == .archive {
                for index in manifest.entries.indices
                where manifest.entries[index].sourceExisted {
                    let effect = ApplicationRemovalTransactionEffect
                        .publishArchive(
                            manifest.entries[index].profileStorageID,
                            index
                        )
                    try boundary(.beforeEffect(effect))
                    try publishArchive(
                        manifest.entries[index],
                        transactionID: manifest.transactionID
                    )
                    try boundary(.afterEffectBeforeRecord(effect))
                    try journal.persist(manifest)
                    try boundary(.afterRecord(effect))
                }
            }

            let commitEffect =
                ApplicationRemovalTransactionEffect.commitMetadata
            try boundary(.beforeEffect(commitEffect))
            _ = try capability.commit(
                preparedCommit,
                backupReason: nil
            )
            manifest.phase = .metadataCommitted
            try journal.persist(manifest)
            try boundary(.afterEffectBeforeRecord(commitEffect))
            try boundary(.afterRecord(commitEffect))

            return try finishCommitted(manifest)
        }
    }

    private func stage(
        _ entry: inout ApplicationRemovalTransactionEntry,
        manifest: ApplicationRemovalTransactionManifest
    ) throws {
        guard entry.sourceExisted else { return }
        let secure = try ApplicationRemovalTransactionPaths
            .secureFileSystem(for: entry)
        let source = try ApplicationRemovalTransactionPaths.source(
            entry,
            applicationStorageID: manifest.applicationStorageID
        )
        let staged = try ApplicationRemovalTransactionPaths.staged(
            entry,
            transactionID: manifest.transactionID
        )
        if case .present = try secure.itemState(at: staged) {
            return
        }
        guard
            case .present(let identity) =
                try secure.itemState(at: source),
            identity.kind == .directory,
            (entry.expectedDevice.map {
                $0 == identity.volumeID
            } ?? true),
            (entry.expectedInode.map {
                $0 == identity.fileID
            } ?? true)
        else {
            throw ApplicationRemovalTransactionError(
                code: .targetChanged
            )
        }
        try secure.write(
            Data(
                ApplicationRemovalTransactionPaths.ownerMarker(
                    manifest.transactionID
                ).utf8
            ),
            to: try source.appending(
                ApplicationRemovalTransactionPaths.ownerMarkerName(
                    manifest.transactionID
                )
            )
        )
        try secure.rename(from: source, to: staged)
    }

    private func publishArchive(
        _ entry: ApplicationRemovalTransactionEntry,
        transactionID: UUID
    ) throws {
        guard entry.sourceExisted else { return }
        let secure = try ApplicationRemovalTransactionPaths
            .secureFileSystem(for: entry)
        let staged = try ApplicationRemovalTransactionPaths.staged(
            entry,
            transactionID: transactionID
        )
        let archive = try ApplicationRemovalTransactionPaths.archive(entry)
        if case .present = try secure.itemState(at: archive) {
            return
        }
        try secure.rename(from: staged, to: archive)
    }

    private func boundary(
        _ value: ApplicationRemovalTransactionBoundary
    ) throws {
        try transactionBoundary?(value)
    }
}
