import Foundation

struct ApplicationRemovalTransactionRecovery {
    let journal: ApplicationRemovalTransactionJournal
    let transactionBoundary:
        (@Sendable (ApplicationRemovalTransactionBoundary) throws -> Void)?

    func repositoryMatchesTarget(
        _ repository: any LibraryRepositoryPersisting,
        manifest: ApplicationRemovalTransactionManifest
    ) -> Bool {
        guard case .loaded(let snapshot) = repository.load() else {
            return false
        }
        return snapshot.versionToken.revision.rawValue
                == manifest.targetRevision
            && snapshot.versionToken.primarySHA256
                == manifest.targetSHA256
    }

    func rollback(
        _ manifest: ApplicationRemovalTransactionManifest
    ) throws -> ApplicationRemovalTransactionOutcome {
        for entry in manifest.entries.reversed()
        where entry.sourceExisted {
            let secure = try ApplicationRemovalTransactionPaths
                .secureFileSystem(for: entry)
            let source = try ApplicationRemovalTransactionPaths.source(
                entry,
                applicationStorageID:
                    manifest.applicationStorageID
            )
            let staged = try ApplicationRemovalTransactionPaths.staged(
                entry,
                transactionID: manifest.transactionID
            )
            let archive = try ApplicationRemovalTransactionPaths.archive(
                entry
            )
            if case .present = try secure.itemState(at: source) {
                continue
            }
            let recoverable: SecureManagedPath?
            if case .present = try secure.itemState(at: archive) {
                recoverable = archive
            } else if case .present =
                try secure.itemState(at: staged)
            {
                recoverable = staged
            } else {
                recoverable = nil
            }
            if let recoverable {
                try verifyOwnership(
                    secure,
                    recoverable,
                    transactionID: manifest.transactionID
                )
                try secure.rename(
                    from: recoverable,
                    to: source
                )
                try? secure.removeTree(
                    at: try source.appending(
                        ApplicationRemovalTransactionPaths.ownerMarkerName(
                            manifest.transactionID
                        )
                    )
                )
            }
        }
        try removeStagingRootIfPresent(manifest)
        return try journal.recordCompletion(
            manifest,
            completion: .rolledBack,
            archiveURLs: [:]
        )
    }

    func finishCommitted(
        _ manifest: ApplicationRemovalTransactionManifest
    ) throws -> ApplicationRemovalTransactionOutcome {
        var archives: [UUID: URL] = [:]
        switch manifest.dataChoice {
        case .keep:
            break
        case .archive:
            for entry in manifest.entries
            where entry.sourceExisted {
                let secure = try ApplicationRemovalTransactionPaths
                    .secureFileSystem(for: entry)
                let staged = try ApplicationRemovalTransactionPaths.staged(
                    entry,
                    transactionID: manifest.transactionID
                )
                let archive = try ApplicationRemovalTransactionPaths.archive(
                    entry
                )
                if case .present =
                    try secure.itemState(at: staged),
                   case .missing =
                    try secure.itemState(at: archive)
                {
                    try verifyOwnership(
                        secure,
                        staged,
                        transactionID: manifest.transactionID
                    )
                    try secure.rename(from: staged, to: archive)
                }
                if case .present =
                    try secure.itemState(at: archive)
                {
                    try verifyOwnership(
                        secure,
                        archive,
                        transactionID: manifest.transactionID
                    )
                    try? secure.removeTree(
                        at: try archive.appending(
                            ApplicationRemovalTransactionPaths.ownerMarkerName(
                                manifest.transactionID
                            )
                        )
                    )
                    archives[entry.profileStorageID] = URL(
                        fileURLWithPath: entry.archivePath
                    )
                }
            }
        case .delete:
            if try stagingRootExists(manifest) {
                for entry in manifest.entries
                where entry.sourceExisted {
                    let secure = try ApplicationRemovalTransactionPaths
                        .secureFileSystem(for: entry)
                    let staged = try ApplicationRemovalTransactionPaths.staged(
                        entry,
                        transactionID: manifest.transactionID
                    )
                    if case .present =
                        try secure.itemState(at: staged)
                    {
                        try verifyOwnership(
                            secure,
                            staged,
                            transactionID: manifest.transactionID
                        )
                    }
                }
                let effect =
                    ApplicationRemovalTransactionEffect.purgeStaging
                try boundary(.beforeEffect(effect))
                try removeStagingRootIfPresent(manifest)
                try boundary(.afterEffectBeforeRecord(effect))
                try boundary(.afterRecord(effect))
            }
        }
        try removeStagingRootIfPresent(manifest)
        return try journal.recordCompletion(
            manifest,
            completion: .committed,
            archiveURLs: archives
        )
    }

    private func verifyOwnership(
        _ secure: SecureManagedFileSystem,
        _ directory: SecureManagedPath,
        transactionID: UUID
    ) throws {
        let markerName = ApplicationRemovalTransactionPaths
            .ownerMarkerName(transactionID)
        let expectedHash = LibraryPersistence.sha256(
            Data(
                ApplicationRemovalTransactionPaths.ownerMarker(
                    transactionID
                ).utf8
            )
        )
        let manifest = try secure.manifest(at: directory)
        guard manifest.entries.contains(where: {
            $0.relativeComponents == [markerName]
                && $0.kind == .regularFile
                && $0.sha256 == expectedHash
        })
        else {
            throw ApplicationRemovalTransactionError(
                code: .unownedStagedData
            )
        }
    }

    private func stagingRootExists(
        _ manifest: ApplicationRemovalTransactionManifest
    ) throws -> Bool {
        guard
            let entry = manifest.entries.first(where: {
                $0.sourceExisted
            })
        else {
            return false
        }
        let secure = try ApplicationRemovalTransactionPaths
            .secureFileSystem(for: entry)
        if case .present =
            try secure.itemState(
                at: ApplicationRemovalTransactionPaths.stagingRoot(
                    manifest.transactionID
                )
            )
        {
            return true
        }
        return false
    }

    private func removeStagingRootIfPresent(
        _ manifest: ApplicationRemovalTransactionManifest
    ) throws {
        guard
            let entry = manifest.entries.first(where: {
                $0.sourceExisted
            })
        else {
            return
        }
        let secure = try ApplicationRemovalTransactionPaths
            .secureFileSystem(for: entry)
        let stagingRoot = try ApplicationRemovalTransactionPaths
            .stagingRoot(manifest.transactionID)
        if case .present =
            try secure.itemState(at: stagingRoot)
        {
            try secure.removeTree(at: stagingRoot)
        }
    }

    private func boundary(
        _ value: ApplicationRemovalTransactionBoundary
    ) throws {
        try transactionBoundary?(value)
    }
}
