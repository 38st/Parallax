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
    private enum Phase: String, Codable {
        case prepared
        case metadataCommitted
    }

    private struct Entry: Codable {
        let profileID: UUID
        let profileStorageID: UUID
        let baseRootPath: String
        let sourcePath: String
        let stagedPath: String
        let archivePath: String
        let expectedDevice: UInt64?
        let expectedInode: UInt64?
        var sourceExisted: Bool
    }

    private struct Manifest: Codable {
        let transactionID: UUID
        let applicationID: UUID
        let applicationStorageID: UUID
        let dataChoice: ApplicationRemovalDataChoice
        let priorRevision: UInt64
        let priorSHA256: String?
        let targetRevision: UInt64
        let targetSHA256: String?
        let stagingRootPath: String
        var phase: Phase
        var entries: [Entry]
    }

    private struct CompletedRecord: Codable {
        let transactionID: UUID
        let completion: ApplicationRemovalTransactionCompletion
        let dataChoice: ApplicationRemovalDataChoice
        let archivePaths: [String: String]
    }

    private let fileManager = FileManager.default
    private let journalRoot: URL
    private let now: @Sendable () -> Date
    private let transactionBoundary:
        (@Sendable (ApplicationRemovalTransactionBoundary) throws -> Void)?

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
        journalRoot = support
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent(
                "ApplicationRemovalTransactions",
                isDirectory: true
            )
        self.now = now
        self.transactionBoundary = transactionBoundary
    }

    func execute(
        _ request: ApplicationRemovalTransactionRequest,
        preparedCommit: PreparedLibraryCommit,
        repository: any LibraryRepositoryPersisting
    ) throws -> ApplicationRemovalTransactionOutcome {
        try validate(request, preparedCommit: preparedCommit)
        if let completed = try completedOutcome(
            transactionID: request.transactionID
        ) {
            return completed
        }

        var manifest = try makeManifest(
            request,
            preparedCommit: preparedCommit
        )
        try persist(manifest)

        do {
            return try repository.withExclusiveMutation(
                expectedVersion:
                    request.executionAuthorization.repositoryVersion
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
                        try persist(manifest)
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
                        try persist(manifest)
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
                try persist(manifest)
                try boundary(.afterEffectBeforeRecord(commitEffect))
                try boundary(.afterRecord(commitEffect))

                return try finishCommitted(manifest)
            }
        } catch is ApplicationRemovalTransactionInterruption {
            throw ApplicationRemovalTransactionInterruption
                .simulatedCrash
        } catch {
            if manifest.phase == .metadataCommitted
                || repositoryMatchesTarget(
                    repository,
                    manifest: manifest
                )
            {
                manifest.phase = .metadataCommitted
                try? persist(manifest)
                _ = try? finishCommitted(manifest)
            } else {
                _ = try? rollback(manifest)
            }
            throw error
        }
    }

    func pendingTransactions() throws -> [UUID] {
        guard fileManager.fileExists(atPath: journalRoot.path) else {
            return []
        }
        return try fileManager.contentsOfDirectory(
            at: journalRoot,
            includingPropertiesForKeys: nil
        )
        .filter {
            $0.pathExtension == "json"
                && !$0.lastPathComponent.hasSuffix(".completed.json")
        }
        .compactMap {
            UUID(
                uuidString:
                    $0.deletingPathExtension().lastPathComponent
            )
        }
        .sorted { $0.uuidString < $1.uuidString }
    }

    func recover(
        transactionID: UUID,
        repository: any LibraryRepositoryPersisting
    ) throws -> ApplicationRemovalTransactionOutcome {
        if let completed = try completedOutcome(
            transactionID: transactionID
        ) {
            return completed
        }
        let manifest = try loadManifest(transactionID: transactionID)
        if manifest.phase == .metadataCommitted
            || repositoryMatchesTarget(repository, manifest: manifest)
        {
            return try finishCommitted(manifest)
        }
        return try rollback(manifest)
    }

    private func validate(
        _ request: ApplicationRemovalTransactionRequest,
        preparedCommit: PreparedLibraryCommit
    ) throws {
        let authorization = request.executionAuthorization
        guard
            preparedCommit.priorVersion
                == authorization.repositoryVersion,
            Set(request.profiles.map(\.profileStorageID))
                == Set(authorization.profileStorageIDs),
            request.profiles.count
                == authorization.profileStorageIDs.count
        else {
            throw ApplicationRemovalTransactionError(
                code: .invalidRequest
            )
        }
        for profile in request.profiles {
            _ = try managedBaseRoot(
                for: profile,
                applicationStorageID:
                    authorization.applicationStorageID
            )
        }
    }

    private func makeManifest(
        _ request: ApplicationRemovalTransactionRequest,
        preparedCommit: PreparedLibraryCommit
    ) throws -> Manifest {
        let authorization = request.executionAuthorization
        let timestamp = Int64(
            (now().timeIntervalSince1970 * 1_000).rounded(.down)
        )
        var entries: [Entry] = []
        var stagingRoot: URL?
        for profile in request.profiles {
            let baseRoot = try managedBaseRoot(
                for: profile,
                applicationStorageID:
                    authorization.applicationStorageID
            )
            let transactionRoot = baseRoot
                .appendingPathComponent(".parallax", isDirectory: true)
                .appendingPathComponent(
                    "ApplicationRemovalTransactions",
                    isDirectory: true
                )
                .appendingPathComponent(
                    request.transactionID.uuidString.lowercased(),
                    isDirectory: true
                )
            if let stagingRoot, stagingRoot != transactionRoot {
                throw ApplicationRemovalTransactionError(
                    code: .invalidTarget
                )
            }
            stagingRoot = transactionRoot
            let archive = baseRoot
                .appendingPathComponent(".parallax", isDirectory: true)
                .appendingPathComponent("Archives", isDirectory: true)
                .appendingPathComponent(
                    authorization.applicationStorageID.uuidString
                        .lowercased(),
                    isDirectory: true
                )
                .appendingPathComponent(
                    profile.profileStorageID.uuidString.lowercased(),
                    isDirectory: true
                )
                .appendingPathComponent(
                    "\(timestamp)-\(request.transactionID.uuidString.lowercased())",
                    isDirectory: true
                )
            var entry = Entry(
                profileID: profile.profileID,
                profileStorageID: profile.profileStorageID,
                baseRootPath: baseRoot.path,
                sourcePath:
                    profile.managedProfileRoot.canonicalPath,
                stagedPath: transactionRoot
                    .appendingPathComponent(
                        profile.profileStorageID.uuidString
                            .lowercased(),
                        isDirectory: true
                    ).path,
                archivePath: archive.path,
                expectedDevice:
                    profile.managedProfileRoot.fileIdentity?
                        .volumeID,
                expectedInode:
                    profile.managedProfileRoot.fileIdentity?
                        .fileID,
                sourceExisted: false
            )
            if authorization.dataChoice != .keep {
                let secure = try secureFileSystem(for: entry)
                let source = try sourcePath(
                    entry,
                    applicationStorageID:
                        authorization.applicationStorageID
                )
                switch try secure.itemState(at: source) {
                case .missing:
                    guard
                        entry.expectedDevice == nil,
                        entry.expectedInode == nil
                    else {
                        throw ApplicationRemovalTransactionError(
                            code: .targetChanged
                        )
                    }
                case .present(let identity):
                    guard
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
                    entry.sourceExisted = true
                }
            }
            entries.append(entry)
        }
        let fallbackRoot = journalRoot.appendingPathComponent(
            request.transactionID.uuidString.lowercased(),
            isDirectory: true
        )
        return Manifest(
            transactionID: request.transactionID,
            applicationID: authorization.applicationID,
            applicationStorageID:
                authorization.applicationStorageID,
            dataChoice: authorization.dataChoice,
            priorRevision:
                preparedCommit.priorVersion.revision.rawValue,
            priorSHA256:
                preparedCommit.priorVersion.primarySHA256,
            targetRevision:
                preparedCommit.targetVersion.revision.rawValue,
            targetSHA256:
                preparedCommit.targetVersion.primarySHA256,
            stagingRootPath: (stagingRoot ?? fallbackRoot).path,
            phase: .prepared,
            entries: entries
        )
    }

    private func managedBaseRoot(
        for profile: ApplicationRemovalProfileTarget,
        applicationStorageID: UUID
    ) throws -> URL {
        let source = profile.managedProfileRoot.canonicalURL
            .standardizedFileURL
        var base = source
        for _ in 0..<5 {
            base.deleteLastPathComponent()
        }
        let expected = base
            .appendingPathComponent(".parallax", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(
                applicationStorageID.uuidString.lowercased(),
                isDirectory: true
            )
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(
                profile.profileStorageID.uuidString.lowercased(),
                isDirectory: true
            )
            .standardizedFileURL
        guard
            source == expected,
            base.path != "/",
            source.path.hasPrefix(base.path + "/")
        else {
            throw ApplicationRemovalTransactionError(
                code: .invalidTarget
            )
        }
        return base
    }

    private func stage(
        _ entry: inout Entry,
        manifest: Manifest
    ) throws {
        guard entry.sourceExisted else { return }
        let secure = try secureFileSystem(for: entry)
        let source = try sourcePath(
            entry,
            applicationStorageID: manifest.applicationStorageID
        )
        let staged = try stagedPath(
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
            Data(ownerMarker(manifest.transactionID).utf8),
            to: try source.appending(
                ownerMarkerName(manifest.transactionID)
            )
        )
        try secure.rename(from: source, to: staged)
    }

    private func publishArchive(
        _ entry: Entry,
        transactionID: UUID
    ) throws {
        guard entry.sourceExisted else { return }
        let secure = try secureFileSystem(for: entry)
        let staged = try stagedPath(
            entry,
            transactionID: transactionID
        )
        let archive = try archivePath(entry)
        if case .present = try secure.itemState(at: archive) {
            return
        }
        try secure.rename(from: staged, to: archive)
    }

    private func rollback(
        _ manifest: Manifest
    ) throws -> ApplicationRemovalTransactionOutcome {
        for entry in manifest.entries.reversed()
        where entry.sourceExisted {
            let secure = try secureFileSystem(for: entry)
            let source = try sourcePath(
                entry,
                applicationStorageID:
                    manifest.applicationStorageID
            )
            let staged = try stagedPath(
                entry,
                transactionID: manifest.transactionID
            )
            let archive = try archivePath(entry)
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
                        ownerMarkerName(manifest.transactionID)
                    )
                )
            }
        }
        try removeStagingRootIfPresent(manifest)
        return try recordCompletion(
            manifest,
            completion: .rolledBack,
            archiveURLs: [:]
        )
    }

    private func finishCommitted(
        _ manifest: Manifest
    ) throws -> ApplicationRemovalTransactionOutcome {
        var archives: [UUID: URL] = [:]
        switch manifest.dataChoice {
        case .keep:
            break
        case .archive:
            for entry in manifest.entries
            where entry.sourceExisted {
                let secure = try secureFileSystem(for: entry)
                let staged = try stagedPath(
                    entry,
                    transactionID: manifest.transactionID
                )
                let archive = try archivePath(entry)
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
                            ownerMarkerName(manifest.transactionID)
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
                    let secure = try secureFileSystem(for: entry)
                    let staged = try stagedPath(
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
        return try recordCompletion(
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
        let markerName = ownerMarkerName(transactionID)
        let expectedHash = LibraryPersistence.sha256(
            Data(ownerMarker(transactionID).utf8)
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

    private func ownerMarkerName(_ transactionID: UUID) -> String {
        ".parallax-owner-\(transactionID.uuidString.lowercased())"
    }

    private func ownerMarker(_ transactionID: UUID) -> String {
        "Parallax application-removal transaction \(transactionID.uuidString.lowercased())"
    }

    private func secureFileSystem(
        for entry: Entry
    ) throws -> SecureManagedFileSystem {
        try SecureManagedFileSystem(
            rootURL: URL(
                fileURLWithPath: entry.baseRootPath,
                isDirectory: true
            )
        )
    }

    private func sourcePath(
        _ entry: Entry,
        applicationStorageID: UUID
    ) throws -> SecureManagedPath {
        try SecureManagedPath([
            ".parallax",
            "Applications",
            applicationStorageID.uuidString.lowercased(),
            "Profiles",
            entry.profileStorageID.uuidString.lowercased(),
        ])
    }

    private func stagedPath(
        _ entry: Entry,
        transactionID: UUID
    ) throws -> SecureManagedPath {
        try SecureManagedPath([
            ".parallax",
            "ApplicationRemovalTransactions",
            transactionID.uuidString.lowercased(),
            entry.profileStorageID.uuidString.lowercased(),
        ])
    }

    private func stagingRootPath(
        _ transactionID: UUID
    ) throws -> SecureManagedPath {
        try SecureManagedPath([
            ".parallax",
            "ApplicationRemovalTransactions",
            transactionID.uuidString.lowercased(),
        ])
    }

    private func archivePath(
        _ entry: Entry
    ) throws -> SecureManagedPath {
        try SecureManagedPath([
            ".parallax",
            "Archives",
            URL(fileURLWithPath: entry.archivePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .lastPathComponent,
            entry.profileStorageID.uuidString.lowercased(),
            URL(fileURLWithPath: entry.archivePath)
                .lastPathComponent,
        ])
    }

    private func stagingRootExists(
        _ manifest: Manifest
    ) throws -> Bool {
        guard
            let entry = manifest.entries.first(where: {
                $0.sourceExisted
            })
        else {
            return false
        }
        let secure = try secureFileSystem(for: entry)
        if case .present =
            try secure.itemState(
                at: stagingRootPath(manifest.transactionID)
            )
        {
            return true
        }
        return false
    }

    private func removeStagingRootIfPresent(
        _ manifest: Manifest
    ) throws {
        guard
            let entry = manifest.entries.first(where: {
                $0.sourceExisted
            })
        else {
            return
        }
        let secure = try secureFileSystem(for: entry)
        let stagingRoot = try stagingRootPath(
            manifest.transactionID
        )
        if case .present =
            try secure.itemState(at: stagingRoot)
        {
            try secure.removeTree(at: stagingRoot)
        }
    }

    private func repositoryMatchesTarget(
        _ repository: any LibraryRepositoryPersisting,
        manifest: Manifest
    ) -> Bool {
        guard case .loaded(let snapshot) = repository.load() else {
            return false
        }
        return snapshot.versionToken.revision.rawValue
                == manifest.targetRevision
            && snapshot.versionToken.primarySHA256
                == manifest.targetSHA256
    }

    private func boundary(
        _ value: ApplicationRemovalTransactionBoundary
    ) throws {
        try transactionBoundary?(value)
    }

    private func persist(_ manifest: Manifest) throws {
        try fileManager.createDirectory(
            at: journalRoot,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(
            to: manifestURL(manifest.transactionID),
            options: [.atomic]
        )
    }

    private func loadManifest(
        transactionID: UUID
    ) throws -> Manifest {
        do {
            return try JSONDecoder().decode(
                Manifest.self,
                from: Data(contentsOf: manifestURL(transactionID))
            )
        } catch {
            throw ApplicationRemovalTransactionError(
                code: .transactionNotFound
            )
        }
    }

    private func recordCompletion(
        _ manifest: Manifest,
        completion: ApplicationRemovalTransactionCompletion,
        archiveURLs: [UUID: URL]
    ) throws -> ApplicationRemovalTransactionOutcome {
        try fileManager.createDirectory(
            at: journalRoot,
            withIntermediateDirectories: true
        )
        let record = CompletedRecord(
            transactionID: manifest.transactionID,
            completion: completion,
            dataChoice: manifest.dataChoice,
            archivePaths: Dictionary(
                uniqueKeysWithValues: archiveURLs.map {
                    ($0.key.uuidString, $0.value.path)
                }
            )
        )
        try JSONEncoder().encode(record).write(
            to: completedURL(manifest.transactionID),
            options: [.atomic]
        )
        try? fileManager.removeItem(
            at: manifestURL(manifest.transactionID)
        )
        return ApplicationRemovalTransactionOutcome(
            transactionID: manifest.transactionID,
            completion: completion,
            dataChoice: manifest.dataChoice,
            archiveURLs: archiveURLs
        )
    }

    private func completedOutcome(
        transactionID: UUID
    ) throws -> ApplicationRemovalTransactionOutcome? {
        let url = completedURL(transactionID)
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let record = try JSONDecoder().decode(
            CompletedRecord.self,
            from: Data(contentsOf: url)
        )
        return ApplicationRemovalTransactionOutcome(
            transactionID: record.transactionID,
            completion: record.completion,
            dataChoice: record.dataChoice,
            archiveURLs: Dictionary(
                uniqueKeysWithValues:
                    record.archivePaths.compactMap {
                        key,
                        path in
                        UUID(uuidString: key).map {
                            ($0, URL(fileURLWithPath: path))
                        }
                    }
            )
        )
    }

    private func manifestURL(_ transactionID: UUID) -> URL {
        journalRoot.appendingPathComponent(
            "\(transactionID.uuidString.lowercased()).json"
        )
    }

    private func completedURL(_ transactionID: UUID) -> URL {
        journalRoot.appendingPathComponent(
            "\(transactionID.uuidString.lowercased()).completed.json"
        )
    }
}
