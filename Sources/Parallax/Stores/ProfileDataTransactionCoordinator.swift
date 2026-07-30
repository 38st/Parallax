import Darwin
import Foundation

struct ProfileDataTransactionIdentity: Codable, Sendable, Equatable {
    let applicationID: UUID
    let applicationStorageID: UUID
    let sourceProfileID: UUID
    let sourceProfileStorageID: UUID
    let destinationProfileID: UUID?
    let destinationProfileStorageID: UUID?

    init(
        applicationID: UUID,
        applicationStorageID: UUID,
        sourceProfileID: UUID,
        sourceProfileStorageID: UUID,
        destinationProfileID: UUID? = nil,
        destinationProfileStorageID: UUID? = nil
    ) {
        self.applicationID = applicationID
        self.applicationStorageID = applicationStorageID
        self.sourceProfileID = sourceProfileID
        self.sourceProfileStorageID = sourceProfileStorageID
        self.destinationProfileID = destinationProfileID
        self.destinationProfileStorageID = destinationProfileStorageID
    }
}

enum ProfileDataTransactionOperation: String, Codable, Sendable, Equatable {
    case archive
    case clear
    case delete
    case duplicate
    case relocate
}

enum ProfileExternalDataHandling: Codable, Sendable, Equatable {
    case notConfigured
    case configurationOnly(configuredPaths: [String])
}

enum ProfileDataMutation: String, Codable, Sendable, Equatable {
    case noManagedData
    case archivedManagedData
    case deletedManagedData
    case copiedManagedData
    case relocatedManagedData
    case rolledBack
}

struct ProfileDataTransactionRequest: Sendable {
    let transactionID: UUID
    let identity: ProfileDataTransactionIdentity
    let operation: ProfileDataTransactionOperation
    let source: ResolvedProfilePaths
    let destination: ResolvedProfilePaths?
    let externalDataHandling: ProfileExternalDataHandling
}

enum ProfileDataTransactionEffect: String, Codable, Sendable, Equatable {
    case createTransactionsDirectory
    case writeOwnerMarker
    case createStaging
    case moveToStaging
    case copyToStaging
    case writePayloadMarker
    case publishArchive
    case publishDestination
    case commitMetadata
    case removePayloadMarker
    case removeDeletedPayload
    case removeRelocatedSource
    case removeStaging
    case removeOwnerMarker
    case writeReceipt
    case requireRecovery
}

enum ProfileDataTransactionBoundary: Sendable, Equatable {
    case beforeEffect(ProfileDataTransactionEffect)
    case afterEffectBeforeRecord(ProfileDataTransactionEffect)
    case afterRecord(ProfileDataTransactionEffect)
}

struct ProfileDataTransactionOutcome: Sendable, Equatable {
    let transactionID: UUID
    let operation: ProfileDataTransactionOperation
    let dataMutation: ProfileDataMutation
    let externalDataHandling: ProfileExternalDataHandling
    let didArchiveData: Bool
    let archiveURL: URL?
    let receiptURL: URL
}

struct PendingProfileDataTransaction: Sendable, Equatable {
    let transactionID: UUID
    let identity: ProfileDataTransactionIdentity
    let operation: ProfileDataTransactionOperation
    let state: String
    let createdAt: Date
}

struct ProfileDataTransactionError: LocalizedError {
    enum Code: String, Sendable, Equatable {
        case unexpectedDestination
        case sameSourceAndDestination
        case sourceChanged
        case invalidJournal
        case invalidReceipt
        case transactionNotFound
        case rollbackRequired
        case unsupportedSymbolicLink
        case preparedCommitMismatch
        case ambiguousLibraryState
        case unownedData
    }

    let code: Code
    let operation: ProfileDataTransactionOperation?
    let path: String?
    let detail: String?

    init(
        _ code: Code,
        operation: ProfileDataTransactionOperation? = nil,
        path: String? = nil,
        detail: String? = nil
    ) {
        self.code = code
        self.operation = operation
        self.path = path
        self.detail = detail
    }

    var errorDescription: String? {
        let operationName = operation?.rawValue ?? String(localized: "profile data")
        switch code {
        case .unexpectedDestination:
            return String(
                localized: "The \(operationName) transaction stopped because an unexpected destination exists at \(path ?? "an unknown path")."
            )
        case .sameSourceAndDestination:
            return String(localized: "The profile data source and destination are the same.")
        case .sourceChanged:
            return String(localized: "Managed profile data changed during the transaction.")
        case .invalidJournal:
            return String(localized: "The profile transaction journal failed integrity validation.")
        case .invalidReceipt:
            return String(localized: "The profile transaction receipt failed integrity validation.")
        case .transactionNotFound:
            return String(localized: "The profile transaction could not be found.")
        case .rollbackRequired:
            return String(localized: "The \(operationName) transaction requires recovery.")
        case .unsupportedSymbolicLink:
            return String(localized: "Managed profile data contains an unsupported symbolic link.")
        case .preparedCommitMismatch:
            return String(localized: "The prepared library commit does not match this profile transaction.")
        case .ambiguousLibraryState:
            return String(
                localized: "The library matches neither the prior nor prepared transaction version. No profile data was removed."
            )
        case .unownedData:
            return String(
                localized: "Parallax could not prove ownership of transaction data at \(path ?? "an unknown path"), so it was preserved."
            )
        }
    }
}

/// Executes managed profile mutations through descriptor-relative filesystem
/// primitives and binds them to one prepared, compare-and-swap library commit.
///
/// The central ProfileTransactions index is independent of the mutable library
/// model and every record is write-once, canonical, and hash chained.
struct ProfileDataTransactionCoordinator: @unchecked Sendable {
    private static let controlComponents = ["Parallax", "ProfileTransactions"]
    private static let payloadOwnerPrefix = ".parallax-owner-"

    private let applicationSupportURL: URL
    private let controlRootURL: URL
    private let controlRootIdentity: FileSystemObjectIdentity
    private let control: SecureManagedFileSystem
    private let fileSystem: any FileSystem
    private let now: () -> Date
    private let transactionBoundary:
        (@Sendable (ProfileDataTransactionBoundary) throws -> Void)?
    private let secureBoundary:
        (@Sendable (URL, SecureManagedFileSystemBoundary) throws -> Void)?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        applicationSupportURL: URL,
        fileSystem: any FileSystem = LocalFileSystem(),
        now: @escaping () -> Date = Date.init,
        transactionBoundary:
            (@Sendable (ProfileDataTransactionBoundary) throws -> Void)? = nil,
        secureBoundary:
            (@Sendable (URL, SecureManagedFileSystemBoundary) throws -> Void)? = nil
    ) throws {
        self.applicationSupportURL = applicationSupportURL
        self.fileSystem = fileSystem
        self.now = now
        self.transactionBoundary = transactionBoundary
        self.secureBoundary = secureBoundary
        control = try SecureManagedFileSystem(
            anchorURL: applicationSupportURL,
            rootComponents: Self.controlComponents,
            createIfMissing: true
        )
        controlRootURL = Self.controlComponents.reduce(applicationSupportURL) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        let attributes = try fileSystem.attributesOfItem(at: controlRootURL)
        guard
            attributes.kind == .directory,
            let identity = attributes.identity
        else {
            throw ProfileDataTransactionError(
                .invalidJournal,
                path: controlRootURL.path
            )
        }
        controlRootIdentity = identity

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    func execute(
        _ request: ProfileDataTransactionRequest,
        preparedCommit: PreparedLibraryCommit,
        repository: any LibraryRepositoryPersisting
    ) throws -> ProfileDataTransactionOutcome {
        try validatePreparedCommit(preparedCommit)
        try validateRequest(request)

        do {
            return try repository.withExclusiveMutation(
                expectedVersion: preparedCommit.priorVersion
            ) { capability in
                var log = try preparePlan(
                    request: request,
                    preparedCommit: preparedCommit
                )
                try validateMetadataTransition(
                    plan: log.plan,
                    priorApplications: capability.applications,
                    targetApplications: preparedCommit.applications
                )
                guard
                    log.plan.preparedCommitIdentifier
                        == preparedCommitIdentifier(
                            request: request,
                            preparedCommit: preparedCommit
                        )
                else {
                    throw ProfileDataTransactionError(
                        .preparedCommitMismatch,
                        operation: request.operation
                    )
                }
                let sourceFS = try secureFileSystem(for: log.plan.sourceRoot)
                let destinationFS = try log.plan.destinationRoot.map {
                    try secureFileSystem(for: $0)
                }
                try verifyInitialState(
                    log.plan,
                    sourceFS: sourceFS,
                    destinationFS: destinationFS
                )
                try publishPlan(log)
                if log.plan.sourceSnapshot != nil {
                    try prepareOwnedStaging(
                        log: &log,
                        hostFS: destinationFS ?? sourceFS
                    )
                }

                let mutation = try applyData(
                    log: &log,
                    sourceFS: sourceFS,
                    destinationFS: destinationFS
                )
                _ = try perform(
                    .commitMetadata,
                    log: &log
                ) {
                    let result = try capability.commit(
                        preparedCommit,
                        backupReason: metadataBackupReason(
                            for: request.operation
                        )
                    )
                    return [
                        "primaryState": result.primaryState.rawValue,
                        "targetSHA256":
                            result.snapshot.versionToken.primarySHA256 ?? "",
                    ]
                }

                try finalizeCommittedData(
                    log: &log,
                    sourceFS: sourceFS,
                    destinationFS: destinationFS
                )
                try cleanupOwnedStaging(
                    log: &log,
                    hostFS: destinationFS ?? sourceFS
                )
                return try complete(
                    log: &log,
                    mutation: mutation,
                    completion: .committed
                )
            }
        } catch {
            // All state needed by restart recovery is already durable. Do not
            // perform an unlocked best-effort mutation here.
            throw error
        }
    }

    func recover(
        transactionID: UUID,
        repository: any LibraryRepositoryPersisting
    ) throws -> ProfileDataTransactionOutcome {
        var log = try loadLog(transactionID: transactionID)
        if try control.itemState(
            at: controlReceiptPath(transactionID)
        ) != .missing,
           !log.hasEffect(.writeReceipt) {
            try repairReceiptEffect(log: &log)
        }
        if let receipt = try validatedReceiptIfPresent(log: log) {
            return outcome(from: receipt, plan: log.plan)
        }

        let primary = classifyPrimary(
            repository.load(),
            prior: log.plan.priorVersion.value,
            target: log.plan.targetVersion.value
        )
        guard primary != .neither else {
            if !log.hasEffect(.requireRecovery) {
                _ = try perform(.requireRecovery, log: &log) {
                    ["primaryState": LibraryCommitPrimaryState.neither.rawValue]
                }
            }
            throw ProfileDataTransactionError(
                .ambiguousLibraryState,
                operation: log.plan.operation
            )
        }

        let sourceFS = try secureFileSystem(for: log.plan.sourceRoot)
        let destinationFS = try log.plan.destinationRoot.map {
            try secureFileSystem(for: $0)
        }
        do {
            if primary == .target {
                try finalizeCommittedData(
                    log: &log,
                    sourceFS: sourceFS,
                    destinationFS: destinationFS
                )
                try cleanupOwnedStaging(
                    log: &log,
                    hostFS: destinationFS ?? sourceFS
                )
                return try complete(
                    log: &log,
                    mutation: committedMutation(for: log.plan),
                    completion: .committed
                )
            }

            try rollBackData(
                log: &log,
                sourceFS: sourceFS,
                destinationFS: destinationFS
            )
            try cleanupOwnedStaging(
                log: &log,
                hostFS: destinationFS ?? sourceFS
            )
            return try complete(
                log: &log,
                mutation: .rolledBack,
                completion: .rolledBack
            )
        } catch {
            try markRecoveryRequired(
                log: &log,
                primary: primary,
                error: error
            )
            throw error
        }
    }

    func pendingTransactions() throws -> [PendingProfileDataTransaction] {
        try validateControlRoot()
        let entries = try fileSystem.contentsOfDirectory(at: controlRootURL)
        let suffix = ".plan.json"
        var pending: [PendingProfileDataTransaction] = []
        for entry in entries
            .filter({ $0.lastPathComponent.hasSuffix(suffix) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let rawID = String(entry.lastPathComponent.dropLast(suffix.count))
            guard
                let id = UUID(uuidString: rawID),
                id.uuidString.lowercased() == rawID
            else {
                throw ProfileDataTransactionError(
                    .invalidJournal,
                    path: entry.path
                )
            }
            let log = try loadLog(transactionID: id)
            if try validatedReceiptIfPresent(log: log) != nil {
                continue
            }
            pending.append(
                PendingProfileDataTransaction(
                    transactionID: id,
                    identity: log.plan.identity,
                    operation: log.plan.operation,
                    state: log.records.last?.unsigned.event.effect.rawValue
                        ?? "prepared",
                    createdAt: log.plan.createdAt
                )
            )
        }
        try validateControlRoot()
        return pending
    }

    private func preparePlan(
        request: ProfileDataTransactionRequest,
        preparedCommit: PreparedLibraryCommit
    ) throws -> TransactionLog {
        let sourceBinding = try rootBinding(
            for: request.source.profileRoot.validationContext
        )
        let sourcePath = try securePath(
            request.source.profileRoot.url,
            relativeTo: sourceBinding.url
        )
        let archivePath = request.operation == .archive
            || request.operation == .clear
            ? try securePath(
                request.source.archiveEntry(
                    timestamp: now(),
                    nonce: request.transactionID
                ).url,
                relativeTo: sourceBinding.url
            )
            : nil

        let destinationBinding: RootBinding?
        let destinationPath: PathValue?
        if let destination = request.destination {
            destinationBinding = try rootBinding(
                for: destination.profileRoot.validationContext
            )
            destinationPath = PathValue(
                try securePath(
                    destination.profileRoot.url,
                    relativeTo: destinationBinding?.url
                        ?? destination.profileRoot.validationContext.canonicalBaseRootURL
                )
            )
        } else {
            destinationBinding = nil
            destinationPath = nil
        }

        let sourceFS = try secureFileSystem(for: sourceBinding)
        let sourceSnapshot = try snapshot(at: sourcePath, in: sourceFS)
        if let destinationBinding, let destinationPath {
            let destinationFS = try secureFileSystem(for: destinationBinding)
            guard try destinationFS.itemState(at: destinationPath.value) == .missing else {
                throw ProfileDataTransactionError(
                    .unexpectedDestination,
                    operation: request.operation,
                    path: request.destination?.profileRoot.url.path
                )
            }
        }
        if let archivePath {
            guard try sourceFS.itemState(at: archivePath) == .missing else {
                throw ProfileDataTransactionError(
                    .unexpectedDestination,
                    operation: request.operation,
                    path: request.source.archiveRoot.url.path
                )
            }
        }

        let transactionComponent = request.transactionID.uuidString.lowercased()
        let hostBinding = destinationBinding ?? sourceBinding
        let stagePath = try SecureManagedPath([
            ".parallax",
            "Transactions",
            transactionComponent,
        ])
        let stageOwnerPath = try SecureManagedPath([
            ".parallax",
            "Transactions",
            transactionComponent + ".owner",
        ])
        let payloadPath = try stagePath.appending("payload")
        let payloadOwnerPath = try payloadPath.appending(
            Self.payloadOwnerPrefix + transactionComponent
        )

        let createdAt = now()
        let preparedIdentifier = preparedCommitIdentifier(
            request: request,
            preparedCommit: preparedCommit
        )
        let plan = Plan(
            version: 2,
            transactionID: request.transactionID,
            identity: request.identity,
            operation: request.operation,
            createdAt: createdAt,
            sourceRoot: sourceBinding,
            sourcePath: PathValue(sourcePath),
            sourceSnapshot: sourceSnapshot,
            destinationRoot: destinationBinding,
            destinationPath: destinationPath,
            archivePath: archivePath.map(PathValue.init),
            hostRoot: hostBinding,
            stagePath: PathValue(stagePath),
            stageOwnerPath: PathValue(stageOwnerPath),
            payloadPath: PathValue(payloadPath),
            payloadOwnerPath: PathValue(payloadOwnerPath),
            priorVersion: TokenValue(preparedCommit.priorVersion),
            targetVersion: TokenValue(preparedCommit.targetVersion),
            targetBytesSHA256: LibraryPersistence.sha256(
                preparedCommit.targetBytes
            ),
            preparedCommitIdentifier: preparedIdentifier,
            externalDataHandling: request.externalDataHandling
        )
        let planBytes = try canonicalBytes(plan)
        let planHash = LibraryPersistence.sha256(planBytes)
        return TransactionLog(
            plan: plan,
            planBytes: planBytes,
            planHash: planHash,
            records: []
        )
    }

    private func publishPlan(_ log: TransactionLog) throws {
        let path = try controlPlanPath(log.plan.transactionID)
        guard try control.itemState(at: path) == .missing else {
            throw ProfileDataTransactionError(
                .unexpectedDestination,
                operation: log.plan.operation,
                path: controlURL(for: path).path
            )
        }
        try control.write(log.planBytes, to: path)
    }

    private func prepareOwnedStaging(
        log: inout TransactionLog,
        hostFS: SecureManagedFileSystem
    ) throws {
        let parent = try SecureManagedPath(
            Array(log.plan.stagePath.value.components.dropLast())
        )
        if try hostFS.itemState(at: parent) == .missing {
            _ = try perform(.createTransactionsDirectory, log: &log) {
                try hostFS.createDirectory(at: parent)
                return try snapshotDetails(at: parent, in: hostFS)
            }
        }

        let ownerBytes = try canonicalBytes(
            OwnerMarker(
                version: 1,
                transactionID: log.plan.transactionID,
                planSHA256: log.planHash
            )
        )
        let stageOwnerPath = log.plan.stageOwnerPath.value
        if try hostFS.itemState(at: stageOwnerPath) == .missing {
            _ = try perform(.writeOwnerMarker, log: &log) {
                try hostFS.write(ownerBytes, to: stageOwnerPath)
                return [
                    "ownerSHA256": LibraryPersistence.sha256(ownerBytes),
                ].merging(
                    try snapshotDetails(
                        at: stageOwnerPath,
                        in: hostFS
                    )
                ) { _, new in new }
            }
        } else {
            try requireOwner(log: log, hostFS: hostFS)
        }

        let stagePath = log.plan.stagePath.value
        if try hostFS.itemState(at: stagePath) == .missing {
            _ = try perform(.createStaging, log: &log) {
                try hostFS.createDirectory(at: stagePath)
                return try snapshotDetails(
                    at: stagePath,
                    in: hostFS
                )
            }
        }
    }

    private func applyData(
        log: inout TransactionLog,
        sourceFS: SecureManagedFileSystem,
        destinationFS: SecureManagedFileSystem?
    ) throws -> ProfileDataMutation {
        guard log.plan.sourceSnapshot != nil else {
            return .noManagedData
        }
        let hostFS = destinationFS ?? sourceFS
        let sourcePath = log.plan.sourcePath.value
        let payloadPath = log.plan.payloadPath.value
        switch log.plan.operation {
        case .archive, .clear, .delete:
            if try hostFS.itemState(at: payloadPath) == .missing {
                _ = try perform(.moveToStaging, log: &log) {
                    try sourceFS.rename(
                        from: sourcePath,
                        to: payloadPath
                    )
                    return try snapshotDetails(
                        at: payloadPath,
                        in: hostFS
                    )
                }
            }
        case .duplicate, .relocate:
            if try hostFS.itemState(at: payloadPath) == .missing {
                _ = try perform(.copyToStaging, log: &log) {
                    try sourceFS.copyTree(
                        from: sourcePath,
                        to: payloadPath,
                        in: hostFS
                    )
                    return try snapshotDetails(
                        at: payloadPath,
                        in: hostFS
                    )
                }
            }
        }

        try writePayloadOwnerIfNeeded(log: &log, hostFS: hostFS)

        switch log.plan.operation {
        case .archive, .clear:
            guard let archive = log.plan.archivePath?.value else {
                throw ProfileDataTransactionError(.invalidJournal)
            }
            if try sourceFS.itemState(at: archive) == .missing {
                let payloadPath = log.plan.payloadPath.value
                _ = try perform(.publishArchive, log: &log) {
                    try sourceFS.rename(
                        from: payloadPath,
                        to: archive
                    )
                    return try snapshotDetails(at: archive, in: sourceFS)
                }
            }
            return .archivedManagedData
        case .delete:
            return .deletedManagedData
        case .duplicate:
            guard
                let destinationFS,
                let destination = log.plan.destinationPath?.value
            else {
                throw ProfileDataTransactionError(.invalidJournal)
            }
            if try destinationFS.itemState(at: destination) == .missing {
                let payloadPath = log.plan.payloadPath.value
                _ = try perform(.publishDestination, log: &log) {
                    try destinationFS.rename(
                        from: payloadPath,
                        to: destination
                    )
                    return try snapshotDetails(
                        at: destination,
                        in: destinationFS
                    )
                }
            }
            return .copiedManagedData
        case .relocate:
            guard
                let destinationFS,
                let destination = log.plan.destinationPath?.value
            else {
                throw ProfileDataTransactionError(.invalidJournal)
            }
            if try destinationFS.itemState(at: destination) == .missing {
                let payloadPath = log.plan.payloadPath.value
                _ = try perform(.publishDestination, log: &log) {
                    try destinationFS.rename(
                        from: payloadPath,
                        to: destination
                    )
                    return try snapshotDetails(
                        at: destination,
                        in: destinationFS
                    )
                }
            }
            return .relocatedManagedData
        }
    }

    private func writePayloadOwnerIfNeeded(
        log: inout TransactionLog,
        hostFS: SecureManagedFileSystem
    ) throws {
        let payloadOwner = payloadOwnerPath(for: log, published: false)
        if try hostFS.itemState(at: payloadOwner) != .missing {
            try requirePayloadOwner(log: log, fileSystem: hostFS, at: payloadOwner)
            return
        }
        let bytes = try canonicalBytes(
            OwnerMarker(
                version: 1,
                transactionID: log.plan.transactionID,
                planSHA256: log.planHash
            )
        )
        let payloadPath = log.plan.payloadPath.value
        _ = try perform(.writePayloadMarker, log: &log) {
            try hostFS.write(bytes, to: payloadOwner)
            return [
                "ownerSHA256": LibraryPersistence.sha256(bytes),
            ].merging(
                try snapshotDetails(at: payloadPath, in: hostFS)
            ) { _, new in new }
        }
    }

    private func finalizeCommittedData(
        log: inout TransactionLog,
        sourceFS: SecureManagedFileSystem,
        destinationFS: SecureManagedFileSystem?
    ) throws {
        let hostFS = destinationFS ?? sourceFS
        switch log.plan.operation {
        case .archive, .clear:
            guard let archive = log.plan.archivePath?.value else {
                throw ProfileDataTransactionError(.invalidJournal)
            }
            try removePayloadOwnerIfPresent(
                log: &log,
                fileSystem: sourceFS,
                container: archive
            )
        case .delete:
            let payloadPath = log.plan.payloadPath.value
            if try hostFS.itemState(at: payloadPath) != .missing {
                try requirePayloadOwner(
                    log: log,
                    fileSystem: hostFS,
                    at: payloadOwnerPath(for: log, published: false)
                )
                _ = try perform(.removeDeletedPayload, log: &log) {
                    try removeCurrentOwnedTree(
                        payloadPath,
                        in: hostFS
                    )
                    return [:]
                }
            }
        case .duplicate:
            guard
                let destinationFS,
                let destination = log.plan.destinationPath?.value
            else {
                throw ProfileDataTransactionError(.invalidJournal)
            }
            try removePayloadOwnerIfPresent(
                log: &log,
                fileSystem: destinationFS,
                container: destination
            )
        case .relocate:
            guard
                let destinationFS,
                let destination = log.plan.destinationPath?.value
            else {
                throw ProfileDataTransactionError(.invalidJournal)
            }
            try removePayloadOwnerIfPresent(
                log: &log,
                fileSystem: destinationFS,
                container: destination
            )
            if let sourceSnapshot = log.plan.sourceSnapshot,
               try sourceFS.itemState(at: log.plan.sourcePath.value) != .missing {
                let sourcePath = log.plan.sourcePath.value
                _ = try perform(.removeRelocatedSource, log: &log) {
                    try sourceFS.removeOwnedTree(
                        at: sourcePath,
                        expectedIdentity: sourceSnapshot.identity.value,
                        expectedManifest: sourceSnapshot.manifest.value
                    )
                    return [:]
                }
            }
        }
    }

    private func rollBackData(
        log: inout TransactionLog,
        sourceFS: SecureManagedFileSystem,
        destinationFS: SecureManagedFileSystem?
    ) throws {
        guard log.plan.sourceSnapshot != nil else { return }
        let hostFS = destinationFS ?? sourceFS
        switch log.plan.operation {
        case .archive, .clear:
            guard let archive = log.plan.archivePath?.value else {
                throw ProfileDataTransactionError(.invalidJournal)
            }
            if try sourceFS.itemState(at: archive) != .missing {
                try requirePayloadOwner(
                    log: log,
                    fileSystem: sourceFS,
                    at: payloadOwnerPath(
                        for: log,
                        publishedContainer: archive
                    )
                )
                try requireMissing(log.plan.sourcePath.value, in: sourceFS)
                try sourceFS.rename(
                    from: archive,
                    to: log.plan.sourcePath.value
                )
                try removePayloadOwnerIfPresent(
                    log: &log,
                    fileSystem: sourceFS,
                    container: log.plan.sourcePath.value
                )
            } else if try hostFS.itemState(at: log.plan.payloadPath.value) != .missing {
                try requireOwner(log: log, hostFS: hostFS)
                try requireMissing(log.plan.sourcePath.value, in: sourceFS)
                try sourceFS.rename(
                    from: log.plan.payloadPath.value,
                    to: log.plan.sourcePath.value
                )
                try removePayloadOwnerIfPresent(
                    log: &log,
                    fileSystem: sourceFS,
                    container: log.plan.sourcePath.value
                )
            }
            if try sourceFS.itemState(at: log.plan.sourcePath.value) != .missing {
                try removePayloadOwnerIfPresent(
                    log: &log,
                    fileSystem: sourceFS,
                    container: log.plan.sourcePath.value
                )
            }
        case .delete:
            if try hostFS.itemState(at: log.plan.payloadPath.value) != .missing {
                try requireOwner(log: log, hostFS: hostFS)
                try requireMissing(log.plan.sourcePath.value, in: sourceFS)
                try sourceFS.rename(
                    from: log.plan.payloadPath.value,
                    to: log.plan.sourcePath.value
                )
                try removePayloadOwnerIfPresent(
                    log: &log,
                    fileSystem: sourceFS,
                    container: log.plan.sourcePath.value
                )
            }
            if try sourceFS.itemState(at: log.plan.sourcePath.value) != .missing {
                try removePayloadOwnerIfPresent(
                    log: &log,
                    fileSystem: sourceFS,
                    container: log.plan.sourcePath.value
                )
            }
        case .duplicate, .relocate:
            if
                let destinationFS,
                let destination = log.plan.destinationPath?.value,
                try destinationFS.itemState(at: destination) != .missing
            {
                let marker = payloadOwnerPath(
                    for: log,
                    publishedContainer: destination
                )
                if try destinationFS.itemState(at: marker) != .missing {
                    try requirePayloadOwner(
                        log: log,
                        fileSystem: destinationFS,
                        at: marker
                    )
                    try removeCurrentOwnedTree(destination, in: destinationFS)
                } else if log.hasEvent(.publishDestination) {
                    throw ProfileDataTransactionError(
                        .unownedData,
                        operation: log.plan.operation,
                        path: destination.components.joined(separator: "/")
                    )
                }
            }
            if try hostFS.itemState(at: log.plan.payloadPath.value) != .missing {
                try requireOwner(log: log, hostFS: hostFS)
                try removeCurrentOwnedTree(log.plan.payloadPath.value, in: hostFS)
            }
        }
    }

    private func cleanupOwnedStaging(
        log: inout TransactionLog,
        hostFS: SecureManagedFileSystem
    ) throws {
        let stageState = try hostFS.itemState(at: log.plan.stagePath.value)
        if case .present = stageState {
            try requireOwner(log: log, hostFS: hostFS)
            let stagePath = log.plan.stagePath.value
            _ = try perform(.removeStaging, log: &log) {
                try removeCurrentOwnedTree(stagePath, in: hostFS)
                return [:]
            }
        }

        if try hostFS.itemState(at: log.plan.stageOwnerPath.value) != .missing {
            try requireOwner(log: log, hostFS: hostFS)
            let stageOwnerPath = log.plan.stageOwnerPath.value
            _ = try perform(.removeOwnerMarker, log: &log) {
                try removeCurrentOwnedTree(
                    stageOwnerPath,
                    in: hostFS
                )
                return [:]
            }
        }
    }

    private func complete(
        log: inout TransactionLog,
        mutation: ProfileDataMutation,
        completion: Completion
    ) throws -> ProfileDataTransactionOutcome {
        if let existing = try validatedReceiptIfPresent(log: log) {
            return outcome(
                from: existing,
                plan: log.plan
            )
        }
        let receipt = Receipt(
            version: 1,
            transactionID: log.plan.transactionID,
            planSHA256: log.planHash,
            chainHeadSHA256: log.chainHead,
            identity: log.plan.identity,
            operation: log.plan.operation,
            completion: completion,
            dataMutation: mutation,
            externalDataHandling: log.plan.externalDataHandling,
            priorVersion: log.plan.priorVersion,
            targetVersion: log.plan.targetVersion,
            completedAt: now()
        )
        let bytes = try canonicalBytes(receipt)
        let hash = LibraryPersistence.sha256(bytes)
        let transactionID = log.plan.transactionID
        _ = try perform(.writeReceipt, log: &log) {
            try control.write(
                bytes,
                to: try controlReceiptPath(transactionID)
            )
            return ["receiptSHA256": hash]
        }
        let validated = try validatedReceiptIfPresent(log: log)
        guard let validated else {
            throw ProfileDataTransactionError(.invalidReceipt)
        }
        return outcome(
            from: validated,
            plan: log.plan
        )
    }

    private func perform(
        _ effect: ProfileDataTransactionEffect,
        log: inout TransactionLog,
        body: () throws -> [String: String]
    ) throws -> [String: String] {
        try appendRecord(
            event: Event(phase: .intent, effect: effect),
            details: [:],
            log: &log
        )
        try transactionBoundary?(.beforeEffect(effect))
        let details = try body()
        try transactionBoundary?(.afterEffectBeforeRecord(effect))
        try appendRecord(
            event: Event(phase: .effect, effect: effect),
            details: details,
            log: &log
        )
        try transactionBoundary?(.afterRecord(effect))
        return details
    }

    private func appendRecord(
        event: Event,
        details: [String: String],
        log: inout TransactionLog
    ) throws {
        let sequence = log.records.count + 1
        let unsigned = UnsignedRecord(
            version: 1,
            transactionID: log.plan.transactionID,
            sequence: sequence,
            previousSHA256: log.chainHead,
            planSHA256: log.planHash,
            event: event,
            details: details,
            recordedAt: now()
        )
        let unsignedBytes = try canonicalBytes(unsigned)
        let recordHash = LibraryPersistence.sha256(unsignedBytes)
        let record = Record(unsigned: unsigned, recordSHA256: recordHash)
        let bytes = try canonicalBytes(record)
        try control.write(
            bytes,
            to: try controlRecordPath(
                transactionID: log.plan.transactionID,
                sequence: sequence
            )
        )
        log.records.append(record)
    }

    private func loadLog(transactionID: UUID) throws -> TransactionLog {
        let planPath = try controlPlanPath(transactionID)
        guard try control.itemState(at: planPath) != .missing else {
            throw ProfileDataTransactionError(.transactionNotFound)
        }
        let planBytes = try readControlFile(planPath)
        let plan: Plan
        do {
            plan = try decoder.decode(Plan.self, from: planBytes)
        } catch {
            throw ProfileDataTransactionError(
                .invalidJournal,
                path: controlURL(for: planPath).path,
                detail: error.localizedDescription
            )
        }
        guard
            plan.version == 2,
            plan.transactionID == transactionID,
            try canonicalBytes(plan) == planBytes,
            try validateDecodedPlan(plan)
        else {
            throw ProfileDataTransactionError(
                .invalidJournal,
                path: controlURL(for: planPath).path
            )
        }
        let planHash = LibraryPersistence.sha256(planBytes)
        var records: [Record] = []
        var sequence = 1
        var previousHash = planHash
        while true {
            let path = try controlRecordPath(
                transactionID: transactionID,
                sequence: sequence
            )
            guard try control.itemState(at: path) != .missing else { break }
            let bytes = try readControlFile(path)
            let record: Record
            do {
                record = try decoder.decode(Record.self, from: bytes)
            } catch {
                throw ProfileDataTransactionError(
                    .invalidJournal,
                    path: controlURL(for: path).path
                )
            }
            let expectedHash = LibraryPersistence.sha256(
                try canonicalBytes(record.unsigned)
            )
            guard
                try canonicalBytes(record) == bytes,
                record.unsigned.version == 1,
                record.unsigned.transactionID == transactionID,
                record.unsigned.sequence == sequence,
                record.unsigned.planSHA256 == planHash,
                record.unsigned.previousSHA256 == previousHash,
                record.recordSHA256 == expectedHash
            else {
                throw ProfileDataTransactionError(
                    .invalidJournal,
                    path: controlURL(for: path).path
                )
            }
            records.append(record)
            previousHash = record.recordSHA256
            sequence += 1
        }

        let prefix = transactionID.uuidString.lowercased() + "."
        let recordSuffix = ".record.json"
        let files = try fileSystem.contentsOfDirectory(at: controlRootURL)
        let unexpectedSequence = files.contains { url in
            guard
                url.lastPathComponent.hasPrefix(prefix),
                url.lastPathComponent.hasSuffix(recordSuffix)
            else { return false }
            let value = url.lastPathComponent
                .dropFirst(prefix.count)
                .dropLast(recordSuffix.count)
            guard let number = Int(value) else { return true }
            return number >= sequence
        }
        guard !unexpectedSequence else {
            throw ProfileDataTransactionError(.invalidJournal)
        }
        return TransactionLog(
            plan: plan,
            planBytes: planBytes,
            planHash: planHash,
            records: records
        )
    }

    private func validatedReceiptIfPresent(
        log: TransactionLog
    ) throws -> Receipt? {
        let path = try controlReceiptPath(log.plan.transactionID)
        guard try control.itemState(at: path) != .missing else {
            if log.hasEffect(.writeReceipt) {
                throw ProfileDataTransactionError(.invalidReceipt)
            }
            return nil
        }
        let bytes = try readControlFile(path)
        let receipt: Receipt
        do {
            receipt = try decoder.decode(Receipt.self, from: bytes)
        } catch {
            throw ProfileDataTransactionError(.invalidReceipt)
        }
        guard
            try canonicalBytes(receipt) == bytes,
            receipt.version == 1,
            receipt.transactionID == log.plan.transactionID,
            receipt.planSHA256 == log.planHash,
            receipt.identity == log.plan.identity,
            receipt.operation == log.plan.operation,
            receipt.externalDataHandling == log.plan.externalDataHandling,
            receipt.priorVersion == log.plan.priorVersion,
            receipt.targetVersion == log.plan.targetVersion,
            receiptIsConsistent(receipt, plan: log.plan),
            let receiptRecord = log.records.last(where: {
                $0.unsigned.event
                    == Event(phase: .effect, effect: .writeReceipt)
            }),
            let receiptIntent = log.records.last(where: {
                $0.unsigned.event
                    == Event(phase: .intent, effect: .writeReceipt)
            }),
            receiptRecord.unsigned.details["receiptSHA256"]
                == LibraryPersistence.sha256(bytes),
            receipt.chainHeadSHA256
                == receiptIntent.unsigned.previousSHA256,
            receiptRecord.unsigned.previousSHA256
                == receiptIntent.recordSHA256
        else {
            throw ProfileDataTransactionError(.invalidReceipt)
        }
        return receipt
    }

    private func repairReceiptEffect(
        log: inout TransactionLog
    ) throws {
        guard
            let intent = log.records.last,
            intent.unsigned.event
                == Event(phase: .intent, effect: .writeReceipt)
        else {
            throw ProfileDataTransactionError(.invalidReceipt)
        }
        let path = try controlReceiptPath(log.plan.transactionID)
        let bytes = try readControlFile(path)
        let receipt: Receipt
        do {
            receipt = try decoder.decode(Receipt.self, from: bytes)
        } catch {
            throw ProfileDataTransactionError(.invalidReceipt)
        }
        guard
            try canonicalBytes(receipt) == bytes,
            receipt.version == 1,
            receipt.transactionID == log.plan.transactionID,
            receipt.planSHA256 == log.planHash,
            receipt.chainHeadSHA256 == intent.unsigned.previousSHA256,
            receipt.identity == log.plan.identity,
            receipt.operation == log.plan.operation,
            receipt.externalDataHandling == log.plan.externalDataHandling,
            receipt.priorVersion == log.plan.priorVersion,
            receipt.targetVersion == log.plan.targetVersion,
            receiptIsConsistent(receipt, plan: log.plan)
        else {
            throw ProfileDataTransactionError(.invalidReceipt)
        }
        try appendRecord(
            event: Event(phase: .effect, effect: .writeReceipt),
            details: [
                "receiptSHA256": LibraryPersistence.sha256(bytes),
            ],
            log: &log
        )
    }

    private func markRecoveryRequired(
        log: inout TransactionLog,
        primary: LibraryCommitPrimaryState,
        error: Error
    ) throws {
        guard !log.hasEffect(.requireRecovery) else { return }
        _ = try perform(.requireRecovery, log: &log) {
            [
                "primaryState": primary.rawValue,
                "errorType": String(reflecting: type(of: error)),
            ]
        }
    }

    private func validatePreparedCommit(
        _ prepared: PreparedLibraryCommit
    ) throws {
        guard
            prepared.targetVersion.primarySHA256
                == LibraryPersistence.sha256(prepared.targetBytes),
            prepared.targetVersion.revision.rawValue
                == prepared.priorVersion.revision.rawValue + 1
        else {
            throw ProfileDataTransactionError(.preparedCommitMismatch)
        }
    }

    private func validateMetadataTransition(
        plan: Plan,
        priorApplications: [ManagedApplication],
        targetApplications: [ManagedApplication]
    ) throws {
        guard
            let priorApplication = priorApplications.first(where: {
                $0.id == plan.identity.applicationID
            }),
            let targetApplication = targetApplications.first(where: {
                $0.id == plan.identity.applicationID
            }),
            priorApplications.filter({
                $0.id == plan.identity.applicationID
            }).count == 1,
            targetApplications.filter({
                $0.id == plan.identity.applicationID
            }).count == 1,
            priorApplication.storageID
                == plan.identity.applicationStorageID,
            targetApplication.storageID
                == plan.identity.applicationStorageID,
            let priorSource = priorApplication.profiles.first(where: {
                $0.id == plan.identity.sourceProfileID
            }),
            priorSource.storageID
                == plan.identity.sourceProfileStorageID
        else {
            throw ProfileDataTransactionError(
                .preparedCommitMismatch,
                operation: plan.operation
            )
        }

        let targetSource = targetApplication.profiles.first {
            $0.id == plan.identity.sourceProfileID
        }
        let targetHasSource = targetSource?.storageID
            == plan.identity.sourceProfileStorageID
        switch plan.operation {
        case .archive, .delete:
            guard !targetHasSource else {
                throw ProfileDataTransactionError(
                    .preparedCommitMismatch,
                    operation: plan.operation
                )
            }
        case .clear:
            guard targetHasSource else {
                throw ProfileDataTransactionError(
                    .preparedCommitMismatch,
                    operation: plan.operation
                )
            }
        case .duplicate:
            guard
                targetHasSource,
                let destinationID = plan.identity.destinationProfileID,
                destinationID != plan.identity.sourceProfileID,
                !priorApplication.profiles.contains(where: {
                    $0.id == destinationID
                }),
                let targetDestination = targetApplication.profiles.first(where: {
                    $0.id == destinationID
                }),
                targetDestination.storageID
                    == plan.identity.destinationProfileStorageID
            else {
                throw ProfileDataTransactionError(
                    .preparedCommitMismatch,
                    operation: plan.operation
                )
            }
        case .relocate:
            guard targetHasSource else {
                throw ProfileDataTransactionError(
                    .preparedCommitMismatch,
                    operation: plan.operation
                )
            }
        }
    }

    private func validateDecodedPlan(_ plan: Plan) throws -> Bool {
        guard
            plan.version == 2,
            plan.sourceRoot.path.hasPrefix("/"),
            plan.hostRoot.path.hasPrefix("/"),
            !plan.preparedCommitIdentifier.isEmpty,
            plan.targetBytesSHA256 == plan.targetVersion.primarySHA256,
            plan.priorVersion.revision < UInt64.max,
            plan.targetVersion.revision == plan.priorVersion.revision + 1
        else { return false }
        switch plan.operation {
        case .archive, .clear:
            guard
                plan.destinationRoot == nil,
                plan.destinationPath == nil,
                plan.archivePath != nil,
                plan.hostRoot == plan.sourceRoot,
                plan.identity.destinationProfileID == nil,
                plan.identity.destinationProfileStorageID == nil
            else { return false }
        case .delete:
            guard
                plan.destinationRoot == nil,
                plan.destinationPath == nil,
                plan.archivePath == nil,
                plan.hostRoot == plan.sourceRoot,
                plan.identity.destinationProfileID == nil,
                plan.identity.destinationProfileStorageID == nil
            else { return false }
        case .duplicate:
            guard
                let destinationRoot = plan.destinationRoot,
                plan.destinationPath != nil,
                plan.archivePath == nil,
                plan.hostRoot == destinationRoot,
                plan.identity.destinationProfileID != nil,
                plan.identity.destinationProfileStorageID != nil
            else { return false }
        case .relocate:
            guard
                let destinationRoot = plan.destinationRoot,
                plan.destinationPath != nil,
                plan.archivePath == nil,
                plan.hostRoot == destinationRoot,
                plan.identity.destinationProfileID
                    == plan.identity.sourceProfileID,
                plan.identity.destinationProfileStorageID
                    == plan.identity.sourceProfileStorageID
            else { return false }
        }
        let paths = [
            plan.sourcePath,
            plan.destinationPath,
            plan.archivePath,
            plan.stagePath,
            plan.stageOwnerPath,
            plan.payloadPath,
            plan.payloadOwnerPath,
        ].compactMap { $0 }
        for path in paths {
            _ = try SecureManagedPath(path.components)
        }
        let applicationStorage =
            plan.identity.applicationStorageID.uuidString.lowercased()
        let sourceStorage =
            plan.identity.sourceProfileStorageID.uuidString.lowercased()
        guard plan.sourcePath.components == [
            ".parallax",
            "Applications",
            applicationStorage,
            "Profiles",
            sourceStorage,
        ] else { return false }
        let transaction = plan.transactionID.uuidString.lowercased()
        guard
            plan.stagePath.components == [
                ".parallax", "Transactions", transaction,
            ],
            plan.stageOwnerPath.components == [
                ".parallax", "Transactions", transaction + ".owner",
            ],
            plan.payloadPath.components
                == plan.stagePath.components + ["payload"],
            plan.payloadOwnerPath.components
                == plan.payloadPath.components
                    + [Self.payloadOwnerPrefix + transaction]
        else { return false }
        if let destination = plan.destinationPath {
            guard let destinationStorage =
                plan.identity.destinationProfileStorageID?
                    .uuidString.lowercased()
            else { return false }
            guard destination.components == [
                ".parallax",
                "Applications",
                applicationStorage,
                "Profiles",
                destinationStorage,
            ] else { return false }
        }
        if let archive = plan.archivePath {
            guard
                archive.components.count == 5,
                Array(archive.components.prefix(4)) == [
                    ".parallax",
                    "Archives",
                    applicationStorage,
                    sourceStorage,
                ],
                archive.components[4].hasSuffix("-" + transaction)
            else { return false }
        }
        let snapshots = [plan.sourceSnapshot].compactMap { $0 }
        for snapshot in snapshots {
            guard snapshot.identity.isValid else { return false }
            for entry in snapshot.manifest.entries {
                guard
                    IdentityValue.validKinds.contains(entry.kind),
                    entry.relativeComponents.allSatisfy({
                        !$0.isEmpty
                            && $0 != "."
                            && $0 != ".."
                            && !$0.contains("/")
                            && !$0.contains("\0")
                    })
                else { return false }
            }
        }
        return true
    }

    private func receiptIsConsistent(
        _ receipt: Receipt,
        plan: Plan
    ) -> Bool {
        switch receipt.completion {
        case .committed:
            return receipt.dataMutation == committedMutation(for: plan)
        case .rolledBack:
            return receipt.dataMutation == .rolledBack
        }
    }

    private func validateRequest(
        _ request: ProfileDataTransactionRequest
    ) throws {
        switch request.operation {
        case .duplicate, .relocate:
            guard
                request.destination != nil,
                request.identity.destinationProfileID != nil,
                request.identity.destinationProfileStorageID != nil
            else {
                throw ProfileDataTransactionError(.invalidJournal)
            }
        case .archive, .clear, .delete:
            guard
                request.destination == nil,
                request.identity.destinationProfileID == nil,
                request.identity.destinationProfileStorageID == nil
            else {
                throw ProfileDataTransactionError(.invalidJournal)
            }
        }
        if let destination = request.destination,
           destination.profileRoot.url.standardizedFileURL
            == request.source.profileRoot.url.standardizedFileURL {
            throw ProfileDataTransactionError(.sameSourceAndDestination)
        }
    }

    private func verifyInitialState(
        _ plan: Plan,
        sourceFS: SecureManagedFileSystem,
        destinationFS: SecureManagedFileSystem?
    ) throws {
        guard try snapshot(at: plan.sourcePath.value, in: sourceFS)
            == plan.sourceSnapshot else {
            throw ProfileDataTransactionError(
                .sourceChanged,
                operation: plan.operation
            )
        }
        if
            let destinationFS,
            let destination = plan.destinationPath?.value
        {
            guard try destinationFS.itemState(at: destination) == .missing else {
                throw ProfileDataTransactionError(
                    .unexpectedDestination,
                    operation: plan.operation
                )
            }
        }
    }

    private func rootBinding(
        for context: ManagedPathValidationContext
    ) throws -> RootBinding {
        let root = context.canonicalBaseRootURL.standardizedFileURL
        let attributes = try fileSystem.attributesOfItem(at: root)
        guard
            attributes.kind == .directory,
            let identity = attributes.identity
        else {
            throw ProfileDataTransactionError(
                .sourceChanged,
                path: root.path
            )
        }
        return RootBinding(
            path: root.path,
            volumeID: identity.volumeID,
            fileID: identity.fileID
        )
    }

    private func secureFileSystem(
        for binding: RootBinding
    ) throws -> SecureManagedFileSystem {
        let attributes = try fileSystem.attributesOfItem(at: binding.url)
        guard
            attributes.kind == .directory,
            attributes.identity == binding.identity
        else {
            throw ProfileDataTransactionError(
                .sourceChanged,
                path: binding.path
            )
        }
        let boundaryHook = secureBoundary
        return try SecureManagedFileSystem(
            rootURL: binding.url,
            boundaryHook: { boundary in
                try boundaryHook?(binding.url, boundary)
            }
        )
    }

    private func securePath(
        _ target: URL,
        relativeTo root: URL
    ) throws -> SecureManagedPath {
        let rootComponents = root.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        guard
            targetComponents.count > rootComponents.count,
            Array(targetComponents.prefix(rootComponents.count))
                == rootComponents
        else {
            throw ProfileDataTransactionError(
                .invalidJournal,
                path: target.path
            )
        }
        return try SecureManagedPath(
            Array(targetComponents.dropFirst(rootComponents.count))
        )
    }

    private func snapshot(
        at path: SecureManagedPath,
        in fileSystem: SecureManagedFileSystem
    ) throws -> ItemSnapshot? {
        switch try fileSystem.itemState(at: path) {
        case .missing:
            return nil
        case let .present(identity):
            return ItemSnapshot(
                identity: IdentityValue(identity),
                manifest: ManifestValue(try fileSystem.manifest(at: path))
            )
        }
    }

    private func snapshotDetails(
        at path: SecureManagedPath,
        in fileSystem: SecureManagedFileSystem
    ) throws -> [String: String] {
        guard let snapshot = try snapshot(at: path, in: fileSystem) else {
            return ["state": "missing"]
        }
        return [
            "state": "present",
            "identity": try canonicalBytes(snapshot.identity)
                .base64EncodedString(),
            "manifest": try canonicalBytes(snapshot.manifest)
                .base64EncodedString(),
        ]
    }

    private func removeCurrentOwnedTree(
        _ path: SecureManagedPath,
        in fileSystem: SecureManagedFileSystem
    ) throws {
        guard let snapshot = try snapshot(at: path, in: fileSystem) else {
            return
        }
        try fileSystem.removeOwnedTree(
            at: path,
            expectedIdentity: snapshot.identity.value,
            expectedManifest: snapshot.manifest.value
        )
    }

    private func removePayloadOwnerIfPresent(
        log: inout TransactionLog,
        fileSystem: SecureManagedFileSystem,
        container: SecureManagedPath
    ) throws {
        let marker = payloadOwnerPath(
            for: log,
            publishedContainer: container
        )
        guard try fileSystem.itemState(at: marker) != .missing else {
            return
        }
        try requirePayloadOwner(log: log, fileSystem: fileSystem, at: marker)
        _ = try perform(.removePayloadMarker, log: &log) {
            try removeCurrentOwnedTree(marker, in: fileSystem)
            return [:]
        }
    }

    private func requireOwner(
        log: TransactionLog,
        hostFS: SecureManagedFileSystem
    ) throws {
        let expected = try canonicalBytes(
            OwnerMarker(
                version: 1,
                transactionID: log.plan.transactionID,
                planSHA256: log.planHash
            )
        )
        let actual = try readManagedFile(
            log.plan.stageOwnerPath.value,
            root: log.plan.hostRoot
        )
        guard actual == expected else {
            throw ProfileDataTransactionError(
                .unownedData,
                operation: log.plan.operation,
                path: log.plan.stageOwnerPath.value.components.joined(
                    separator: "/"
                )
            )
        }
        _ = hostFS
    }

    private func requirePayloadOwner(
        log: TransactionLog,
        fileSystem: SecureManagedFileSystem,
        at path: SecureManagedPath
    ) throws {
        guard try fileSystem.itemState(at: path) != .missing else {
            throw ProfileDataTransactionError(
                .unownedData,
                operation: log.plan.operation,
                path: path.components.joined(separator: "/")
            )
        }
        let expected = try canonicalBytes(
            OwnerMarker(
                version: 1,
                transactionID: log.plan.transactionID,
                planSHA256: log.planHash
            )
        )
        let root = rootContaining(path: path, plan: log.plan)
        let actual = try readManagedFile(path, root: root)
        guard actual == expected else {
            throw ProfileDataTransactionError(
                .unownedData,
                operation: log.plan.operation,
                path: path.components.joined(separator: "/")
            )
        }
    }

    private func rootContaining(
        path: SecureManagedPath,
        plan: Plan
    ) -> RootBinding {
        if let destination = plan.destinationPath?.value,
           destination.components.count <= path.components.count,
           Array(path.components.prefix(destination.components.count))
            == destination.components {
            return plan.destinationRoot ?? plan.hostRoot
        }
        return plan.sourceRoot
    }

    private func requireMissing(
        _ path: SecureManagedPath,
        in fileSystem: SecureManagedFileSystem
    ) throws {
        guard try fileSystem.itemState(at: path) == .missing else {
            throw ProfileDataTransactionError(
                .unexpectedDestination,
                path: path.components.joined(separator: "/")
            )
        }
    }

    private func payloadOwnerPath(
        for log: TransactionLog,
        published: Bool
    ) -> SecureManagedPath {
        if published,
           let destination = log.plan.destinationPath?.value {
            return payloadOwnerPath(for: log, publishedContainer: destination)
        }
        return log.plan.payloadOwnerPath.value
    }

    private func payloadOwnerPath(
        for log: TransactionLog,
        publishedContainer: SecureManagedPath
    ) -> SecureManagedPath {
        do {
            return try publishedContainer.appending(
                Self.payloadOwnerPrefix
                    + log.plan.transactionID.uuidString.lowercased()
            )
        } catch {
            preconditionFailure("Validated payload owner path became invalid.")
        }
    }

    private func classifyPrimary(
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

    private func committedMutation(for plan: Plan) -> ProfileDataMutation {
        guard plan.sourceSnapshot != nil else { return .noManagedData }
        switch plan.operation {
        case .archive, .clear:
            return .archivedManagedData
        case .delete:
            return .deletedManagedData
        case .duplicate:
            return .copiedManagedData
        case .relocate:
            return .relocatedManagedData
        }
    }

    private func metadataBackupReason(
        for operation: ProfileDataTransactionOperation
    ) -> LibraryBackupReason? {
        switch operation {
        case .archive, .delete, .relocate:
            return .destructiveRewrite
        case .clear, .duplicate:
            return nil
        }
    }

    private func outcome(
        from receipt: Receipt,
        plan: Plan
    ) -> ProfileDataTransactionOutcome {
        let archiveURL: URL?
        if receipt.completion == .committed,
           receipt.dataMutation == .archivedManagedData,
           let archive = plan.archivePath?.value {
            archiveURL = absoluteURL(archive, root: plan.sourceRoot)
        } else {
            archiveURL = nil
        }
        return ProfileDataTransactionOutcome(
            transactionID: plan.transactionID,
            operation: receipt.operation,
            dataMutation: receipt.dataMutation,
            externalDataHandling: receipt.externalDataHandling,
            didArchiveData: receipt.completion == .committed
                && receipt.dataMutation == .archivedManagedData,
            archiveURL: archiveURL,
            receiptURL: controlRootURL.appendingPathComponent(
                plan.transactionID.uuidString.lowercased()
                    + ".receipt.json",
                isDirectory: false
            )
        )
    }

    private func preparedCommitIdentifier(
        request: ProfileDataTransactionRequest,
        preparedCommit: PreparedLibraryCommit
    ) -> String {
        let fields = [
            request.transactionID.uuidString.lowercased(),
            request.identity.applicationID.uuidString.lowercased(),
            request.identity.applicationStorageID.uuidString.lowercased(),
            request.identity.sourceProfileID.uuidString.lowercased(),
            request.identity.sourceProfileStorageID.uuidString.lowercased(),
            request.identity.destinationProfileID?.uuidString.lowercased() ?? "",
            request.identity.destinationProfileStorageID?.uuidString.lowercased()
                ?? "",
            request.operation.rawValue,
            String(preparedCommit.priorVersion.revision.rawValue),
            preparedCommit.priorVersion.primarySHA256 ?? "",
            String(preparedCommit.targetVersion.revision.rawValue),
            preparedCommit.targetVersion.primarySHA256 ?? "",
            LibraryPersistence.sha256(preparedCommit.targetBytes),
        ]
        return LibraryPersistence.sha256(Data(fields.joined(separator: "\n").utf8))
    }

    private func canonicalBytes<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    private func controlPlanPath(_ transactionID: UUID) throws -> SecureManagedPath {
        try SecureManagedPath([
            transactionID.uuidString.lowercased() + ".plan.json",
        ])
    }

    private func controlRecordPath(
        transactionID: UUID,
        sequence: Int
    ) throws -> SecureManagedPath {
        try SecureManagedPath([
            transactionID.uuidString.lowercased()
                + "."
                + String(format: "%06d", sequence)
                + ".record.json",
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

    private func absoluteURL(
        _ path: SecureManagedPath,
        root: RootBinding
    ) -> URL {
        path.components.reduce(root.url) {
            $0.appendingPathComponent($1)
        }
    }

    private func validateControlRoot() throws {
        let attributes = try fileSystem.attributesOfItem(at: controlRootURL)
        guard
            attributes.kind == .directory,
            attributes.identity == controlRootIdentity
        else {
            throw ProfileDataTransactionError(
                .invalidJournal,
                path: controlRootURL.path
            )
        }
    }

    private func readControlFile(_ path: SecureManagedPath) throws -> Data {
        try validateControlRoot()
        let data = try readNoFollow(
            path: path,
            rootURL: controlRootURL,
            expectedRootIdentity: controlRootIdentity
        )
        try validateControlRoot()
        return data
    }

    private func readManagedFile(
        _ path: SecureManagedPath,
        root: RootBinding
    ) throws -> Data {
        let attributes = try fileSystem.attributesOfItem(at: root.url)
        guard attributes.identity == root.identity else {
            throw ProfileDataTransactionError(
                .sourceChanged,
                path: root.path
            )
        }
        return try readNoFollow(
            path: path,
            rootURL: root.url,
            expectedRootIdentity: root.identity
        )
    }

    private func readNoFollow(
        path: SecureManagedPath,
        rootURL: URL,
        expectedRootIdentity: FileSystemObjectIdentity
    ) throws -> Data {
        var descriptor = open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(descriptor) }
        var rootStatus = stat()
        guard
            fstat(descriptor, &rootStatus) == 0,
            UInt64(rootStatus.st_dev) == expectedRootIdentity.volumeID,
            UInt64(rootStatus.st_ino) == expectedRootIdentity.fileID
        else {
            throw ProfileDataTransactionError(
                .invalidJournal,
                path: rootURL.path
            )
        }

        for component in path.components.dropLast() {
            let next = openat(
                descriptor,
                component,
                O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
            )
            guard next >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            close(descriptor)
            descriptor = next
        }
        guard let leaf = path.components.last else {
            throw ProfileDataTransactionError(.invalidJournal)
        }
        let file = openat(
            descriptor,
            leaf,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard file >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(file) }
        var status = stat()
        guard
            fstat(file, &status) == 0,
            (status.st_mode & S_IFMT) == S_IFREG,
            status.st_nlink == 1
        else {
            throw ProfileDataTransactionError(.invalidJournal)
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        let maximumBytes = 4 * 1_024 * 1_024
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            result.append(buffer, count: count)
            guard result.count <= maximumBytes else {
                throw ProfileDataTransactionError(
                    .invalidJournal,
                    path: rootURL.path
                )
            }
        }
        return result
    }
}

private extension ProfileDataTransactionCoordinator {
    enum Phase: String, Codable {
        case intent
        case effect
    }

    enum Completion: String, Codable {
        case committed
        case rolledBack
    }

    struct Event: Codable, Equatable {
        let phase: Phase
        let effect: ProfileDataTransactionEffect
    }

    struct TokenValue: Codable, Equatable {
        let revision: UInt64
        let primarySHA256: String?

        init(_ value: LibraryVersionToken) {
            revision = value.revision.rawValue
            primarySHA256 = value.primarySHA256
        }

        var value: LibraryVersionToken {
            LibraryVersionToken(
                revision: LibraryRevision(rawValue: revision),
                primarySHA256: primarySHA256
            )
        }
    }

    struct RootBinding: Codable, Equatable {
        let path: String
        let volumeID: UInt64
        let fileID: UInt64

        var url: URL {
            URL(fileURLWithPath: path, isDirectory: true)
        }

        var identity: FileSystemObjectIdentity {
            FileSystemObjectIdentity(volumeID: volumeID, fileID: fileID)
        }
    }

    struct PathValue: Codable, Equatable {
        let components: [String]

        init(_ path: SecureManagedPath) {
            components = path.components
        }

        var value: SecureManagedPath {
            // Values have already passed SecureManagedPath validation and the
            // immutable plan's canonical-byte check.
            do {
                return try SecureManagedPath(components)
            } catch {
                preconditionFailure("Validated transaction path became invalid.")
            }
        }
    }

    struct IdentityValue: Codable, Equatable {
        static let validKinds = [
            SecureManagedItemIdentity.Kind.directory.rawValue,
            SecureManagedItemIdentity.Kind.regularFile.rawValue,
        ]

        let volumeID: UInt64
        let fileID: UInt64
        let kind: String

        init(_ identity: SecureManagedItemIdentity) {
            volumeID = identity.volumeID
            fileID = identity.fileID
            kind = identity.kind.rawValue
        }

        var isValid: Bool {
            Self.validKinds.contains(kind)
        }

        var value: SecureManagedItemIdentity {
            SecureManagedItemIdentity(
                volumeID: volumeID,
                fileID: fileID,
                kind: kind == SecureManagedItemIdentity.Kind.regularFile.rawValue
                    ? .regularFile
                    : .directory
            )
        }
    }

    struct ManifestEntryValue: Codable, Equatable {
        let relativeComponents: [String]
        let kind: String
        let byteCount: UInt64
        let permissions: UInt16
        let sha256: String?
    }

    struct ManifestValue: Codable, Equatable {
        let entries: [ManifestEntryValue]

        init(_ manifest: SecureManagedManifest) {
            entries = manifest.entries.map {
                ManifestEntryValue(
                    relativeComponents: $0.relativeComponents,
                    kind: $0.kind.rawValue,
                    byteCount: $0.byteCount,
                    permissions: $0.permissions,
                    sha256: $0.sha256
                )
            }
        }

        var value: SecureManagedManifest {
            SecureManagedManifest(
                entries: entries.map {
                    SecureManagedManifest.Entry(
                        relativeComponents: $0.relativeComponents,
                        kind: $0.kind
                            == SecureManagedItemIdentity.Kind.regularFile.rawValue
                            ? .regularFile
                            : .directory,
                        byteCount: $0.byteCount,
                        permissions: $0.permissions,
                        sha256: $0.sha256
                    )
                }
            )
        }
    }

    struct ItemSnapshot: Codable, Equatable {
        let identity: IdentityValue
        let manifest: ManifestValue
    }

    struct Plan: Codable, Equatable {
        let version: Int
        let transactionID: UUID
        let identity: ProfileDataTransactionIdentity
        let operation: ProfileDataTransactionOperation
        let createdAt: Date
        let sourceRoot: RootBinding
        let sourcePath: PathValue
        let sourceSnapshot: ItemSnapshot?
        let destinationRoot: RootBinding?
        let destinationPath: PathValue?
        let archivePath: PathValue?
        let hostRoot: RootBinding
        let stagePath: PathValue
        let stageOwnerPath: PathValue
        let payloadPath: PathValue
        let payloadOwnerPath: PathValue
        let priorVersion: TokenValue
        let targetVersion: TokenValue
        let targetBytesSHA256: String
        let preparedCommitIdentifier: String
        let externalDataHandling: ProfileExternalDataHandling
    }

    struct OwnerMarker: Codable, Equatable {
        let version: Int
        let transactionID: UUID
        let planSHA256: String
    }

    struct UnsignedRecord: Codable, Equatable {
        let version: Int
        let transactionID: UUID
        let sequence: Int
        let previousSHA256: String
        let planSHA256: String
        let event: Event
        let details: [String: String]
        let recordedAt: Date
    }

    struct Record: Codable, Equatable {
        let unsigned: UnsignedRecord
        let recordSHA256: String
    }

    struct Receipt: Codable, Equatable {
        let version: Int
        let transactionID: UUID
        let planSHA256: String
        let chainHeadSHA256: String
        let identity: ProfileDataTransactionIdentity
        let operation: ProfileDataTransactionOperation
        let completion: Completion
        let dataMutation: ProfileDataMutation
        let externalDataHandling: ProfileExternalDataHandling
        let priorVersion: TokenValue
        let targetVersion: TokenValue
        let completedAt: Date
    }

    struct TransactionLog {
        let plan: Plan
        let planBytes: Data
        let planHash: String
        var records: [Record]

        var chainHead: String {
            records.last?.recordSHA256 ?? planHash
        }

        func hasEffect(_ effect: ProfileDataTransactionEffect) -> Bool {
            records.contains {
                $0.unsigned.event
                    == Event(phase: .effect, effect: effect)
            }
        }

        func hasEvent(_ effect: ProfileDataTransactionEffect) -> Bool {
            records.contains {
                $0.unsigned.event.effect == effect
            }
        }
    }
}
