import Darwin
import Foundation

/// Prepares and executes an application-wide managed-storage relocation.
///
/// Application and archive namespaces move together. Explicit isolation paths
/// are metadata owned by the user and are never copied or rewritten here.
struct StorageRelocationCoordinator: @unchecked Sendable {
    private static let controlComponents = [
        "Parallax",
        "StorageRelocations",
    ]

    private let fileSystem: any FileSystem
    private let pathResolver: ManagedPathResolver
    private let activityProvider: any StorageRelocationActivityProviding
    private let capacityProvider: (URL) -> UInt64?
    private let makeTransactionID: () -> UUID
    private let now: () -> Date
    private let transactionBoundary:
        (@Sendable (StorageRelocationBoundary) throws -> Void)?
    private let controlRootURL: URL
    private let controlRootIdentity: FileSystemObjectIdentity
    private let control: SecureManagedFileSystem
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        applicationSupportURL: URL,
        fileSystem: any FileSystem,
        pathResolver: ManagedPathResolver? = nil,
        activityProvider: any StorageRelocationActivityProviding,
        availableCapacity: ((URL) -> UInt64?)? = nil,
        transactionID: @escaping () -> UUID = UUID.init,
        now: @escaping () -> Date = Date.init,
        transactionBoundary:
            (@Sendable (StorageRelocationBoundary) throws -> Void)? = nil
    ) throws {
        self.fileSystem = fileSystem
        self.pathResolver = pathResolver ?? ManagedPathResolver(fileSystem: fileSystem)
        self.activityProvider = activityProvider
        capacityProvider = availableCapacity ?? Self.systemAvailableCapacity
        self.makeTransactionID = transactionID
        self.now = now
        self.transactionBoundary = transactionBoundary
        control = try SecureManagedFileSystem(
            anchorURL: applicationSupportURL,
            rootComponents: Self.controlComponents,
            createIfMissing: true
        )
        controlRootURL = Self.controlComponents.reduce(
            applicationSupportURL
        ) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        let controlAttributes = try fileSystem.attributesOfItem(
            at: controlRootURL
        )
        guard
            controlAttributes.kind == .directory,
            let controlIdentity = controlAttributes.identity
        else {
            throw StorageRelocationError(
                .invalidJournal,
                path: controlRootURL.path
            )
        }
        try fileSystem.setPOSIXPermissions(0o700, at: controlRootURL)
        controlRootIdentity = controlIdentity
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func pendingRelocations() throws -> [PendingStorageRelocation] {
        try validateControlRoot()
        let entries = try fileSystem.contentsOfDirectory(at: controlRootURL)
        let planSuffix = ".plan.json"
        var pending: [PendingStorageRelocation] = []
        var planIDs = Set<UUID>()
        for entry in entries
            .filter({ $0.lastPathComponent.hasSuffix(planSuffix) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let rawID = String(
                entry.lastPathComponent.dropLast(planSuffix.count)
            )
            guard
                let transactionID = UUID(uuidString: rawID),
                transactionID.uuidString.lowercased() == rawID
            else {
                throw StorageRelocationError(
                    .invalidJournal,
                    path: entry.path
                )
            }
            planIDs.insert(transactionID)
            let plan = try loadControlPlan(transactionID)
            if try loadControlReceiptIfPresent(plan: plan) != nil {
                continue
            }
            pending.append(
                PendingStorageRelocation(
                    transactionID: transactionID,
                    applicationID: plan.unsigned.applicationID,
                    applicationStorageID:
                        plan.unsigned.applicationStorageID,
                    sourceBasePath: plan.unsigned.sourceBasePath,
                    destinationBasePath:
                        plan.unsigned.destinationBasePath,
                    createdAt: plan.unsigned.createdAt
                )
            )
        }
        for entry in entries where
            entry.lastPathComponent.hasSuffix(".receipt.json") {
            let rawID = String(
                entry.lastPathComponent.dropLast(".receipt.json".count)
            )
            guard
                let transactionID = UUID(uuidString: rawID),
                transactionID.uuidString.lowercased() == rawID,
                planIDs.contains(transactionID)
            else {
                throw StorageRelocationError(
                    .invalidJournal,
                    path: entry.path
                )
            }
        }
        try validateControlRoot()
        return pending.sorted {
            if $0.createdAt == $1.createdAt {
                return $0.transactionID.uuidString
                    < $1.transactionID.uuidString
            }
            return $0.createdAt < $1.createdAt
        }
    }

    func recoverAll(
        repository: any LibraryRepositoryPersisting
    ) throws -> [StorageRelocationRecoveryOutcome] {
        try pendingRelocations().map {
            try recover(
                transactionID: $0.transactionID,
                repository: repository
            )
        }
    }

    func recover(
        transactionID: UUID,
        repository: any LibraryRepositoryPersisting
    ) throws -> StorageRelocationRecoveryOutcome {
        let plan = try loadControlPlan(transactionID)
        if let receipt = try loadControlReceiptIfPresent(plan: plan) {
            return try completedOutcome(
                receipt: receipt,
                plan: plan,
                repository: repository
            )
        }
        let source = try pathResolver.resolveApplication(
            configuredBaseRoot: plan.unsigned.sourceBasePath,
            applicationStorageID: plan.unsigned.applicationStorageID
        )
        let destination = try pathResolver.resolveApplication(
            configuredBaseRoot: plan.unsigned.destinationBasePath,
            applicationStorageID: plan.unsigned.applicationStorageID
        )
        guard
            source.canonicalBaseRootURL.path
                == plan.unsigned.sourceBasePath,
            destination.canonicalBaseRootURL.path
                == plan.unsigned.destinationBasePath
        else {
            throw StorageRelocationError(.invalidJournal)
        }
        let libraryOutcome = repository.load()
        let primary = classifyLibrary(
            libraryOutcome,
            prior: plan.unsigned.priorVersion.libraryToken,
            target: plan.unsigned.targetVersion.libraryToken
        )
        let application = try recoveryApplication(
            libraryOutcome,
            primary: primary,
            plan: plan
        )
        let destinationStaging = destination.stagingRoot(
            transactionID: transactionID
        )
        let stagedApplication = child(
            "Application",
            in: destinationStaging
        )
        let stagedArchives = child("Archives", in: destinationStaging)

        switch primary {
        case .target:
            try requireRecoveryCopy(
                destination.applicationRoot,
                snapshot: plan.unsigned.sourceApplicationSnapshot
            )
            try requireRecoveryCopy(
                destination.applicationArchiveRoot,
                snapshot: plan.unsigned.sourceArchiveSnapshot
            )
            try removeOriginalOwned(
                source.applicationRoot,
                snapshot: plan.unsigned.sourceApplicationSnapshot,
                allowMissing: true
            )
            try removeOriginalOwned(
                source.applicationArchiveRoot,
                snapshot: plan.unsigned.sourceArchiveSnapshot,
                allowMissing: true
            )
            try removeIfPresent(destinationStaging)
            let receiptURL = try writeControlReceipt(
                plan: plan,
                completion: .committed
            )
            return .committed(
                StorageRelocationOutcome(
                    transactionID: transactionID,
                    application: application,
                    versionToken: plan.unsigned.targetVersion.libraryToken,
                    receiptURL: receiptURL
                )
            )
        case .prior:
            try requireOriginalOwned(
                source.applicationRoot,
                snapshot: plan.unsigned.sourceApplicationSnapshot
            )
            try requireOriginalOwned(
                source.applicationArchiveRoot,
                snapshot: plan.unsigned.sourceArchiveSnapshot
            )
            try removeRecoveryCopyIfPresent(
                destination.applicationRoot,
                snapshot: plan.unsigned.sourceApplicationSnapshot
            )
            try removeRecoveryCopyIfPresent(
                destination.applicationArchiveRoot,
                snapshot: plan.unsigned.sourceArchiveSnapshot
            )
            try removeRecoveryCopyIfPresent(
                stagedApplication,
                snapshot: plan.unsigned.sourceApplicationSnapshot
            )
            try removeRecoveryCopyIfPresent(
                stagedArchives,
                snapshot: plan.unsigned.sourceArchiveSnapshot
            )
            try removeIfPresent(destinationStaging)
            _ = try writeControlReceipt(
                plan: plan,
                completion: .rolledBack
            )
            return .rolledBack
        case .neither:
            throw StorageRelocationError(
                .ambiguousLibraryState,
                path: controlURL(
                    for: try controlPlanPath(transactionID)
                ).path
            )
        }
    }

    private func makeControlPlan(
        preview: StorageRelocationPreview,
        preparedCommit: PreparedLibraryCommit
    ) throws -> StorageRelocationControlPlan {
        let unsigned = StorageRelocationControlPlan.Unsigned(
            version: 1,
            transactionID: preview.requestID,
            applicationID: preview.applicationID,
            applicationStorageID: preview.applicationStorageID,
            createdAt: now(),
            priorVersion: StorageRelocationVersionToken(
                preparedCommit.priorVersion
            ),
            targetVersion: StorageRelocationVersionToken(
                preparedCommit.targetVersion
            ),
            originalApplicationSHA256: try applicationSHA256(
                preview.originalApplication
            ),
            relocatedApplicationSHA256: try applicationSHA256(
                preview.relocatedApplication
            ),
            sourceBasePath: preview.source.canonicalBaseRootURL.path,
            destinationBasePath:
                preview.destination.canonicalBaseRootURL.path,
            sourceApplicationFingerprint:
                preview.sourceApplicationFingerprint,
            sourceArchiveFingerprint:
                preview.sourceArchiveFingerprint,
            sourceApplicationSnapshot:
                preview.sourceApplicationSnapshot,
            sourceArchiveSnapshot: preview.sourceArchiveSnapshot
        )
        return StorageRelocationControlPlan(
            unsigned: unsigned,
            planSHA256: LibraryPersistence.sha256(
                try canonicalBytes(unsigned)
            )
        )
    }

    private func writeControlPlan(
        _ plan: StorageRelocationControlPlan
    ) throws {
        try validateControlRoot()
        let path = try controlPlanPath(plan.unsigned.transactionID)
        guard
            try control.itemState(at: path) == .missing,
            try control.itemState(
                at: controlReceiptPath(plan.unsigned.transactionID)
            ) == .missing
        else {
            throw StorageRelocationError(
                .unexpectedDestination,
                path: controlURL(for: path).path
            )
        }
        try control.write(try canonicalBytes(plan), to: path)
        _ = try loadControlPlan(plan.unsigned.transactionID)
    }

    @discardableResult
    private func writeControlReceipt(
        plan: StorageRelocationControlPlan,
        completion: StorageRelocationControlCompletion
    ) throws -> URL {
        try transactionBoundary?(
            .beforeCompletionReceipt(plan.unsigned.transactionID)
        )
        let unsigned = StorageRelocationControlReceipt.Unsigned(
            version: 1,
            transactionID: plan.unsigned.transactionID,
            planSHA256: plan.planSHA256,
            completion: completion,
            completedAt: now(),
            priorVersion: plan.unsigned.priorVersion,
            targetVersion: plan.unsigned.targetVersion
        )
        let receipt = StorageRelocationControlReceipt(
            unsigned: unsigned,
            receiptSHA256: LibraryPersistence.sha256(
                try canonicalBytes(unsigned)
            )
        )
        let path = try controlReceiptPath(plan.unsigned.transactionID)
        guard try control.itemState(at: path) == .missing else {
            if let existing = try loadControlReceiptIfPresent(plan: plan),
               existing.unsigned.completion == completion {
                return controlURL(for: path)
            }
            throw StorageRelocationError(
                .invalidReceipt,
                path: controlURL(for: path).path
            )
        }
        try control.write(try canonicalBytes(receipt), to: path)
        guard
            let validated = try loadControlReceiptIfPresent(plan: plan),
            validated.unsigned.completion == completion,
            validated.unsigned.transactionID
                == receipt.unsigned.transactionID,
            validated.receiptSHA256 == receipt.receiptSHA256
        else {
            throw StorageRelocationError(
                .invalidReceipt,
                path: controlURL(for: path).path
            )
        }
        return controlURL(for: path)
    }

    func prepare(
        application: ManagedApplication,
        destinationBaseRoot: String,
        expectedVersion: LibraryVersionToken
    ) throws -> StorageRelocationPreview {
        let source = try pathResolver.resolveApplication(
            configuredBaseRoot: configuredBaseRoot(for: application),
            applicationStorageID: application.storageID
        )
        let destination = try pathResolver.resolveApplication(
            configuredBaseRoot: destinationBaseRoot,
            applicationStorageID: application.storageID
        )
        let sourceEstimate = try estimateApplicationStorage(source)
        let destinationAvailableBytes = availableCapacity(
            at: destination.applicationRoot.validationContext.identityAnchorURL
        )
        let strategy: StorageRelocationStrategy =
            source.applicationRoot.validationContext.identityAnchor.volumeID
                == destination.applicationRoot.validationContext.identityAnchor.volumeID
            ? .sameVolume
            : .crossVolume
        let rewrite = try relocatedApplication(
            application,
            sourceBaseRoot: source.canonicalBaseRootURL.path,
            destinationBaseRoot: destination.canonicalBaseRootURL.path
        )

        var blockers: [StorageRelocationBlocker] = []
        if source.canonicalBaseRootURL.standardizedFileURL
            == destination.canonicalBaseRootURL.standardizedFileURL {
            blockers.append(.sameStorageLocation)
        }
        if pathsOverlap(
            source.applicationRoot.url,
            destination.applicationRoot.url
        ) || pathsOverlap(
            source.applicationArchiveRoot.url,
            destination.applicationArchiveRoot.url
        ) {
            blockers.append(.overlappingStorageLocations)
        }
        if fileSystem.fileExists(at: destination.applicationRoot.url)
            || fileSystem.fileExists(at: destination.applicationArchiveRoot.url) {
            blockers.append(.unexpectedDestination)
        }
        if sourceEstimate.allocatedBytes > 0 {
            if let destinationAvailableBytes {
                if destinationAvailableBytes < sourceEstimate.allocatedBytes {
                    blockers.append(
                        .insufficientSpace(
                            required: sourceEstimate.allocatedBytes,
                            available: destinationAvailableBytes
                        )
                    )
                }
            } else {
                blockers.append(.capacityUnavailable)
            }
        }
        let active = activeProfileIDs(in: application)
        if !active.isEmpty {
            blockers.append(.activeProfiles(active))
        }

        return StorageRelocationPreview(
            requestID: makeTransactionID(),
            applicationID: application.id,
            applicationStorageID: application.storageID,
            expectedVersion: expectedVersion,
            originalApplication: application,
            relocatedApplication: rewrite.application,
            source: source,
            destination: destination,
            sourceEstimate: sourceEstimate,
            sourceApplicationFingerprint: try fingerprintIfPresent(
                source.applicationRoot
            ),
            sourceArchiveFingerprint: try fingerprintIfPresent(
                source.applicationArchiveRoot
            ),
            sourceApplicationSnapshot: try ownedSnapshotIfPresent(
                source.applicationRoot
            ),
            sourceArchiveSnapshot: try ownedSnapshotIfPresent(
                source.applicationArchiveRoot
            ),
            destinationAvailableBytes: destinationAvailableBytes,
            strategy: strategy,
            generatedRewrites: rewrite.generated,
            preservedExternalPaths: rewrite.external,
            blockers: blockers
        )
    }

    func execute(
        _ preview: StorageRelocationPreview,
        preparedCommit: PreparedLibraryCommit,
        repository: any LibraryRepositoryPersisting,
        cancellation: StorageRelocationCancellation = StorageRelocationCancellation(),
        progress: ((StorageRelocationProgress) -> Void)? = nil
    ) throws -> StorageRelocationOutcome {
        guard preview.blockers.isEmpty else {
            throw StorageRelocationError(.blocked)
        }
        guard
            preparedCommit.priorVersion == preview.expectedVersion,
            preview.expectedVersion.revision.rawValue < UInt64.max,
            preparedCommit.targetVersion.revision.rawValue
                == preview.expectedVersion.revision.rawValue + 1,
            preparedCommit.targetVersion.primarySHA256
                == LibraryPersistence.sha256(preparedCommit.targetBytes)
        else {
            throw StorageRelocationError(.stalePreview)
        }
        guard activeProfileIDs(in: preview.originalApplication).isEmpty else {
            throw StorageRelocationError(.activeProfile)
        }
        try checkCancellation(cancellation)
        progress?(.preparing)
        let plan = try makeControlPlan(
            preview: preview,
            preparedCommit: preparedCommit
        )

        do {
            return try repository.withExclusiveMutation(
                expectedVersion: preview.expectedVersion
            ) { capability in
                let currentApplication = try validatePreparedTransition(
                    preview: preview,
                    preparedCommit: preparedCommit,
                    currentApplications: capability.applications
                )
                guard activeProfileIDs(in: currentApplication).isEmpty else {
                    throw StorageRelocationError(.activeProfile)
                }
                try checkCancellation(cancellation)

                let source = try pathResolver.resolveApplication(
                    configuredBaseRoot: configuredBaseRoot(
                        for: currentApplication
                    ),
                    applicationStorageID: currentApplication.storageID
                )
                let destination = try pathResolver.resolveApplication(
                    configuredBaseRoot:
                        preview.destination.canonicalBaseRootURL.path,
                    applicationStorageID: currentApplication.storageID
                )
                guard
                    source.applicationRoot.url
                        == preview.source.applicationRoot.url,
                    source.applicationArchiveRoot.url
                        == preview.source.applicationArchiveRoot.url,
                    destination.applicationRoot.url
                        == preview.destination.applicationRoot.url,
                    destination.applicationArchiveRoot.url
                        == preview.destination.applicationArchiveRoot.url,
                    try estimateApplicationStorage(source)
                        == preview.sourceEstimate,
                    try fingerprintIfPresent(source.applicationRoot)
                        == preview.sourceApplicationFingerprint,
                    try fingerprintIfPresent(source.applicationArchiveRoot)
                        == preview.sourceArchiveFingerprint,
                    try ownedSnapshotIfPresent(source.applicationRoot)
                        == preview.sourceApplicationSnapshot,
                    try ownedSnapshotIfPresent(
                        source.applicationArchiveRoot
                    ) == preview.sourceArchiveSnapshot
                else {
                    throw StorageRelocationError(.sourceChanged)
                }
                try requireDestinationAbsent(destination)
                guard activeProfileIDs(in: currentApplication).isEmpty else {
                    throw StorageRelocationError(.activeProfile)
                }
                try writeControlPlan(plan)
                do {
                    try transactionBoundary?(
                        .afterPlanDurable(preview.requestID)
                    )
                } catch {
                    throw StorageRelocationError(
                        .rollbackRequired,
                        path: controlURL(
                            for: try controlPlanPath(preview.requestID)
                        ).path,
                        detail: error.localizedDescription
                    )
                }

                let transactionID = preview.requestID
                let destinationStaging = destination.stagingRoot(
                    transactionID: transactionID
                )
                let stagedApplication = child(
                    "Application",
                    in: destinationStaging
                )
                let stagedArchives = child(
                    "Archives",
                    in: destinationStaging
                )
                var applicationStaged = false
                var archivesStaged = false
                var applicationPublished = false
                var archivesPublished = false
                var commitState = LibraryCommitPrimaryState.prior

                do {
                    try createDirectory(destinationStaging)

                    if exists(source.applicationRoot) {
                        progress?(.stagingApplication)
                        try copy(
                            source.applicationRoot,
                            to: stagedApplication
                        )
                        applicationStaged = true
                        try checkCancellation(cancellation)
                    }
                    if exists(source.applicationArchiveRoot) {
                        progress?(.stagingArchives)
                        try copy(
                            source.applicationArchiveRoot,
                            to: stagedArchives
                        )
                        archivesStaged = true
                        try checkCancellation(cancellation)
                    }
                    try transactionBoundary?(
                        .afterStaging(transactionID)
                    )
                    try checkCancellation(cancellation)

                    if applicationStaged {
                        try requireFingerprint(
                            stagedApplication,
                            expected: preview.sourceApplicationFingerprint
                        )
                        progress?(.publishingApplication)
                        try move(
                            stagedApplication,
                            to: destination.applicationRoot
                        )
                        applicationPublished = true
                        applicationStaged = false
                    }
                    if archivesStaged {
                        try requireFingerprint(
                            stagedArchives,
                            expected: preview.sourceArchiveFingerprint
                        )
                        progress?(.publishingArchives)
                        try move(
                            stagedArchives,
                            to: destination.applicationArchiveRoot
                        )
                        archivesPublished = true
                        archivesStaged = false
                    }
                    try checkCancellation(cancellation)
                    guard
                        activeProfileIDs(in: currentApplication).isEmpty
                    else {
                        throw StorageRelocationError(.activeProfile)
                    }

                    progress?(.committingMetadata)
                    guard
                        try fingerprintIfPresent(source.applicationRoot)
                            == preview.sourceApplicationFingerprint,
                        try fingerprintIfPresent(
                            source.applicationArchiveRoot
                        ) == preview.sourceArchiveFingerprint
                    else {
                        throw StorageRelocationError(.sourceChanged)
                    }
                    do {
                        let result = try capability.commit(
                            preparedCommit,
                            backupReason: .destructiveRewrite
                        )
                        commitState = result.primaryState
                    } catch let repositoryError as LibraryRepositoryError {
                        if case let .commitFailed(state, _) = repositoryError {
                            commitState = state
                        }
                        throw repositoryError
                    }
                    guard commitState == .target else {
                        throw StorageRelocationError(
                            .metadataCommitFailed
                        )
                    }
                    progress?(.cleaningSource)
                    try removeOriginalOwned(
                        source.applicationRoot,
                        snapshot: preview.sourceApplicationSnapshot
                    )
                    try removeOriginalOwned(
                        source.applicationArchiveRoot,
                        snapshot: preview.sourceArchiveSnapshot
                    )

                    try removeIfPresent(destinationStaging)
                    let receiptURL = try writeControlReceipt(
                        plan: plan,
                        completion: .committed
                    )
                    progress?(.completed)
                    return StorageRelocationOutcome(
                        transactionID: transactionID,
                        application: preview.relocatedApplication,
                        versionToken: preparedCommit.targetVersion,
                        receiptURL: receiptURL
                    )
                } catch {
                    if commitState == .target {
                        throw StorageRelocationError(
                            .rollbackRequired,
                            path: controlURL(
                                for: try controlPlanPath(transactionID)
                            ).path,
                            detail: error.localizedDescription
                        )
                    }
                    if commitState == .neither {
                        throw StorageRelocationError(
                            .ambiguousLibraryState,
                            path: controlURL(
                                for: try controlPlanPath(transactionID)
                            ).path,
                            detail: error.localizedDescription
                        )
                    }

                    progress?(.rollingBack)
                    do {
                        if applicationPublished {
                            try removePublishedIfUnchanged(
                                destination.applicationRoot,
                                expected:
                                    preview.sourceApplicationFingerprint
                            )
                            applicationPublished = false
                        }
                        if archivesPublished {
                            try removePublishedIfUnchanged(
                                destination.applicationArchiveRoot,
                                expected: preview.sourceArchiveFingerprint
                            )
                            archivesPublished = false
                        }
                        if applicationStaged {
                            try removePublishedIfUnchanged(
                                stagedApplication,
                                expected:
                                    preview.sourceApplicationFingerprint
                            )
                            applicationStaged = false
                        }
                        if archivesStaged {
                            try removePublishedIfUnchanged(
                                stagedArchives,
                                expected: preview.sourceArchiveFingerprint
                            )
                            archivesStaged = false
                        }
                        try removeIfPresent(destinationStaging)
                        _ = try writeControlReceipt(
                            plan: plan,
                            completion: .rolledBack
                        )
                    } catch let rollbackError {
                        throw StorageRelocationError(
                            .rollbackRequired,
                            path: controlURL(
                                for: try controlPlanPath(transactionID)
                            ).path,
                            detail: rollbackError.localizedDescription
                        )
                    }
                    if error is LibraryRepositoryError {
                        throw StorageRelocationError(
                            .metadataCommitFailed,
                            detail: error.localizedDescription
                        )
                    }
                    throw error
                }
            }
        } catch LibraryRepositoryError.staleWriter {
            throw StorageRelocationError(.stalePreview)
        } catch LibraryRepositoryError.preparedVersionMismatch {
            throw StorageRelocationError(.stalePreview)
        } catch LibraryRepositoryError.mutationSessionExpired {
            throw StorageRelocationError(.stalePreview)
        } catch LibraryRepositoryError.mutationAlreadyPublished {
            throw StorageRelocationError(.stalePreview)
        }
    }

    private func validatePreparedTransition(
        preview: StorageRelocationPreview,
        preparedCommit: PreparedLibraryCommit,
        currentApplications: [ManagedApplication]
    ) throws -> ManagedApplication {
        guard
            let index = currentApplications.firstIndex(where: {
                $0.id == preview.applicationID
            }),
            currentApplications.filter({
                $0.id == preview.applicationID
            }).count == 1,
            currentApplications[index] == preview.originalApplication,
            currentApplications[index].storageID
                == preview.applicationStorageID
        else {
            throw StorageRelocationError(.stalePreview)
        }
        var expectedApplications = currentApplications
        expectedApplications[index] = preview.relocatedApplication
        guard preparedCommit.applications == expectedApplications else {
            throw StorageRelocationError(.stalePreview)
        }
        return currentApplications[index]
    }

    private func loadControlPlan(
        _ transactionID: UUID
    ) throws -> StorageRelocationControlPlan {
        let path = try controlPlanPath(transactionID)
        guard try control.itemState(at: path) != .missing else {
            throw StorageRelocationError(
                .transactionNotFound,
                path: controlURL(for: path).path
            )
        }
        let bytes = try readControlFile(path)
        let plan: StorageRelocationControlPlan
        do {
            plan = try decoder.decode(
                StorageRelocationControlPlan.self,
                from: bytes
            )
        } catch {
            throw StorageRelocationError(
                .invalidJournal,
                path: controlURL(for: path).path,
                detail: error.localizedDescription
            )
        }
        guard
            try canonicalBytes(plan) == bytes,
            plan.unsigned.version == 1,
            plan.unsigned.transactionID == transactionID,
            plan.planSHA256 == LibraryPersistence.sha256(
                try canonicalBytes(plan.unsigned)
            ),
            plan.unsigned.priorVersion.revision.rawValue < UInt64.max,
            plan.unsigned.targetVersion.revision.rawValue
                == plan.unsigned.priorVersion.revision.rawValue + 1,
            plan.unsigned.targetVersion.primarySHA256 != nil,
            plan.unsigned.sourceBasePath.hasPrefix("/"),
            !plan.unsigned.sourceBasePath.contains("\0"),
            plan.unsigned.destinationBasePath.hasPrefix("/"),
            !plan.unsigned.destinationBasePath.contains("\0"),
            (plan.unsigned.sourceApplicationFingerprint == nil)
                == (plan.unsigned.sourceApplicationSnapshot == nil),
            (plan.unsigned.sourceArchiveFingerprint == nil)
                == (plan.unsigned.sourceArchiveSnapshot == nil),
            (plan.unsigned.sourceApplicationFingerprint?.count ?? 64)
                == 64,
            (plan.unsigned.sourceArchiveFingerprint?.count ?? 64)
                == 64,
            snapshotsAreValid(plan)
        else {
            throw StorageRelocationError(
                .invalidJournal,
                path: controlURL(for: path).path
            )
        }
        return plan
    }

    private func loadControlReceiptIfPresent(
        plan: StorageRelocationControlPlan
    ) throws -> StorageRelocationControlReceipt? {
        let path = try controlReceiptPath(plan.unsigned.transactionID)
        guard try control.itemState(at: path) != .missing else {
            return nil
        }
        let bytes = try readControlFile(path)
        let receipt: StorageRelocationControlReceipt
        do {
            receipt = try decoder.decode(
                StorageRelocationControlReceipt.self,
                from: bytes
            )
        } catch {
            throw StorageRelocationError(
                .invalidReceipt,
                path: controlURL(for: path).path,
                detail: error.localizedDescription
            )
        }
        guard
            try canonicalBytes(receipt) == bytes,
            receipt.unsigned.version == 1,
            receipt.unsigned.transactionID
                == plan.unsigned.transactionID,
            receipt.unsigned.planSHA256 == plan.planSHA256,
            receipt.unsigned.priorVersion == plan.unsigned.priorVersion,
            receipt.unsigned.targetVersion == plan.unsigned.targetVersion,
            receipt.receiptSHA256 == LibraryPersistence.sha256(
                try canonicalBytes(receipt.unsigned)
            )
        else {
            throw StorageRelocationError(
                .invalidReceipt,
                path: controlURL(for: path).path
            )
        }
        return receipt
    }

    private func completedOutcome(
        receipt: StorageRelocationControlReceipt,
        plan: StorageRelocationControlPlan,
        repository: any LibraryRepositoryPersisting
    ) throws -> StorageRelocationRecoveryOutcome {
        let libraryOutcome = repository.load()
        let primary = classifyLibrary(
            libraryOutcome,
            prior: plan.unsigned.priorVersion.libraryToken,
            target: plan.unsigned.targetVersion.libraryToken
        )
        let application = try recoveryApplication(
            libraryOutcome,
            primary: primary,
            plan: plan
        )
        switch receipt.unsigned.completion {
        case .committed:
            guard primary == .target else {
                throw StorageRelocationError(.ambiguousLibraryState)
            }
            return .committed(
                StorageRelocationOutcome(
                    transactionID: plan.unsigned.transactionID,
                    application: application,
                    versionToken:
                        plan.unsigned.targetVersion.libraryToken,
                    receiptURL: controlURL(
                        for: try controlReceiptPath(
                            plan.unsigned.transactionID
                        )
                    )
                )
            )
        case .rolledBack:
            guard primary == .prior else {
                throw StorageRelocationError(.ambiguousLibraryState)
            }
            return .rolledBack
        }
    }

    private func recoveryApplication(
        _ outcome: LibraryRepositoryLoadOutcome,
        primary: LibraryCommitPrimaryState,
        plan: StorageRelocationControlPlan
    ) throws -> ManagedApplication {
        guard
            primary != .neither,
            case let .loaded(snapshot) = outcome
        else {
            throw StorageRelocationError(
                .ambiguousLibraryState,
                path: controlURL(
                    for: try controlPlanPath(
                        plan.unsigned.transactionID
                    )
                ).path
            )
        }
        let applications = snapshot.applications.filter {
            $0.id == plan.unsigned.applicationID
        }
        guard
            applications.count == 1,
            applications[0].storageID
                == plan.unsigned.applicationStorageID
        else {
            throw StorageRelocationError(.ambiguousLibraryState)
        }
        let expectedHash = primary == .target
            ? plan.unsigned.relocatedApplicationSHA256
            : plan.unsigned.originalApplicationSHA256
        guard try applicationSHA256(applications[0]) == expectedHash else {
            throw StorageRelocationError(.ambiguousLibraryState)
        }
        return applications[0]
    }

    private func snapshotsAreValid(
        _ plan: StorageRelocationControlPlan
    ) -> Bool {
        [
            plan.unsigned.sourceApplicationSnapshot,
            plan.unsigned.sourceArchiveSnapshot,
        ].compactMap { $0 }.allSatisfy { snapshot in
            StorageRelocationSecureConversions.identity(
                snapshot.identity
            ) != nil
                && StorageRelocationSecureConversions.manifest(
                    snapshot.manifest
                ) != nil
        }
    }

    private func applicationSHA256(
        _ application: ManagedApplication
    ) throws -> String {
        LibraryPersistence.sha256(
            try canonicalBytes(application)
        )
    }

    private func canonicalBytes<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    private func controlPlanPath(
        _ transactionID: UUID
    ) throws -> SecureManagedPath {
        try SecureManagedPath([
            transactionID.uuidString.lowercased() + ".plan.json",
        ])
    }

    private func controlReceiptPath(
        _ transactionID: UUID
    ) throws -> SecureManagedPath {
        try SecureManagedPath([
            transactionID.uuidString.lowercased() + ".receipt.json",
        ])
    }

    private func controlURL(for path: SecureManagedPath) -> URL {
        path.components.reduce(controlRootURL) {
            $0.appendingPathComponent($1, isDirectory: false)
        }
    }

    private func validateControlRoot() throws {
        let attributes = try fileSystem.attributesOfItem(
            at: controlRootURL
        )
        guard
            attributes.kind == .directory,
            attributes.identity == controlRootIdentity
        else {
            throw StorageRelocationError(
                .invalidJournal,
                path: controlRootURL.path
            )
        }
    }

    private func readControlFile(
        _ path: SecureManagedPath
    ) throws -> Data {
        try validateControlRoot()
        var descriptor = open(
            controlRootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw StorageRelocationError(
                .invalidJournal,
                path: controlRootURL.path
            )
        }
        defer { close(descriptor) }
        var rootStatus = stat()
        guard
            fstat(descriptor, &rootStatus) == 0,
            UInt64(rootStatus.st_dev) == controlRootIdentity.volumeID,
            UInt64(rootStatus.st_ino) == controlRootIdentity.fileID
        else {
            throw StorageRelocationError(
                .invalidJournal,
                path: controlRootURL.path
            )
        }
        for component in path.components.dropLast() {
            let next = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                throw StorageRelocationError(.invalidJournal)
            }
            close(descriptor)
            descriptor = next
        }
        guard let leaf = path.components.last else {
            throw StorageRelocationError(.invalidJournal)
        }
        let file = openat(
            descriptor,
            leaf,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard file >= 0 else {
            throw StorageRelocationError(.invalidJournal)
        }
        defer { close(file) }
        var status = stat()
        guard
            fstat(file, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_nlink == 1
        else {
            throw StorageRelocationError(.invalidJournal)
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let maximumBytes = 4 * 1_024 * 1_024
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw StorageRelocationError(.invalidJournal)
            }
            result.append(buffer, count: count)
            guard result.count <= maximumBytes else {
                throw StorageRelocationError(.invalidJournal)
            }
        }
        try validateControlRoot()
        return result
    }

    private func classifyLibrary(
        _ outcome: LibraryRepositoryLoadOutcome,
        prior: LibraryVersionToken,
        target: LibraryVersionToken
    ) -> LibraryCommitPrimaryState {
        let actual: LibraryVersionToken?
        switch outcome {
        case .missing:
            actual = .missing
        case let .loaded(snapshot):
            actual = snapshot.versionToken
        case .migrationRequired, .recoveryRequired, .readOnly:
            actual = nil
        }
        if actual == prior { return .prior }
        if actual == target { return .target }
        return .neither
    }

    private func ownedSnapshotIfPresent(
        _ path: any ManagedMutationPath
    ) throws -> StorageRelocationOwnedTreeSnapshot? {
        let secureFileSystem = try SecureManagedFileSystem(
            rootURL: path.validationContext.canonicalBaseRootURL
        )
        guard let relative = try securePath(path) else {
            throw StorageRelocationError(
                .sourceChanged,
                path: path.url.path
            )
        }
        switch try secureFileSystem.itemState(at: relative) {
        case .missing:
            return nil
        case let .present(identity):
            return StorageRelocationSecureConversions.snapshot(
                identity: identity,
                manifest: try secureFileSystem.manifest(at: relative)
            )
        }
    }

    private func removeOriginalOwned(
        _ path: any ManagedMutationPath,
        snapshot: StorageRelocationOwnedTreeSnapshot?,
        allowMissing: Bool = false
    ) throws {
        guard let snapshot else {
            guard !exists(path) else {
                throw StorageRelocationError(
                    .sourceChanged,
                    path: path.url.path
                )
            }
            return
        }
        guard
            let expectedIdentity =
                StorageRelocationSecureConversions.identity(
                    snapshot.identity
                ),
            let expectedManifest =
                StorageRelocationSecureConversions.manifest(
                    snapshot.manifest
                ),
            let relative = try securePath(path)
        else {
            throw StorageRelocationError(
                .invalidJournal,
                path: path.url.path
            )
        }
        let secureFileSystem = try SecureManagedFileSystem(
            rootURL: path.validationContext.canonicalBaseRootURL
        )
        if allowMissing,
           try secureFileSystem.itemState(at: relative) == .missing {
            return
        }
        try transactionBoundary?(.beforeSourceCleanup(path.url))
        do {
            try secureFileSystem.removeOwnedTree(
                at: relative,
                expectedIdentity: expectedIdentity,
                expectedManifest: expectedManifest
            )
        } catch {
            throw StorageRelocationError(
                .sourceChanged,
                path: path.url.path,
                detail: error.localizedDescription
            )
        }
    }

    private func requireOriginalOwned(
        _ path: any ManagedMutationPath,
        snapshot: StorageRelocationOwnedTreeSnapshot?
    ) throws {
        guard let snapshot else {
            guard !exists(path) else {
                throw StorageRelocationError(
                    .rollbackRequired,
                    path: path.url.path
                )
            }
            return
        }
        guard try ownedSnapshotIfPresent(path) == snapshot else {
            throw StorageRelocationError(
                .rollbackRequired,
                path: path.url.path
            )
        }
    }

    private func requireRecoveryCopy(
        _ path: any ManagedMutationPath,
        snapshot: StorageRelocationOwnedTreeSnapshot?
    ) throws {
        guard let snapshot else {
            guard !exists(path) else {
                throw StorageRelocationError(
                    .rollbackRequired,
                    path: path.url.path
                )
            }
            return
        }
        guard
            let expectedManifest =
                StorageRelocationSecureConversions.manifest(
                    snapshot.manifest
                ),
            let relative = try securePath(path)
        else {
            throw StorageRelocationError(.invalidJournal)
        }
        let secureFileSystem = try SecureManagedFileSystem(
            rootURL: path.validationContext.canonicalBaseRootURL
        )
        guard
            try secureFileSystem.itemState(at: relative) != .missing,
            try secureFileSystem.manifest(at: relative)
                == expectedManifest
        else {
            throw StorageRelocationError(
                .rollbackRequired,
                path: path.url.path
            )
        }
    }

    private func removeRecoveryCopyIfPresent(
        _ path: any ManagedMutationPath,
        snapshot: StorageRelocationOwnedTreeSnapshot?
    ) throws {
        guard exists(path) else { return }
        guard
            let snapshot,
            let expectedManifest =
                StorageRelocationSecureConversions.manifest(
                    snapshot.manifest
                ),
            let relative = try securePath(path)
        else {
            throw StorageRelocationError(
                .rollbackRequired,
                path: path.url.path
            )
        }
        let secureFileSystem = try SecureManagedFileSystem(
            rootURL: path.validationContext.canonicalBaseRootURL
        )
        guard
            case let .present(identity) =
                try secureFileSystem.itemState(at: relative),
            try secureFileSystem.manifest(at: relative)
                == expectedManifest
        else {
            throw StorageRelocationError(
                .rollbackRequired,
                path: path.url.path
            )
        }
        try secureFileSystem.removeOwnedTree(
            at: relative,
            expectedIdentity: identity,
            expectedManifest: expectedManifest
        )
    }

    private func removePublishedIfUnchanged(
        _ path: any ManagedMutationPath,
        expected: String?
    ) throws {
        guard exists(path) else { return }
        try requireFingerprint(path, expected: expected)
        try removeIfPresent(path)
    }

    private func requireFingerprint(
        _ path: any ManagedMutationPath,
        expected: String?
    ) throws {
        guard
            let expected,
            exists(path),
            try fingerprintIfPresent(path) == expected
        else {
            throw StorageRelocationError(
                .sourceChanged,
                path: path.url.path
            )
        }
    }

    func loadReceipt(at url: URL) throws -> StorageRelocationReceipt {
        do {
            return try decoder.decode(
                StorageRelocationReceipt.self,
                from: fileSystem.readData(at: url)
            )
        } catch {
            throw StorageRelocationError(
                .invalidReceipt,
                path: url.path,
                detail: error.localizedDescription
            )
        }
    }

    func recover(
        _ preview: StorageRelocationPreview,
        receiptURL: URL,
        repository: any LibraryRepositoryPersisting
    ) throws -> StorageRelocationRecoveryOutcome {
        let receipt = try loadReceipt(at: receiptURL)
        guard
            receipt.transactionID == preview.requestID,
            receipt.applicationID == preview.applicationID,
            receipt.applicationStorageID == preview.applicationStorageID,
            receipt.priorVersion.libraryToken == preview.expectedVersion,
            receipt.priorVersion.revision.rawValue < UInt64.max,
            receipt.targetVersion.revision.rawValue
                == receipt.priorVersion.revision.rawValue + 1,
            receipt.targetVersion.primarySHA256 != nil,
            receipt.sourceBasePath
                == preview.source.canonicalBaseRootURL.path,
            receipt.destinationBasePath
                == preview.destination.canonicalBaseRootURL.path
        else {
            throw StorageRelocationError(
                .invalidReceipt,
                path: receiptURL.path
            )
        }

        let source = preview.source
        let destination = preview.destination
        let destinationStaging = destination.stagingRoot(
            transactionID: receipt.transactionID
        )
        let stagedApplication = child("Application", in: destinationStaging)
        let stagedArchives = child("Archives", in: destinationStaging)
        let libraryOutcome = repository.load()
        let primary = classifyLibrary(
            libraryOutcome,
            prior: receipt.priorVersion.libraryToken,
            target: receipt.targetVersion.libraryToken
        )
        guard recoveryApplicationMatches(
            libraryOutcome,
            primary: primary,
            preview: preview
        ) else {
            throw StorageRelocationError(
                .ambiguousLibraryState,
                path: receiptURL.path
            )
        }
        switch primary {
        case .target:
            try requireRecoveryDestination(
                destination.applicationRoot,
                expected: preview.sourceApplicationFingerprint
            )
            try requireRecoveryDestination(
                destination.applicationArchiveRoot,
                expected: preview.sourceArchiveFingerprint
            )
            try removeOriginalOwned(
                source.applicationRoot,
                snapshot: preview.sourceApplicationSnapshot,
                allowMissing: true
            )
            try removeOriginalOwned(
                source.applicationArchiveRoot,
                snapshot: preview.sourceArchiveSnapshot,
                allowMissing: true
            )
            try removeIfPresent(destinationStaging)
            return .committed(
                StorageRelocationOutcome(
                    transactionID: receipt.transactionID,
                    application: preview.relocatedApplication,
                    versionToken: receipt.targetVersion.libraryToken,
                    receiptURL: nil
                )
            )
        case .prior:
            try requireRecoverySource(
                source.applicationRoot,
                expected: preview.sourceApplicationFingerprint
            )
            try requireRecoverySource(
                source.applicationArchiveRoot,
                expected: preview.sourceArchiveFingerprint
            )
            try removePublishedIfUnchanged(
                destination.applicationRoot,
                expected: preview.sourceApplicationFingerprint
            )
            try removePublishedIfUnchanged(
                destination.applicationArchiveRoot,
                expected: preview.sourceArchiveFingerprint
            )
            try removePublishedIfUnchanged(
                stagedApplication,
                expected: preview.sourceApplicationFingerprint
            )
            try removePublishedIfUnchanged(
                stagedArchives,
                expected: preview.sourceArchiveFingerprint
            )
            try removeIfPresent(destinationStaging)
            return .rolledBack
        case .neither:
            throw StorageRelocationError(
                .ambiguousLibraryState,
                path: receiptURL.path
            )
        }
    }

    private func recoveryApplicationMatches(
        _ outcome: LibraryRepositoryLoadOutcome,
        primary: LibraryCommitPrimaryState,
        preview: StorageRelocationPreview
    ) -> Bool {
        guard case let .loaded(snapshot) = outcome else {
            return false
        }
        let matches = snapshot.applications.filter {
            $0.id == preview.applicationID
        }
        guard matches.count == 1 else { return false }
        switch primary {
        case .prior:
            return matches[0] == preview.originalApplication
        case .target:
            return matches[0] == preview.relocatedApplication
        case .neither:
            return true
        }
    }

    private func requireRecoveryDestination(
        _ path: any ManagedMutationPath,
        expected: String?
    ) throws {
        if expected == nil {
            guard !exists(path) else {
                throw StorageRelocationError(
                    .rollbackRequired,
                    path: path.url.path
                )
            }
            return
        }
        do {
            try requireFingerprint(path, expected: expected)
        } catch {
            throw StorageRelocationError(
                .rollbackRequired,
                path: path.url.path,
                detail: error.localizedDescription
            )
        }
    }

    private func requireRecoverySource(
        _ path: any ManagedMutationPath,
        expected: String?
    ) throws {
        if expected == nil {
            guard !exists(path) else {
                throw StorageRelocationError(
                    .rollbackRequired,
                    path: path.url.path
                )
            }
            return
        }
        do {
            try requireFingerprint(path, expected: expected)
        } catch {
            throw StorageRelocationError(
                .rollbackRequired,
                path: path.url.path,
                detail: error.localizedDescription
            )
        }
    }

    private func relocatedApplication(
        _ application: ManagedApplication,
        sourceBaseRoot: String,
        destinationBaseRoot: String
    ) throws -> (
        application: ManagedApplication,
        generated: [StorageRelocationGeneratedRewrite],
        external: [StorageRelocationExternalPath]
    ) {
        var relocated = application
        relocated.baseStoragePath = destinationBaseRoot
        var generated: [StorageRelocationGeneratedRewrite] = []
        var external: [StorageRelocationExternalPath] = []

        for index in relocated.profiles.indices {
            var profile = relocated.profiles[index]
            let sourcePaths = try pathResolver.resolve(
                configuredBaseRoot: sourceBaseRoot,
                applicationStorageID: application.storageID,
                profileStorageID: profile.storageID
            )
            let destinationPaths = try pathResolver.resolve(
                configuredBaseRoot: destinationBaseRoot,
                applicationStorageID: application.storageID,
                profileStorageID: profile.storageID
            )

            let userDataValue = userDataValue(in: profile)
            let userDataOwnership = resolvedOwnership(
                profile.isolationOwnership.userData,
                configuredValue: userDataValue,
                generatedURL: sourcePaths.userData.url
            )
            profile.isolationOwnership.userData = userDataOwnership
            if userDataOwnership == .generated {
                profile.argumentsText = settingUserDataValue(
                    destinationPaths.userData.url.path,
                    in: profile.argumentsText
                )
                generated.append(
                    StorageRelocationGeneratedRewrite(
                        profileID: profile.id,
                        field: .userData,
                        oldURL: sourcePaths.userData.url,
                        newURL: destinationPaths.userData.url
                    )
                )
            } else if let userDataValue {
                external.append(
                    StorageRelocationExternalPath(
                        profileID: profile.id,
                        field: .userData,
                        value: userDataValue
                    )
                )
            }

            let codexHomeValue = environmentValue(
                "CODEX_HOME",
                in: profile.environmentText
            )
            let codexOwnership = resolvedOwnership(
                profile.isolationOwnership.codexHome,
                configuredValue: codexHomeValue,
                generatedURL: sourcePaths.codexHome.url
            )
            profile.isolationOwnership.codexHome = codexOwnership
            if codexOwnership == .generated {
                profile.environmentText = settingEnvironmentValue(
                    "CODEX_HOME",
                    to: destinationPaths.codexHome.url.path,
                    in: profile.environmentText
                )
                generated.append(
                    StorageRelocationGeneratedRewrite(
                        profileID: profile.id,
                        field: .codexHome,
                        oldURL: sourcePaths.codexHome.url,
                        newURL: destinationPaths.codexHome.url
                    )
                )
            } else if let codexHomeValue {
                external.append(
                    StorageRelocationExternalPath(
                        profileID: profile.id,
                        field: .codexHome,
                        value: codexHomeValue
                    )
                )
            }
            relocated.profiles[index] = profile
        }
        return (relocated, generated, external)
    }

    private func resolvedOwnership(
        _ ownership: IsolationPathOwnership,
        configuredValue: String?,
        generatedURL: URL
    ) -> IsolationPathOwnership {
        guard ownership == .legacyUnknown else { return ownership }
        guard
            let configuredValue,
            canonicalComparisonPath(configuredValue)
                == canonicalComparisonPath(generatedURL.path)
        else {
            return .explicit
        }
        return .generated
    }

    private func canonicalComparisonPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private func activeProfileIDs(
        in application: ManagedApplication
    ) -> [UUID] {
        let activeStorageIDs =
            activityProvider.activeProfileStorageIDs(
                applicationStorageID: application.storageID,
                profileStorageIDs: Set(
                    application.profiles.map(\.storageID)
                )
            )
        return application.profiles.compactMap { profile in
            activeStorageIDs.contains(profile.storageID)
                ? profile.id
                : nil
        }.sorted { $0.uuidString < $1.uuidString }
    }

    private func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.standardizedFileURL.pathComponents
        let right = rhs.standardizedFileURL.pathComponents
        return isPrefix(left, of: right) || isPrefix(right, of: left)
    }

    private func isPrefix(_ prefix: [String], of value: [String]) -> Bool {
        prefix.count <= value.count
            && Array(value.prefix(prefix.count)) == prefix
    }

    private func configuredBaseRoot(
        for application: ManagedApplication
    ) -> String {
        let trimmed = application.baseStoragePath?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty
            ? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support/Parallax/Profiles",
                    isDirectory: true
                )
                .path
            : application.baseStoragePath ?? ""
    }

    private func estimateApplicationStorage(
        _ paths: ResolvedApplicationStoragePaths
    ) throws -> StorageTreeEstimate {
        try estimateIfPresent(source: paths.applicationRoot)
            + estimateIfPresent(source: paths.applicationArchiveRoot)
    }

    private func estimateIfPresent(
        source: any ManagedMutationPath
    ) throws -> StorageTreeEstimate {
        guard fileSystem.fileExists(at: source.url) else { return .zero }
        _ = try pathResolver.revalidateForMutation(source)
        return try estimate(at: source.url)
    }

    private func estimate(at url: URL) throws -> StorageTreeEstimate {
        let attributes = try fileSystem.attributesOfItem(at: url)
        switch attributes.kind {
        case .directory:
            var result = StorageTreeEstimate(
                allocatedBytes: 0,
                itemCount: 1
            )
            for child in try fileSystem.contentsOfDirectory(at: url) {
                result = result + (try estimate(at: child))
            }
            return result
        case .regularFile:
            return StorageTreeEstimate(
                allocatedBytes: attributes.size ?? 0,
                itemCount: 1
            )
        case .symbolicLink, .other:
            throw StorageRelocationError(
                .sourceChanged,
                path: url.path
            )
        }
    }

    private func fingerprintIfPresent(
        _ path: any ManagedMutationPath
    ) throws -> String? {
        guard fileSystem.fileExists(at: path.url) else { return nil }
        _ = try pathResolver.revalidateForMutation(path)
        return try fingerprint(at: path.url)
    }

    private func fingerprint(at root: URL) throws -> String {
        var entries: [RelocationManifestEntry] = []
        try appendManifest(
            at: root,
            relativePath: ".",
            entries: &entries
        )
        let manifestEncoder = JSONEncoder()
        manifestEncoder.outputFormatting = [.sortedKeys]
        return LibraryPersistence.sha256(try manifestEncoder.encode(entries))
    }

    private func appendManifest(
        at url: URL,
        relativePath: String,
        entries: inout [RelocationManifestEntry]
    ) throws {
        let attributes = try fileSystem.attributesOfItem(at: url)
        switch attributes.kind {
        case .directory:
            entries.append(
                RelocationManifestEntry(
                    relativePath: relativePath,
                    kind: "directory",
                    size: nil,
                    contentSHA256: nil
                )
            )
            for child in try fileSystem.contentsOfDirectory(at: url)
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try appendManifest(
                    at: child,
                    relativePath: relativePath == "."
                        ? child.lastPathComponent
                        : relativePath + "/" + child.lastPathComponent,
                    entries: &entries
                )
            }
        case .regularFile:
            let data = try fileSystem.readData(at: url)
            entries.append(
                RelocationManifestEntry(
                    relativePath: relativePath,
                    kind: "file",
                    size: UInt64(data.count),
                    contentSHA256: LibraryPersistence.sha256(data)
                )
            )
        case .symbolicLink, .other:
            throw StorageRelocationError(.sourceChanged, path: url.path)
        }
    }

    private func availableCapacity(at url: URL) -> UInt64? {
        capacityProvider(url)
    }

    private static func systemAvailableCapacity(at url: URL) -> UInt64? {
        guard
            let values = try? url.resourceValues(
                forKeys: [
                    .volumeAvailableCapacityForImportantUsageKey,
                    .volumeAvailableCapacityKey,
                ]
            )
        else { return nil }
        if let important = values.volumeAvailableCapacityForImportantUsage,
           important >= 0 {
            return UInt64(important)
        }
        if let available = values.volumeAvailableCapacity, available >= 0 {
            return UInt64(available)
        }
        return nil
    }

    private func requireDestinationAbsent(
        _ paths: ResolvedApplicationStoragePaths
    ) throws {
        guard
            !fileSystem.fileExists(at: paths.applicationRoot.url),
            !fileSystem.fileExists(at: paths.applicationArchiveRoot.url)
        else {
            throw StorageRelocationError(
                .unexpectedDestination,
                path: paths.canonicalBaseRootURL.path
            )
        }
        _ = try pathResolver.revalidateForMutation(paths.applicationRoot)
        _ = try pathResolver.revalidateForMutation(
            paths.applicationArchiveRoot
        )
    }

    private func restoreOriginal(
        source: any ManagedMutationPath,
        destination: any ManagedMutationPath,
        staged: RelocationManagedPath,
        retired: RelocationManagedPath,
        strategy: StorageRelocationStrategy
    ) throws {
        if fileSystem.fileExists(at: source.url) {
            try removeIfPresent(destination)
            try removeIfPresent(staged)
            try removeIfPresent(retired)
            return
        }
        if fileSystem.fileExists(at: retired.url) {
            try move(retired, to: source)
            try removeIfPresent(destination)
            try removeIfPresent(staged)
            return
        }
        if strategy == .sameVolume,
           fileSystem.fileExists(at: destination.url) {
            try move(destination, to: source)
            try removeIfPresent(staged)
            return
        }
        if strategy == .sameVolume,
           fileSystem.fileExists(at: staged.url) {
            try move(staged, to: source)
            try removeIfPresent(destination)
            return
        }
        throw StorageRelocationError(
            .rollbackRequired,
            path: source.url.path
        )
    }

    private func checkCancellation(
        _ cancellation: StorageRelocationCancellation
    ) throws {
        if cancellation.isCancelled {
            throw StorageRelocationError(.cancelled)
        }
    }

    private func exists(_ path: any ManagedMutationPath) -> Bool {
        fileSystem.fileExists(at: path.url)
    }

    private func createDirectory(_ path: any ManagedMutationPath) throws {
        let url = try pathResolver.revalidateForMutation(path)
        if fileSystem is LocalFileSystem,
           let securePath = try securePath(path) {
            let secureFileSystem = try SecureManagedFileSystem(
                rootURL: path.validationContext.canonicalBaseRootURL
            )
            try secureFileSystem.createDirectory(at: securePath)
            return
        }
        try fileSystem.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        try fileSystem.setPOSIXPermissions(0o700, at: url)
    }

    private func copy(
        _ source: any ManagedMutationPath,
        to destination: any ManagedMutationPath
    ) throws {
        let sourceURL = try pathResolver.revalidateForMutation(source)
        let destinationURL = try pathResolver.revalidateForMutation(destination)
        guard !fileSystem.fileExists(at: destinationURL) else {
            throw StorageRelocationError(
                .unexpectedDestination,
                path: destinationURL.path
            )
        }
        if fileSystem is LocalFileSystem,
           let sourcePath = try securePath(source),
           let destinationPath = try securePath(destination) {
            let sourceFileSystem = try SecureManagedFileSystem(
                rootURL: source.validationContext.canonicalBaseRootURL
            )
            let destinationFileSystem = try SecureManagedFileSystem(
                rootURL: destination.validationContext.canonicalBaseRootURL
            )
            try sourceFileSystem.copyTree(
                from: sourcePath,
                to: destinationPath,
                in: destinationFileSystem
            )
            return
        }
        try fileSystem.copyItem(at: sourceURL, to: destinationURL)
    }

    private func move(
        _ source: any ManagedMutationPath,
        to destination: any ManagedMutationPath
    ) throws {
        let sourceURL = try pathResolver.revalidateForMutation(source)
        let destinationURL = try pathResolver.revalidateForMutation(destination)
        guard !fileSystem.fileExists(at: destinationURL) else {
            throw StorageRelocationError(
                .unexpectedDestination,
                path: destinationURL.path
            )
        }
        if fileSystem is LocalFileSystem,
           source.validationContext.canonicalBaseRootURL
            == destination.validationContext.canonicalBaseRootURL,
           let sourcePath = try securePath(source),
           let destinationPath = try securePath(destination) {
            let secureFileSystem = try SecureManagedFileSystem(
                rootURL: source.validationContext.canonicalBaseRootURL
            )
            try secureFileSystem.rename(
                from: sourcePath,
                to: destinationPath
            )
            return
        }
        try fileSystem.moveItem(at: sourceURL, to: destinationURL)
    }

    private func removeIfPresent(
        _ path: any ManagedMutationPath
    ) throws {
        guard fileSystem.fileExists(at: path.url) else { return }
        let url = try pathResolver.revalidateForMutation(path)
        if fileSystem is LocalFileSystem,
           let securePath = try securePath(path) {
            let secureFileSystem = try SecureManagedFileSystem(
                rootURL: path.validationContext.canonicalBaseRootURL
            )
            try secureFileSystem.removeTree(at: securePath)
            return
        }
        try fileSystem.removeItem(at: url)
    }

    private func securePath(
        _ path: any ManagedMutationPath
    ) throws -> SecureManagedPath? {
        let rootComponents =
            path.validationContext.canonicalBaseRootURL.pathComponents
        let pathComponents = path.url.pathComponents
        guard
            pathComponents.count > rootComponents.count,
            Array(pathComponents.prefix(rootComponents.count))
                == rootComponents
        else { return nil }
        return try SecureManagedPath(
            Array(pathComponents.dropFirst(rootComponents.count))
        )
    }

    private func persist(
        _ receipt: StorageRelocationReceipt,
        at path: RelocationReceiptPath
    ) throws {
        let data = try encoder.encode(receipt)
        // The resolver's mutation path contract describes directories. Validate
        // the containing transaction directory immediately before writing the
        // fixed receipt filename, rather than treating an existing JSON file as
        // a directory target on subsequent state transitions.
        let parent = RelocationManagedPath(
            url: path.url.deletingLastPathComponent(),
            validationContext: path.validationContext
        )
        _ = try pathResolver.revalidateForMutation(parent)
        try fileSystem.writeDataAtomically(data, to: path.url)
    }

    private func child(
        _ name: String,
        in staging: ManagedStagingRootPath
    ) -> RelocationManagedPath {
        RelocationManagedPath(
            url: staging.url.appendingPathComponent(name, isDirectory: true),
            validationContext: staging.validationContext
        )
    }

    private func childFile(
        _ name: String,
        in staging: ManagedStagingRootPath
    ) -> RelocationReceiptPath {
        RelocationReceiptPath(
            url: staging.url.appendingPathComponent(name, isDirectory: false),
            validationContext: staging.validationContext
        )
    }

    private func userDataValue(in profile: LaunchProfile) -> String? {
        for argument in profile.arguments {
            guard argument.hasPrefix("--user-data-dir=") else { continue }
            let value = String(
                argument.dropFirst("--user-data-dir=".count)
            )
            if !value.isEmpty { return value }
        }
        return nil
    }

    private func settingUserDataValue(
        _ value: String,
        in text: String
    ) -> String {
        var replaced = false
        let replacement = "--user-data-dir=\(value)"
        var arguments = ShellWordsParser.parse(text).map { argument in
            guard argument.hasPrefix("--user-data-dir=") else {
                return argument
            }
            replaced = true
            return replacement
        }
        if !replaced {
            arguments.append(replacement)
        }
        return arguments.map(ShellWordsParser.quote).joined(separator: " ")
    }

    private func environmentValue(
        _ key: String,
        in text: String
    ) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let string = String(line)
            guard let separator = string.firstIndex(of: "=") else { continue }
            let candidate = string[..<separator]
                .trimmingCharacters(in: .whitespaces)
            guard candidate == key else { continue }
            return String(string[string.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private func settingEnvironmentValue(
        _ key: String,
        to value: String,
        in text: String
    ) -> String {
        var replaced = false
        let lines = text.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map { line -> String in
            let string = String(line)
            guard let separator = string.firstIndex(of: "=") else {
                return string
            }
            let candidate = string[..<separator]
                .trimmingCharacters(in: .whitespaces)
            guard candidate == key else { return string }
            replaced = true
            return "\(key)=\(value)"
        }
        if replaced {
            return lines.joined(separator: "\n")
        }
        let suffix = "\(key)=\(value)"
        return text.isEmpty ? suffix : text + "\n" + suffix
    }
}

private struct RelocationManagedPath: ManagedMutationPath {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

private struct RelocationReceiptPath: ManagedMutationPath {
    let url: URL
    let validationContext: ManagedPathValidationContext
}

private struct RelocationManifestEntry: Codable {
    let relativePath: String
    let kind: String
    let size: UInt64?
    let contentSHA256: String?
}

private enum StorageRelocationControlCompletion:
    String,
    Codable,
    Equatable
{
    case committed
    case rolledBack
}

private struct StorageRelocationControlPlan: Codable, Equatable {
    struct Unsigned: Codable, Equatable {
        let version: Int
        let transactionID: UUID
        let applicationID: UUID
        let applicationStorageID: UUID
        let createdAt: Date
        let priorVersion: StorageRelocationVersionToken
        let targetVersion: StorageRelocationVersionToken
        let originalApplicationSHA256: String
        let relocatedApplicationSHA256: String
        let sourceBasePath: String
        let destinationBasePath: String
        let sourceApplicationFingerprint: String?
        let sourceArchiveFingerprint: String?
        let sourceApplicationSnapshot:
            StorageRelocationOwnedTreeSnapshot?
        let sourceArchiveSnapshot: StorageRelocationOwnedTreeSnapshot?
    }

    let unsigned: Unsigned
    let planSHA256: String
}

private struct StorageRelocationControlReceipt: Codable, Equatable {
    struct Unsigned: Codable, Equatable {
        let version: Int
        let transactionID: UUID
        let planSHA256: String
        let completion: StorageRelocationControlCompletion
        let completedAt: Date
        let priorVersion: StorageRelocationVersionToken
        let targetVersion: StorageRelocationVersionToken
    }

    let unsigned: Unsigned
    let receiptSHA256: String
}

private enum StorageRelocationSecureConversions {
    static func snapshot(
        identity: SecureManagedItemIdentity,
        manifest: SecureManagedManifest
    ) -> StorageRelocationOwnedTreeSnapshot {
        StorageRelocationOwnedTreeSnapshot(
            identity: StorageRelocationItemIdentity(
                volumeID: identity.volumeID,
                fileID: identity.fileID,
                kind: identity.kind.rawValue
            ),
            manifest: manifest.entries.map {
                StorageRelocationManifestEntry(
                    relativeComponents: $0.relativeComponents,
                    kind: $0.kind.rawValue,
                    byteCount: $0.byteCount,
                    permissions: $0.permissions,
                    sha256: $0.sha256
                )
            }
        )
    }

    static func identity(
        _ value: StorageRelocationItemIdentity
    ) -> SecureManagedItemIdentity? {
        guard
            let kind = SecureManagedItemIdentity.Kind(
                rawValue: value.kind
            )
        else { return nil }
        return SecureManagedItemIdentity(
            volumeID: value.volumeID,
            fileID: value.fileID,
            kind: kind
        )
    }

    static func manifest(
        _ values: [StorageRelocationManifestEntry]
    ) -> SecureManagedManifest? {
        var entries: [SecureManagedManifest.Entry] = []
        for value in values {
            guard
                let kind = SecureManagedItemIdentity.Kind(
                    rawValue: value.kind
                ),
                value.relativeComponents.allSatisfy({
                    !$0.isEmpty
                        && $0 != "."
                        && $0 != ".."
                        && !$0.contains("/")
                        && !$0.contains(":")
                        && !$0.contains("\0")
                })
            else { return nil }
            entries.append(
                SecureManagedManifest.Entry(
                    relativeComponents: value.relativeComponents,
                    kind: kind,
                    byteCount: value.byteCount,
                    permissions: value.permissions,
                    sha256: value.sha256
                )
            )
        }
        return SecureManagedManifest(entries: entries)
    }
}
