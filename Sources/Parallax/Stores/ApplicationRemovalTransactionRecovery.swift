import Foundation

struct ApplicationRemovalTransactionRecovery {
    let journal: ApplicationRemovalTransactionJournal
    let transactionBoundary:
        (@Sendable (ApplicationRemovalTransactionBoundary) throws -> Void)?
    var identitySource: ApplicationRemovalTransactionIdentitySource =
        ApplicationRemovalTransactionRootIdentity.read

    func repositoryCommittedRemoval(
        _ repository: any LibraryRepositoryPersisting,
        manifest: ApplicationRemovalTransactionManifest
    ) throws -> Bool {
        guard case .loaded(let snapshot) = repository.load() else {
            return false
        }
        guard !snapshot.applications.contains(where: {
            $0.id == manifest.applicationID || $0.storageID == manifest.applicationStorageID
        }) else { return false }
        if manifest.phase == .metadataCommitted {
            return true
        }
        if snapshot.versionToken.revision.rawValue == manifest.targetRevision,
           snapshot.versionToken.primarySHA256 == manifest.targetSHA256 {
            return true
        }
        // A later metadata edit does not undo an already committed removal.
        return snapshot.versionToken.revision.rawValue > manifest.targetRevision
            && !snapshot.applications.contains(where: {
                $0.id == manifest.applicationID
                    || $0.storageID == manifest.applicationStorageID
            })
    }

    func rollback(
        _ manifest: ApplicationRemovalTransactionManifest
    ) throws -> ApplicationRemovalTransactionOutcome {
        for entry in manifest.entries.reversed()
        where entry.sourceExisted {
            let secure = try ApplicationRemovalTransactionPaths
                .secureFileSystem(for: entry, identitySource: identitySource)
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
            let sourceExists = try exists(source, in: secure)
            let stagedExists = try exists(staged, in: secure)
            let archiveExists = try exists(archive, in: secure)
            guard !(stagedExists && archiveExists),
                  !(sourceExists && (stagedExists || archiveExists)) else {
                throw ApplicationRemovalTransactionError(
                    code: .conflictingManagedData
                )
            }
            if sourceExists {
                try verifyIdentity(secure, source, entry: entry)
            } else {
                guard stagedExists || archiveExists else {
                    throw ApplicationRemovalTransactionError(
                        code: .missingManagedData
                    )
                }
                let recoverable = archiveExists ? archive : staged
                try verifyIdentity(secure, recoverable, entry: entry)
                if manifest.dataChoice == .archive, entry.finalizationStarted == true {
                    try verifyFinalizationOwnership(secure, recoverable, entry: entry, manifest: manifest)
                } else {
                    try verifyOwnership(
                        secure,
                        recoverable,
                        transactionID: manifest.transactionID
                    )
                }
                try ApplicationRemovalTransactionFileSystem.preflight(
                    recoverable,
                    in: secure,
                    profileName: entry.profileName ?? entry.profileID.uuidString
                )
                try secure.rename(from: recoverable, to: source)
            }
            let marker = try source.appending(
                ApplicationRemovalTransactionPaths.ownerMarkerName(
                    manifest.transactionID
                )
            )
            if try exists(marker, in: secure) {
                try verifyOwnership(
                    secure,
                    source,
                    transactionID: manifest.transactionID
                )
                try secure.removeTree(at: marker)
            }
        }
        try removeEmptyStagingRoot(manifest)
        return try journal.recordCompletion(
            manifest,
            completion: .rolledBack,
            archiveURLs: [:]
        )
    }

    func preflightFinalization(
        _ manifest: ApplicationRemovalTransactionManifest
    ) throws {
        for entry in manifest.entries where entry.sourceExisted {
            let secure = try ApplicationRemovalTransactionPaths
                .secureFileSystem(for: entry, identitySource: identitySource)
            let path = try manifest.dataChoice == .archive
                ? ApplicationRemovalTransactionPaths.archive(entry)
                : ApplicationRemovalTransactionPaths.staged(
                    entry,
                    transactionID: manifest.transactionID
                )
            try ApplicationRemovalTransactionFileSystem.preflight(
                path,
                in: secure,
                profileName: entry.profileName ?? entry.profileID.uuidString
            )
        }
    }

    func finishCommitted(
        _ original: ApplicationRemovalTransactionManifest
    ) throws -> ApplicationRemovalTransactionOutcome {
        // Before promoting an inferred commit, verify every remaining marker.
        // Otherwise a partial finish could authorize marker-less legacy entries.
        if original.phase != .metadataCommitted {
            for entry in original.entries where entry.sourceExisted {
                let secure = try ApplicationRemovalTransactionPaths
                    .secureFileSystem(for: entry, identitySource: identitySource)
                let directory = try original.dataChoice == .archive
                    ? ApplicationRemovalTransactionPaths.archive(entry)
                    : ApplicationRemovalTransactionPaths.staged(
                        entry,
                        transactionID: original.transactionID
                    )
                guard try exists(directory, in: secure) else {
                    throw ApplicationRemovalTransactionError(code: .missingManagedData)
                }
                try verifyOwnership(
                    secure,
                    directory,
                    transactionID: original.transactionID
                )
            }
        }
        var manifest = original
        manifest.phase = .metadataCommitted
        var archives: [UUID: URL] = [:]
        switch manifest.dataChoice {
        case .keep:
            break
        case .archive:
            for index in manifest.entries.indices
            where manifest.entries[index].sourceExisted {
                let entry = manifest.entries[index]
                let secure = try ApplicationRemovalTransactionPaths
                    .secureFileSystem(for: entry, identitySource: identitySource)
                let staged = try ApplicationRemovalTransactionPaths.staged(
                    entry,
                    transactionID: manifest.transactionID
                )
                let archive = try ApplicationRemovalTransactionPaths.archive(
                    entry
                )
                if try exists(staged, in: secure) {
                    guard try !exists(archive, in: secure) else {
                        throw ApplicationRemovalTransactionError(
                            code: .conflictingManagedData
                        )
                    }
                    try verifyIdentity(secure, staged, entry: entry)
                    try verifyOwnership(
                        secure,
                        staged,
                        transactionID: manifest.transactionID
                    )
                    try secure.rename(from: staged, to: archive)
                }
                guard try exists(archive, in: secure) else {
                    throw ApplicationRemovalTransactionError(
                        code: .missingManagedData
                    )
                }
                try verifyIdentity(secure, archive, entry: entry)
                if entry.finalizationStarted != true {
                    try verifyFinalizationOwnership(
                        secure,
                        archive,
                        entry: entry,
                        manifest: original
                    )
                    manifest.entries[index].finalizationStarted = true
                    try journal.persist(manifest)
                }
                let effect = ApplicationRemovalTransactionEffect
                    .finalizeArchive(entry.profileStorageID, index)
                try boundary(.beforeEffect(effect))
                let marker = try archive.appending(
                    ApplicationRemovalTransactionPaths.ownerMarkerName(
                        manifest.transactionID
                    )
                )
                if try exists(marker, in: secure) {
                    try secure.removeTree(at: marker)
                }
                try boundary(.afterEffectBeforeRecord(effect))
                archives[entry.profileStorageID] = URL(
                    fileURLWithPath: entry.archivePath
                )
                try boundary(.afterRecord(effect))
            }
        case .delete:
            let effect = ApplicationRemovalTransactionEffect.purgeStaging
            try boundary(.beforeEffect(effect))
            for index in manifest.entries.indices
            where manifest.entries[index].sourceExisted {
                let entry = manifest.entries[index]
                let secure = try ApplicationRemovalTransactionPaths
                    .secureFileSystem(for: entry, identitySource: identitySource)
                let staged = try ApplicationRemovalTransactionPaths.staged(
                    entry,
                    transactionID: manifest.transactionID
                )
                let tombstone = try ApplicationRemovalTransactionPaths.tombstone(
                    entry,
                    transactionID: manifest.transactionID
                )
                let stagedExists = try exists(staged, in: secure)
                let tombstoneExists = try exists(tombstone, in: secure)
                guard !(stagedExists && tombstoneExists) else {
                    throw ApplicationRemovalTransactionError(
                        code: .conflictingManagedData
                    )
                }
                if stagedExists {
                    try verifyIdentity(secure, staged, entry: entry)
                    try verifyFinalizationOwnership(
                        secure,
                        staged,
                        entry: entry,
                        manifest: original
                    )
                    manifest.entries[index].finalizationStarted = true
                    try journal.persist(manifest)
                    let publication = ApplicationRemovalTransactionEffect
                        .publishTombstone(entry.profileStorageID, index)
                    try boundary(.beforeEffect(publication))
                    try secure.rename(from: staged, to: tombstone)
                    try boundary(.afterEffectBeforeRecord(publication))
                    try boundary(.afterRecord(publication))
                } else if entry.finalizationStarted != true {
                    // Older committed journals could purge an entire entry
                    // before recording completion. Tombstones are newer.
                    guard !tombstoneExists,
                          entry.baseRootInode == nil,
                          original.phase == .metadataCommitted else {
                        throw ApplicationRemovalTransactionError(
                            code: tombstoneExists ? .unownedStagedData : .missingStagedData
                        )
                    }
                    continue
                }
                if try exists(tombstone, in: secure) {
                    try verifyIdentity(secure, tombstone, entry: entry)
                    for name in try ApplicationRemovalTransactionFileSystem.children(
                        of: tombstone,
                        in: secure
                    ) {
                        let childEffect = ApplicationRemovalTransactionEffect
                            .purgeChild(entry.profileStorageID, name)
                        try boundary(.beforeEffect(childEffect))
                        try secure.removeTree(at: tombstone.appending(name))
                        try boundary(.afterEffectBeforeRecord(childEffect))
                        try boundary(.afterRecord(childEffect))
                    }
                    try secure.removeTree(at: tombstone)
                }
            }
            try removeEmptyStagingRoot(manifest)
            try boundary(.afterEffectBeforeRecord(effect))
            try boundary(.afterRecord(effect))
        }
        try removeEmptyStagingRoot(manifest)
        return try journal.recordCompletion(
            manifest,
            completion: .committed,
            archiveURLs: archives
        )
    }

    private func exists(
        _ path: SecureManagedPath,
        in secure: SecureManagedFileSystem
    ) throws -> Bool {
        if case .present = try secure.itemState(at: path) {
            return true
        }
        return false
    }

    private func verifyIdentity(
        _ secure: SecureManagedFileSystem,
        _ directory: SecureManagedPath,
        entry: ApplicationRemovalTransactionEntry
    ) throws {
        guard case .present(let identity) = try secure.itemState(at: directory),
              identity.kind == .directory,
              entry.baseRootInode == nil
                || (entry.expectedInode.map({ $0 == identity.fileID }) ?? true) else {
            throw ApplicationRemovalTransactionError(code: .targetChanged)
        }
    }

    private func verifyFinalizationOwnership(
        _ secure: SecureManagedFileSystem,
        _ directory: SecureManagedPath,
        entry: ApplicationRemovalTransactionEntry,
        manifest: ApplicationRemovalTransactionManifest
    ) throws {
        let marker = try directory.appending(
            ApplicationRemovalTransactionPaths.ownerMarkerName(
                manifest.transactionID
            )
        )
        if try !exists(marker, in: secure),
           manifest.phase == .metadataCommitted,
           entry.finalizationStarted == true || entry.baseRootInode == nil,
           case .present(let identity) = try secure.itemState(at: directory),
           entry.expectedInode == identity.fileID {
            // Marker-less finalization needs both a committed journal and
            // the original directory, including for older journals.
            return
        }
        try verifyOwnership(
            secure,
            directory,
            transactionID: manifest.transactionID
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
        let marker = try directory.appending(markerName)
        guard try exists(marker, in: secure) else {
            throw ApplicationRemovalTransactionError(code: .unownedStagedData)
        }
        let manifest = try secure.manifest(at: marker)
        guard manifest.entries.contains(where: {
            $0.relativeComponents.isEmpty
                && $0.kind == .regularFile
                && $0.sha256 == expectedHash
        })
        else {
            throw ApplicationRemovalTransactionError(
                code: .unownedStagedData
            )
        }
    }

    private func removeEmptyStagingRoot(
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
            .secureFileSystem(for: entry, identitySource: identitySource)
        let stagingRoot = try ApplicationRemovalTransactionPaths
            .stagingRoot(manifest.transactionID)
        if try exists(stagingRoot, in: secure) {
            let children = try ApplicationRemovalTransactionFileSystem.children(
                of: stagingRoot,
                in: secure
            )
            for name in children {
                guard name == ".DS_Store" || name.hasPrefix("._"),
                      case .present(let identity) = try secure.itemState(at: stagingRoot.appending(name)),
                      identity.kind == .regularFile else {
                    throw ApplicationRemovalTransactionError(code: .unownedStagedData)
                }
            }
            // Finder metadata is benign, but never authorize deleting an
            // unexpected directory or following a link with a metadata name.
            try secure.removeTree(at: stagingRoot)
        }
    }

    private func boundary(
        _ value: ApplicationRemovalTransactionBoundary
    ) throws {
        try transactionBoundary?(value)
    }
}
