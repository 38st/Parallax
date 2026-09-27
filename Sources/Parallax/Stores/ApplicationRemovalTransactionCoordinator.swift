import Foundation

enum ApplicationRemovalTransactionEffect: Equatable, Sendable {
    case stageProfile(UUID, Int)
    case publishArchive(UUID, Int)
    case commitMetadata
    case purgeStaging
    case finalizeArchive(UUID, Int)
    case publishTombstone(UUID, Int)
    case purgeChild(UUID, String)
}

enum ApplicationRemovalTransactionBoundary: Equatable, Sendable {
    case beforeEffect(ApplicationRemovalTransactionEffect)
    case afterEffectBeforeRecord(ApplicationRemovalTransactionEffect)
    case afterRecord(ApplicationRemovalTransactionEffect)
}

enum ApplicationRemovalTransactionInterruption: Error {
    case simulatedCrash
}

struct ApplicationRemovalTransactionError: LocalizedError {
    enum Code: String, Equatable, Sendable {
        case invalidRequest
        case invalidTarget
        case targetChanged
        case unownedStagedData
        case transactionNotFound
        case missingManagedData
        case storageUnavailable
        case conflictingManagedData
        case missingStagedData
        case unsupportedProfileTree
        case libraryUnavailable
        case preservedFilesRequireReview
    }

    let code: Code
    var profileName: String? = nil
    var itemPath: String? = nil

    var errorDescription: String? {
        switch code {
        case .invalidRequest:
            String(
                localized:
                    "The application removal transaction is incomplete or does not match its authorization."
            )
        case .invalidTarget:
            String(
                localized:
                    "A managed profile target is outside its immutable application storage namespace."
            )
        case .targetChanged:
            String(
                localized:
                    "A managed profile target changed after removal was confirmed."
            )
        case .unownedStagedData:
            String(
                localized:
                    "Transaction staging contains data Parallax cannot prove it owns. Recovery stopped without deleting it."
            )
        case .missingManagedData:
            String(localized: "Managed profile data expected by this removal transaction is missing. Reconnect its storage and retry, or choose Keep Files and Continue to leave any remaining files in place.")
        case .storageUnavailable:
            String(localized: "The storage location is unavailable. Reconnect it at the same path, then retry application removal.")
        case .conflictingManagedData:
            String(localized: "Multiple copies of this profile's data exist. Parallax left every copy in place. Review their locations, then choose Keep Files and Continue to stop this removal's recovery.")
        case .missingStagedData:
            String(localized: "The staged profile data is missing before deletion was recorded. Parallax stopped recovery. Review the data locations, then choose Keep Files and Continue to leave any remaining files in place.")
        case .unsupportedProfileTree:
            String(localized: "Managed storage for space \(profileName ?? String(localized: "Unknown space")) contains a symbolic link or unsupported item at \(itemPath ?? String(localized: "Unknown location")). Quit the application and review this item, including any stale Chromium Singleton files, before removing the application.")
        case .libraryUnavailable:
            String(localized: "The library needs repair or migration before this removal record can be retired. No files or recovery records were changed.")
        case .preservedFilesRequireReview:
            String(localized: "Files from an earlier removal may remain at these locations: \(itemPath ?? String(localized: "Unknown location")). Archive and Delete cannot remove these preserved copies. Review Preserved Files, or choose Keep in Place.")
        case .transactionNotFound:
            String(
                localized:
                    "The application removal transaction could not be found."
            )
        }
    }
}

struct ApplicationRemovalTransactionRequest: Sendable {
    let transactionID: UUID
    let executionAuthorization: ApplicationRemovalExecutionAuthorization
    let profiles: [ApplicationRemovalProfileTarget]

    init(
        transactionID: UUID,
        executionAuthorization: ApplicationRemovalExecutionAuthorization,
        profiles: [ApplicationRemovalProfileTarget]
    ) {
        self.transactionID = transactionID
        self.executionAuthorization = executionAuthorization
        self.profiles = profiles
    }
}

enum ApplicationRemovalTransactionCompletion:
    String,
    Codable,
    Equatable,
    Sendable
{
    case committed
    case rolledBack
    case keptFiles
}

struct ApplicationRemovalTransactionOutcome:
    Equatable,
    Sendable
{
    let transactionID: UUID
    let completion: ApplicationRemovalTransactionCompletion
    let dataChoice: ApplicationRemovalDataChoice
    let archiveURLs: [UUID: URL]
}

/// A durable, all-or-nothing transaction across every managed profile owned
/// by one application. External paths are evidence only and are never passed
/// to a filesystem mutation.
struct ApplicationRemovalTransactionCoordinator: Sendable {
    private let applicationSupportURL: URL
    private let journal: ApplicationRemovalTransactionJournal
    private let planBuilder: ApplicationRemovalTransactionPlanBuilder
    private let executor: ApplicationRemovalTransactionExecutor
    private let recovery: ApplicationRemovalTransactionRecovery
    let recoveryPresentation = ApplicationRemovalRecoveryPresentation()
    let recoveryAttempts = ApplicationRemovalRecoveryAttempts()
    private let recoveryInventoryWillRead: (@Sendable () -> Void)?

    init(
        applicationSupportURL: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        identitySource: @escaping ApplicationRemovalTransactionIdentitySource =
            ApplicationRemovalTransactionRootIdentity.read,
        isMountContainer: @escaping @Sendable (URL) -> Bool =
            ApplicationRemovalTransactionFileSystem.isMountContainer,
        transactionBoundary:
            (@Sendable (ApplicationRemovalTransactionBoundary) throws -> Void)?
            = nil,
        recoveryInventoryWillRead: (@Sendable () -> Void)? = nil
    ) throws {
        let support = applicationSupportURL.standardizedFileURL
        guard support.isFileURL, support.path != "/" else {
            throw ApplicationRemovalTransactionError(
                code: .invalidRequest
            )
        }
        let journalRoot = support
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent(
                "ApplicationRemovalTransactions",
                isDirectory: true
            )
        let journal = ApplicationRemovalTransactionJournal(
            rootURL: journalRoot
        )
        self.applicationSupportURL = applicationSupportURL
        self.journal = journal
        self.recoveryInventoryWillRead = recoveryInventoryWillRead
        planBuilder = ApplicationRemovalTransactionPlanBuilder(
            journalRoot: journalRoot,
            now: now,
            identitySource: identitySource,
            isMountContainer: isMountContainer
        )
        executor = ApplicationRemovalTransactionExecutor(
            journal: journal,
            transactionBoundary: transactionBoundary,
            identitySource: identitySource
        )
        recovery = ApplicationRemovalTransactionRecovery(
            journal: journal,
            transactionBoundary: transactionBoundary,
            identitySource: identitySource
        )
    }

    func execute(
        _ request: ApplicationRemovalTransactionRequest,
        preparedCommit: PreparedLibraryCommit,
        repository: any LibraryRepositoryPersisting
    ) throws -> ApplicationRemovalTransactionOutcome {
        try planBuilder.validate(
            request,
            preparedCommit: preparedCommit
        )
        if let completed = try journal.completedOutcome(
            transactionID: request.transactionID
        ) {
            return completed
        }

        var manifest = try planBuilder.makeManifest(
            request,
            preparedCommit: preparedCommit
        )
        do {
            return try executor.execute(
                &manifest,
                preparedCommit: preparedCommit,
                expectedVersion: request.executionAuthorization.repositoryVersion,
                repository: repository,
                recovery: recovery
            )
        } catch {
            recoveryAttempts.recordFailure(error, transactionID: request.transactionID)
            throw error
        }
    }

    func recoveryReview(transactionID: UUID) throws -> ApplicationRemovalRecoveryReview {
        let data = try journal.manifestData(transactionID: transactionID)
        return try Self.recoveryReview(data: data, transactionID: transactionID)
    }

    static func recoveryReview(data: Data, transactionID: UUID) throws -> ApplicationRemovalRecoveryReview {
        let manifest = try JSONDecoder().decode(ApplicationRemovalTransactionManifest.self, from: data)
        guard manifest.transactionID == transactionID else {
            throw ApplicationRemovalTransactionError(code: .invalidRequest)
        }
        var locations = Set<URL>()
        for entry in manifest.entries {
            let root = URL(fileURLWithPath: entry.baseRootPath, isDirectory: true)
            guard entry.baseRootPath.hasPrefix("/"), root.path != "/",
                  !entry.baseRootPath.contains("\0") else {
                throw ApplicationRemovalTransactionError(code: .invalidTarget)
            }
            let paths = try [
                ApplicationRemovalTransactionPaths.source(entry, applicationStorageID: manifest.applicationStorageID),
                ApplicationRemovalTransactionPaths.staged(entry, transactionID: transactionID),
                ApplicationRemovalTransactionPaths.archive(entry),
                ApplicationRemovalTransactionPaths.tombstone(entry, transactionID: transactionID),
            ]
            for path in paths {
                locations.insert(path.components.reduce(root) {
                    $0.appendingPathComponent($1, isDirectory: true)
                })
            }
        }
        return ApplicationRemovalRecoveryReview(
            transactionID: transactionID,
            manifestSHA256: LibraryPersistence.sha256(data),
            locations: locations.sorted { $0.path < $1.path }
        )
    }

    func keepFilesAndContinue(
        _ review: ApplicationRemovalRecoveryReview,
        repository: any LibraryRepositoryPersisting,
        access: LibraryExclusiveAccess
    ) throws {
        try access.validate(for: repository)
        guard try recoveryReview(transactionID: review.transactionID) == review else {
            throw ApplicationRemovalTransactionError(code: .targetChanged)
        }
        try journal.keepFiles(review)
        recoveryAttempts.clear(review.transactionID)
    }

    func recoveryInventory() throws -> ApplicationRemovalRecoveryInventory {
        recoveryInventoryWillRead?()
        let pending = try journal.pendingTransactions().map { transactionID in
            do {
                return ApplicationRemovalRecoveryJournalReview(
                    id: transactionID,
                    review: try recoveryReview(transactionID: transactionID),
                    status: recoveryAttempts.message(for: transactionID).map {
                        .failed($0)
                    } ?? .notAttempted
                )
            } catch {
                return ApplicationRemovalRecoveryJournalReview(
                    id: transactionID,
                    review: nil,
                    status: .unreadable(String(localized: "This removal recovery record could not be read: \(error.localizedDescription)"))
                )
            }
        }
        return ApplicationRemovalRecoveryInventory(
            pending: pending,
            preserved: try journal.preservedFiles()
        )
    }

    func pendingTransactions() throws -> [UUID] {
        try journal.pendingTransactions()
    }

    func recover(
        transactionID: UUID,
        repository: any LibraryRepositoryPersisting
    ) throws -> ApplicationRemovalTransactionOutcome {
        do {
            let outcome = try recoverTransaction(transactionID: transactionID, repository: repository)
            recoveryAttempts.clear(transactionID)
            return outcome
        } catch {
            recoveryAttempts.recordFailure(error, transactionID: transactionID)
            throw error
        }
    }

    private func recoverTransaction(
        transactionID: UUID,
        repository: any LibraryRepositoryPersisting
    ) throws -> ApplicationRemovalTransactionOutcome {
        if let completed = try journal.completedOutcome(
            transactionID: transactionID
        ) {
            try journal.removeManifest(transactionID: transactionID)
            return completed
        }
        let manifest = try journal.loadManifest(
            transactionID: transactionID
        )
        let registry = try ProfileActivityRegistry(applicationSupportURL: applicationSupportURL)
        let reservation = try registry.acquireDataOperationLease(identities: Set(manifest.entries.map { entry in
            ProfileActivityIdentity(applicationID: manifest.applicationID, applicationStorageID: manifest.applicationStorageID,
                profileID: entry.profileID, profileStorageID: entry.profileStorageID)
        }))
        defer { reservation.release() }
        if try recovery.repositoryCommittedRemoval(repository, manifest: manifest) {
            return try recovery.finishCommitted(manifest)
        }
        return try recovery.rollback(manifest)
    }
}
