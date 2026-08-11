import Foundation

enum ApplicationRemovalTransactionEffect: Equatable, Sendable {
    case stageProfile(UUID, Int)
    case publishArchive(UUID, Int)
    case commitMetadata
    case purgeStaging
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
    }

    let code: Code

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
struct ApplicationRemovalTransactionCoordinator: @unchecked Sendable {
    private let journal: ApplicationRemovalTransactionJournal
    private let planBuilder: ApplicationRemovalTransactionPlanBuilder
    private let executor: ApplicationRemovalTransactionExecutor
    private let recovery: ApplicationRemovalTransactionRecovery

    init(
        applicationSupportURL: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        transactionBoundary:
            (@Sendable (ApplicationRemovalTransactionBoundary) throws -> Void)?
            = nil
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
        self.journal = journal
        planBuilder = ApplicationRemovalTransactionPlanBuilder(
            journalRoot: journalRoot,
            now: now
        )
        executor = ApplicationRemovalTransactionExecutor(
            journal: journal,
            transactionBoundary: transactionBoundary
        )
        recovery = ApplicationRemovalTransactionRecovery(
            journal: journal,
            transactionBoundary: transactionBoundary
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
        try journal.persist(manifest)

        do {
            return try executor.execute(
                &manifest,
                preparedCommit: preparedCommit,
                expectedVersion:
                    request.executionAuthorization.repositoryVersion,
                repository: repository,
                finishCommitted: recovery.finishCommitted
            )
        } catch is ApplicationRemovalTransactionInterruption {
            throw ApplicationRemovalTransactionInterruption
                .simulatedCrash
        } catch {
            if manifest.phase == .metadataCommitted
                || recovery.repositoryMatchesTarget(
                    repository,
                    manifest: manifest
                )
            {
                manifest.phase = .metadataCommitted
                try? journal.persist(manifest)
                _ = try? recovery.finishCommitted(manifest)
            } else {
                _ = try? recovery.rollback(manifest)
            }
            throw error
        }
    }

    func pendingTransactions() throws -> [UUID] {
        try journal.pendingTransactions()
    }

    func recover(
        transactionID: UUID,
        repository: any LibraryRepositoryPersisting
    ) throws -> ApplicationRemovalTransactionOutcome {
        if let completed = try journal.completedOutcome(
            transactionID: transactionID
        ) {
            return completed
        }
        let manifest = try journal.loadManifest(
            transactionID: transactionID
        )
        if manifest.phase == .metadataCommitted
            || recovery.repositoryMatchesTarget(
                repository,
                manifest: manifest
            )
        {
            return try recovery.finishCommitted(manifest)
        }
        return try recovery.rollback(manifest)
    }
}
