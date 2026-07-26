import Foundation
import Darwin

struct LibraryMigrationBlocker: Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        case reservedArchiveAmbiguity
        case caseInsensitiveSourceCollision
        case canonicalSourceCollision
        case unsafeLegacyStorageName
        case sharedApplicationRoot
        case unexpectedDestination
        case invalidBaseStorageRoot
        case sourceOutsideManagedRoot
        case unsupportedSourceItem
    }

    let kind: Kind
    let recordOccurrences: [Int]
    let canonicalPaths: [String]
}

struct LibraryMigrationPlan: Hashable, Sendable {
    let blockers: [LibraryMigrationBlocker]
}

struct LibraryMigrationReceipt: Hashable, Sendable, Codable {
    let schemaVersion: Int
    let migrationID: UUID
    let sourceFormat: String
    let sourceSHA256: String
    let sourceByteCount: Int
    let targetSHA256: String
    let backupRelativePath: String
    let startedAt: Date
    let completedAt: Date
    let committedAt: Date
    let legacyDataRetention: String
    let applicationMappings: [LibraryMigrationApplicationMapping]
    let mappings: [LibraryMigrationPathMapping]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case migrationID
        case sourceFormat
        case sourceSHA256
        case sourceByteCount
        case targetSHA256
        case backupRelativePath
        case startedAt
        case completedAt
        case committedAt
        case legacyDataRetention
        case applicationMappings
        case mappings
    }

    init(
        schemaVersion: Int,
        migrationID: UUID,
        sourceFormat: String,
        sourceSHA256: String,
        sourceByteCount: Int,
        targetSHA256: String,
        backupRelativePath: String,
        startedAt: Date,
        completedAt: Date,
        committedAt: Date,
        legacyDataRetention: String,
        applicationMappings: [LibraryMigrationApplicationMapping],
        mappings: [LibraryMigrationPathMapping]
    ) {
        self.schemaVersion = schemaVersion
        self.migrationID = migrationID
        self.sourceFormat = sourceFormat
        self.sourceSHA256 = sourceSHA256
        self.sourceByteCount = sourceByteCount
        self.targetSHA256 = targetSHA256
        self.backupRelativePath = backupRelativePath
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.committedAt = committedAt
        self.legacyDataRetention = legacyDataRetention
        self.applicationMappings = applicationMappings
        self.mappings = mappings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let migrationString = try container.decode(String.self, forKey: .migrationID)
        guard let migrationID = UUID(uuidString: migrationString) else {
            throw LibraryMigrationError.invalidJournal
        }
        self.migrationID = migrationID
        sourceFormat = try container.decode(String.self, forKey: .sourceFormat)
        sourceSHA256 = try container.decode(String.self, forKey: .sourceSHA256)
        sourceByteCount = try container.decode(Int.self, forKey: .sourceByteCount)
        targetSHA256 = try container.decode(String.self, forKey: .targetSHA256)
        backupRelativePath = try container.decode(
            String.self,
            forKey: .backupRelativePath
        )
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
        committedAt = try container.decode(Date.self, forKey: .committedAt)
        legacyDataRetention = try container.decode(
            String.self,
            forKey: .legacyDataRetention
        )
        applicationMappings = try container.decode(
            [LibraryMigrationApplicationMapping].self,
            forKey: .applicationMappings
        )
        mappings = try container.decode(
            [LibraryMigrationPathMapping].self,
            forKey: .mappings
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(
            migrationID.uuidString.lowercased(),
            forKey: .migrationID
        )
        try container.encode(sourceFormat, forKey: .sourceFormat)
        try container.encode(sourceSHA256, forKey: .sourceSHA256)
        try container.encode(sourceByteCount, forKey: .sourceByteCount)
        try container.encode(targetSHA256, forKey: .targetSHA256)
        try container.encode(backupRelativePath, forKey: .backupRelativePath)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(committedAt, forKey: .committedAt)
        try container.encode(legacyDataRetention, forKey: .legacyDataRetention)
        try container.encode(applicationMappings, forKey: .applicationMappings)
        try container.encode(mappings, forKey: .mappings)
    }
}

struct LibraryMigrationApplicationMapping: Hashable, Sendable, Codable {
    let applicationOccurrence: Int
    let oldApplicationID: UUID
    let newApplicationID: UUID
    let applicationStorageID: UUID

    private enum CodingKeys: String, CodingKey {
        case applicationOccurrence
        case oldApplicationID
        case newApplicationID
        case applicationStorageID
    }

    init(
        applicationOccurrence: Int,
        oldApplicationID: UUID,
        newApplicationID: UUID,
        applicationStorageID: UUID
    ) {
        self.applicationOccurrence = applicationOccurrence
        self.oldApplicationID = oldApplicationID
        self.newApplicationID = newApplicationID
        self.applicationStorageID = applicationStorageID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        applicationOccurrence = try container.decode(
            Int.self,
            forKey: .applicationOccurrence
        )
        oldApplicationID = try Self.uuid(
            try container.decode(String.self, forKey: .oldApplicationID)
        )
        newApplicationID = try Self.uuid(
            try container.decode(String.self, forKey: .newApplicationID)
        )
        applicationStorageID = try Self.uuid(
            try container.decode(String.self, forKey: .applicationStorageID)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(applicationOccurrence, forKey: .applicationOccurrence)
        try container.encode(
            oldApplicationID.uuidString.lowercased(),
            forKey: .oldApplicationID
        )
        try container.encode(
            newApplicationID.uuidString.lowercased(),
            forKey: .newApplicationID
        )
        try container.encode(
            applicationStorageID.uuidString.lowercased(),
            forKey: .applicationStorageID
        )
    }

    private static func uuid(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw LibraryMigrationError.invalidJournal
        }
        return uuid
    }
}

struct LibraryMigrationPathMapping: Hashable, Sendable, Codable {
    enum Disposition: String, Hashable, Sendable, Codable {
        case retainedInPlace
        case missing
    }

    enum IsolationConfiguration: String, Hashable, Sendable, Codable {
        case generated
        case external
        case none
        case requiresReview
    }

    let applicationOccurrence: Int
    let profileOccurrence: Int
    let oldApplicationID: UUID
    let newApplicationID: UUID
    let applicationStorageID: UUID
    let oldProfileID: UUID
    let newProfileID: UUID
    let profileStorageID: UUID
    let oldCanonicalPath: String
    let newCanonicalPath: String
    let disposition: Disposition
    let isolationConfiguration: IsolationConfiguration
    let sourceManifestSHA256: String?

    private enum CodingKeys: String, CodingKey {
        case applicationOccurrence
        case profileOccurrence
        case oldApplicationID
        case newApplicationID
        case applicationStorageID
        case oldProfileID
        case newProfileID
        case profileStorageID
        case oldCanonicalPath
        case newCanonicalPath
        case disposition
        case isolationConfiguration
        case sourceManifestSHA256
    }

    init(
        applicationOccurrence: Int,
        profileOccurrence: Int,
        oldApplicationID: UUID,
        newApplicationID: UUID,
        applicationStorageID: UUID,
        oldProfileID: UUID,
        newProfileID: UUID,
        profileStorageID: UUID,
        oldCanonicalPath: String,
        newCanonicalPath: String,
        disposition: Disposition,
        isolationConfiguration: IsolationConfiguration,
        sourceManifestSHA256: String?
    ) {
        self.applicationOccurrence = applicationOccurrence
        self.profileOccurrence = profileOccurrence
        self.oldApplicationID = oldApplicationID
        self.newApplicationID = newApplicationID
        self.applicationStorageID = applicationStorageID
        self.oldProfileID = oldProfileID
        self.newProfileID = newProfileID
        self.profileStorageID = profileStorageID
        self.oldCanonicalPath = oldCanonicalPath
        self.newCanonicalPath = newCanonicalPath
        self.disposition = disposition
        self.isolationConfiguration = isolationConfiguration
        self.sourceManifestSHA256 = sourceManifestSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        applicationOccurrence = try container.decode(
            Int.self,
            forKey: .applicationOccurrence
        )
        profileOccurrence = try container.decode(Int.self, forKey: .profileOccurrence)
        oldApplicationID = try Self.decodeUUID(
            from: container,
            key: .oldApplicationID
        )
        newApplicationID = try Self.decodeUUID(
            from: container,
            key: .newApplicationID
        )
        applicationStorageID = try Self.decodeUUID(
            from: container,
            key: .applicationStorageID
        )
        oldProfileID = try Self.decodeUUID(from: container, key: .oldProfileID)
        newProfileID = try Self.decodeUUID(from: container, key: .newProfileID)
        profileStorageID = try Self.decodeUUID(
            from: container,
            key: .profileStorageID
        )
        oldCanonicalPath = try container.decode(String.self, forKey: .oldCanonicalPath)
        newCanonicalPath = try container.decode(String.self, forKey: .newCanonicalPath)
        disposition = try container.decode(Disposition.self, forKey: .disposition)
        isolationConfiguration = try container.decode(
            IsolationConfiguration.self,
            forKey: .isolationConfiguration
        )
        sourceManifestSHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .sourceManifestSHA256
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(applicationOccurrence, forKey: .applicationOccurrence)
        try container.encode(profileOccurrence, forKey: .profileOccurrence)
        try Self.encode(oldApplicationID, to: &container, key: .oldApplicationID)
        try Self.encode(newApplicationID, to: &container, key: .newApplicationID)
        try Self.encode(applicationStorageID, to: &container, key: .applicationStorageID)
        try Self.encode(oldProfileID, to: &container, key: .oldProfileID)
        try Self.encode(newProfileID, to: &container, key: .newProfileID)
        try Self.encode(profileStorageID, to: &container, key: .profileStorageID)
        try container.encode(oldCanonicalPath, forKey: .oldCanonicalPath)
        try container.encode(newCanonicalPath, forKey: .newCanonicalPath)
        try container.encode(disposition, forKey: .disposition)
        try container.encode(isolationConfiguration, forKey: .isolationConfiguration)
        try container.encodeIfPresent(
            sourceManifestSHA256,
            forKey: .sourceManifestSHA256
        )
    }

    private static func decodeUUID(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> UUID {
        let value = try container.decode(String.self, forKey: key)
        guard let uuid = UUID(uuidString: value) else {
            throw LibraryMigrationError.invalidJournal
        }
        return uuid
    }

    private static func encode(
        _ uuid: UUID,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws {
        try container.encode(uuid.uuidString.lowercased(), forKey: key)
    }
}

enum LibraryMigrationOutcome: Hashable, Sendable {
    case current([ManagedApplication])
    case migrated([ManagedApplication], LibraryMigrationReceipt)
    case requiresResolution(LibraryMigrationPlan)
}

enum LibraryMigrationError: LocalizedError, Equatable {
    case sourceChanged
    case recoveryConflict
    case invalidJournal
    case unsupportedSourceItem(String)

    var errorDescription: String? {
        switch self {
        case .sourceChanged:
            String(localized: "Legacy profile data changed while it was being migrated.")
        case .recoveryConflict:
            String(localized: "Migration recovery found library data that matches neither the original nor the committed version.")
        case .invalidJournal:
            String(localized: "The migration recovery journal is invalid.")
        case let .unsupportedSourceItem(path):
            String(localized: "The legacy profile contains an unsupported filesystem item at \(path).")
        }
    }
}

struct LibraryMigrationCoordinator: Sendable {
    private static let schemaVersion = 1
    private static let ownerFileName = ".parallax-migration-owner"
    private static let applicationUUID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000001"
    ) ?? UUID()
    private static let profileUUID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000002"
    ) ?? UUID()

    private let fileSystem: any FileSystem
    private let applicationSupportURL: URL
    private let uuidGenerator: @Sendable () -> UUID
    private let now: @Sendable () -> Date

    init(
        fileSystem: any FileSystem,
        applicationSupportURL: URL,
        uuidGenerator: @escaping @Sendable () -> UUID = UUID.init,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileSystem = fileSystem
        self.applicationSupportURL = applicationSupportURL
        self.uuidGenerator = uuidGenerator
        self.now = now
    }

    func migrateIfNeeded() throws -> LibraryMigrationOutcome {
        let persistence = LibraryPersistence(
            fileSystem: fileSystem,
            applicationSupportURL: applicationSupportURL
        )
        switch try persistence.loadSnapshot() {
        case .missing:
            return .current([])
        case let .current(applications):
            return try recoverCommittedMigrationIfNeeded(
                applications: applications
            ) ?? .current(applications)
        case let .legacy(snapshot):
            return try migrate(snapshot: snapshot)
        }
    }

    private func migrate(
        snapshot: LegacyLibrarySnapshot
    ) throws -> LibraryMigrationOutcome {
        let resumableJournal = try journal(matchingSourceHash: snapshot.sourceSHA256)
        let sourceInventory = try inventorySources(in: snapshot.library)
        guard sourceInventory.blockers.isEmpty else {
            return .requiresResolution(
                LibraryMigrationPlan(blockers: sourceInventory.blockers)
            )
        }
        if let resumableJournal {
            try validate(
                journal: resumableJournal,
                against: snapshot.library,
                sources: sourceInventory.profiles
            )
            try rollbackOwnedState(
                for: resumableJournal,
                sourceRecords: sourceInventory.profiles
            )
        }

        let allocation = try allocate(
            snapshot: snapshot,
            sources: sourceInventory.profiles,
            existingJournal: resumableJournal
        )
        guard allocation.blockers.isEmpty else {
            return .requiresResolution(
                LibraryMigrationPlan(blockers: allocation.blockers)
            )
        }

        let journal = allocation.journal
        do {
            try prepareControlState(
                journal: journal,
                originalBytes: snapshot.originalBytes
            )
            try executeCopies(journal: journal, sourceRecords: allocation.records)
            try verifyPrimaryStillMatches(snapshot)
            try writePendingReceipt(for: journal)
            try commitLibrary(
                journal: journal,
                applications: allocation.applications,
                sourceRecords: allocation.records.map(\.source)
            )
        } catch {
            try cleanUnjournaledControlStateIfNeeded(journal: journal)
            let primaryHash = try? currentPrimaryHash()
            if primaryHash == journal.sourceSHA256 {
                do {
                    try rollbackOwnedState(
                        for: journal,
                        sourceRecords: allocation.records.map(\.source)
                    )
                } catch {
                    try? markRollbackRequired(
                        journal: journal,
                        reason: "precommitCleanupFailed"
                    )
                }
            } else if primaryHash != journal.targetSHA256 {
                throw LibraryMigrationError.recoveryConflict
            }
            throw error
        }

        try validateRetainedLegacySources(for: journal)
        try validate(journal: journal, against: allocation.applications)
        try verifyPublishedDestinations(journal)
        let receipt = try finalizeCommittedMigration(journal: journal)
        return .migrated(allocation.applications, receipt)
    }
}

// MARK: - Inventory and planning

private extension LibraryMigrationCoordinator {
    struct SourceRecord: Sendable {
        let applicationOccurrence: Int
        let profileOccurrence: Int
        let legacyApplication: LegacyManagedApplication
        let legacyProfile: LegacyLaunchProfile
        let baseRoot: URL
        let canonicalBaseRoot: URL
        let applicationRoot: URL
        let sourceURL: URL
        let canonicalSourceURL: URL
        let sourceExists: Bool
        let sourceIdentity: FileSystemObjectIdentity?
        let sourceManifest: DirectoryManifest?
    }

    struct SourceInventory {
        let profiles: [SourceRecord]
        let blockers: [LibraryMigrationBlocker]
    }

    struct PlannedRecord: Sendable {
        let source: SourceRecord
        let paths: ResolvedProfilePaths
        let mapping: LibraryMigrationPathMapping
    }

    struct Allocation {
        let applications: [ManagedApplication]
        let records: [PlannedRecord]
        let journal: MigrationJournal
        let blockers: [LibraryMigrationBlocker]
    }

    func inventorySources(in legacy: LegacyLibrary) throws -> SourceInventory {
        var records: [SourceRecord] = []
        var blockers: [LibraryMigrationBlocker] = []
        var applicationRootGroups: [String: [Int]] = [:]
        var profileOccurrence = 0

        for (applicationOccurrence, application) in legacy.applications.enumerated() {
            let basePath = legacyBasePath(for: application)
            let baseResolution: (configured: URL, canonical: URL)
            do {
                let paths = try ManagedPathResolver(fileSystem: fileSystem).resolve(
                    configuredBaseRoot: basePath,
                    applicationStorageID: Self.applicationUUID,
                    profileStorageID: Self.profileUUID
                )
                guard
                    try attributesIfExists(
                        at: paths.profileRoot.validationContext.configuredBaseRootURL
                    ) != nil
                else {
                    throw ManagedPathError(
                        .baseRootUnavailable,
                        path: basePath
                    )
                }
                baseResolution = (
                    paths.profileRoot.validationContext.configuredBaseRootURL,
                    paths.profileRoot.validationContext.canonicalBaseRootURL
                )
            } catch {
                blockers.append(
                    LibraryMigrationBlocker(
                        kind: .invalidBaseStorageRoot,
                        recordOccurrences: [applicationOccurrence],
                        canonicalPaths: [basePath]
                    )
                )
                profileOccurrence += application.profiles.count
                continue
            }

            let applicationComponent = legacySanitizedComponent(application.displayName)
            let applicationRoot = baseResolution.configured.appendingPathComponent(
                applicationComponent,
                isDirectory: true
            )
            let canonicalApplicationRoot = canonicalExistingOrExpected(
                applicationRoot,
                canonicalBase: baseResolution.canonical,
                relativeComponents: [applicationComponent]
            )
            if try attributesIfExists(at: applicationRoot) != nil {
                let applicationRootKey = compatibilityKey(canonicalApplicationRoot.path)
                applicationRootGroups[applicationRootKey, default: []].append(
                    applicationOccurrence
                )
            }

            for profile in application.profiles {
                defer { profileOccurrence += 1 }
                let rawComponent = profile.storageName
                    ?? legacySanitizedComponent(profile.name)
                guard isSafeLegacyComponent(rawComponent) else {
                    blockers.append(
                        LibraryMigrationBlocker(
                            kind: .unsafeLegacyStorageName,
                            recordOccurrences: [profileOccurrence],
                            canonicalPaths: []
                        )
                    )
                    continue
                }

                if compatibilityKey(rawComponent) == compatibilityKey("Archives") {
                    blockers.append(
                        LibraryMigrationBlocker(
                            kind: .reservedArchiveAmbiguity,
                            recordOccurrences: [profileOccurrence],
                            canonicalPaths: [applicationRoot.path]
                        )
                    )
                    continue
                }

                let sourceURL = applicationRoot.appendingPathComponent(
                    rawComponent,
                    isDirectory: true
                )
                let sourceAttributes: FileSystemItemAttributes?
                do {
                    sourceAttributes = try attributesIfExists(at: sourceURL)
                } catch {
                    blockers.append(
                        LibraryMigrationBlocker(
                            kind: .unsupportedSourceItem,
                            recordOccurrences: [profileOccurrence],
                            canonicalPaths: [sourceURL.path]
                        )
                    )
                    continue
                }
                let sourceExists = sourceAttributes != nil
                var canonicalSourceURL = baseResolution.canonical
                    .appendingPathComponent(applicationComponent, isDirectory: true)
                    .appendingPathComponent(rawComponent, isDirectory: true)
                var manifest: DirectoryManifest?
                var sourceIdentity: FileSystemObjectIdentity?

                if sourceExists {
                    do {
                        guard let sourceAttributes,
                              sourceAttributes.kind == .directory else {
                            blockers.append(
                                LibraryMigrationBlocker(
                                    kind: .unsupportedSourceItem,
                                    recordOccurrences: [profileOccurrence],
                                    canonicalPaths: [sourceURL.path]
                                )
                            )
                            continue
                        }
                        canonicalSourceURL = try fileSystem
                            .canonicalURL(for: sourceURL)
                            .standardizedFileURL
                        sourceIdentity = sourceAttributes.identity
                    } catch {
                        blockers.append(
                            LibraryMigrationBlocker(
                                kind: .unsupportedSourceItem,
                                recordOccurrences: [profileOccurrence],
                                canonicalPaths: [sourceURL.path]
                            )
                        )
                        continue
                    }

                    guard contains(canonicalSourceURL, within: baseResolution.canonical) else {
                        blockers.append(
                            LibraryMigrationBlocker(
                                kind: .sourceOutsideManagedRoot,
                                recordOccurrences: [profileOccurrence],
                                canonicalPaths: [canonicalSourceURL.path]
                            )
                        )
                        continue
                    }
                    do {
                        manifest = try directoryManifest(at: sourceURL)
                    } catch {
                        blockers.append(
                            LibraryMigrationBlocker(
                                kind: .unsupportedSourceItem,
                                recordOccurrences: [profileOccurrence],
                                canonicalPaths: [sourceURL.path]
                            )
                        )
                        continue
                    }
                }

                records.append(
                    SourceRecord(
                        applicationOccurrence: applicationOccurrence,
                        profileOccurrence: profileOccurrence,
                        legacyApplication: application,
                        legacyProfile: profile,
                        baseRoot: baseResolution.configured,
                        canonicalBaseRoot: baseResolution.canonical,
                        applicationRoot: canonicalApplicationRoot,
                        sourceURL: sourceURL,
                        canonicalSourceURL: canonicalSourceURL,
                        sourceExists: sourceExists,
                        sourceIdentity: sourceIdentity,
                        sourceManifest: manifest
                    )
                )
            }
        }

        for (key, occurrences) in applicationRootGroups
            where Set(occurrences).count > 1 {
            blockers.append(
                LibraryMigrationBlocker(
                    kind: .sharedApplicationRoot,
                    recordOccurrences: occurrences.sorted(),
                    canonicalPaths: [key]
                )
            )
        }

        let existingRecords = records.filter(\.sourceExists)
        let exactGroups = Dictionary(grouping: existingRecords) {
            $0.canonicalSourceURL.standardizedFileURL.path
        }
        for (path, group) in exactGroups where group.count > 1 {
            blockers.append(
                LibraryMigrationBlocker(
                    kind: .canonicalSourceCollision,
                    recordOccurrences: group.map(\.profileOccurrence).sorted(),
                    canonicalPaths: [path]
                )
            )
        }

        let identityGroups = Dictionary(grouping: existingRecords.compactMap {
            record in record.sourceIdentity.map { ($0, record) }
        }, by: \.0)
        for (_, identified) in identityGroups where identified.count > 1 {
            let group = identified.map(\.1)
            blockers.append(
                LibraryMigrationBlocker(
                    kind: .canonicalSourceCollision,
                    recordOccurrences: group.map(\.profileOccurrence).sorted(),
                    canonicalPaths: Set(group.map(\.canonicalSourceURL.path)).sorted()
                )
            )
        }

        let compatibilityGroups = Dictionary(grouping: existingRecords) {
            compatibilityKey($0.sourceURL.standardizedFileURL.path)
        }
        for (_, group) in compatibilityGroups where group.count > 1 {
            let exactPaths = Set(group.map { $0.sourceURL.standardizedFileURL.path })
            if exactPaths.count > 1 {
                blockers.append(
                    LibraryMigrationBlocker(
                        kind: .caseInsensitiveSourceCollision,
                        recordOccurrences: group.map(\.profileOccurrence).sorted(),
                        canonicalPaths: exactPaths.sorted()
                    )
                )
            }
        }

        for leftIndex in existingRecords.indices {
            for rightIndex in existingRecords.indices where rightIndex > leftIndex {
                let left = existingRecords[leftIndex]
                let right = existingRecords[rightIndex]
                if contains(left.canonicalSourceURL, within: right.canonicalSourceURL)
                    || contains(right.canonicalSourceURL, within: left.canonicalSourceURL) {
                    blockers.append(
                        LibraryMigrationBlocker(
                            kind: .canonicalSourceCollision,
                            recordOccurrences: [
                                left.profileOccurrence,
                                right.profileOccurrence
                            ].sorted(),
                            canonicalPaths: [
                                left.canonicalSourceURL.path,
                                right.canonicalSourceURL.path
                            ].sorted()
                        )
                    )
                }
            }
        }

        return SourceInventory(
            profiles: records,
            blockers: uniqueBlockers(blockers)
        )
    }

    func allocate(
        snapshot: LegacyLibrarySnapshot,
        sources: [SourceRecord],
        existingJournal: MigrationJournal?
    ) throws -> Allocation {
        if let existingJournal {
            return try allocation(
                snapshot: snapshot,
                sources: sources,
                journal: existingJournal
            )
        }

        var occupied = Set(snapshot.library.applications.map(\.id))
        occupied.formUnion(snapshot.library.applications.flatMap(\.profiles).map(\.id))
        let migrationID = nextUniqueUUID(occupied: &occupied)

        var applicationStorageIDs: [UUID] = []
        for _ in snapshot.library.applications {
            applicationStorageIDs.append(nextUniqueUUID(occupied: &occupied))
        }

        var profileStorageIDs: [UUID] = []
        for _ in snapshot.library.applications.flatMap(\.profiles) {
            profileStorageIDs.append(nextUniqueUUID(occupied: &occupied))
        }

        let duplicateApplicationIDs = duplicateValues(
            snapshot.library.applications.map(\.id)
        )
        let duplicateProfileIDs = duplicateValues(
            snapshot.library.applications.flatMap(\.profiles).map(\.id)
        )
        let newApplicationIDs = snapshot.library.applications.map { application in
            duplicateApplicationIDs.contains(application.id)
                ? nextUniqueUUID(occupied: &occupied)
                : application.id
        }
        let newProfileIDs = snapshot.library.applications
            .flatMap(\.profiles)
            .map { profile in
                duplicateProfileIDs.contains(profile.id)
                    ? nextUniqueUUID(occupied: &occupied)
                    : profile.id
            }

        let provisionalJournal = MigrationJournal(
            schemaVersion: Self.schemaVersion,
            migrationID: migrationID,
            sourceFormat: sourceFormat(snapshot.library.format),
            sourceSHA256: snapshot.sourceSHA256,
            sourceByteCount: snapshot.sourceByteCount,
            targetSHA256: "",
            createdAt: now(),
            applicationMappings: [],
            mappings: []
        )
        return try allocation(
            snapshot: snapshot,
            sources: sources,
            journal: provisionalJournal,
            applicationStorageIDs: applicationStorageIDs,
            profileStorageIDs: profileStorageIDs,
            applicationIDs: newApplicationIDs,
            profileIDs: newProfileIDs
        )
    }

    func allocation(
        snapshot: LegacyLibrarySnapshot,
        sources: [SourceRecord],
        journal: MigrationJournal
    ) throws -> Allocation {
        let applicationMappings = journal.applicationMappings.sorted {
            $0.applicationOccurrence < $1.applicationOccurrence
        }
        let mappings = journal.mappings.sorted { $0.profileOccurrence < $1.profileOccurrence }
        guard applicationMappings.count == snapshot.library.applications.count else {
            throw LibraryMigrationError.invalidJournal
        }
        guard mappings.count == snapshot.library.applications.flatMap(\.profiles).count else {
            throw LibraryMigrationError.invalidJournal
        }

        let applicationStorageIDs = applicationMappings.map(\.applicationStorageID)
        let applicationIDs = applicationMappings.map(\.newApplicationID)
        var profileStorageIDs = Array(
            repeating: Self.profileUUID,
            count: mappings.count
        )
        var profileIDs = snapshot.library.applications.flatMap(\.profiles).map(\.id)
        for mapping in mappings {
            guard
                mapping.applicationOccurrence < applicationStorageIDs.count,
                mapping.profileOccurrence < profileStorageIDs.count
            else {
                throw LibraryMigrationError.invalidJournal
            }
            profileStorageIDs[mapping.profileOccurrence] = mapping.profileStorageID
            profileIDs[mapping.profileOccurrence] = mapping.newProfileID
        }

        return try allocation(
            snapshot: snapshot,
            sources: sources,
            journal: journal,
            applicationStorageIDs: applicationStorageIDs,
            profileStorageIDs: profileStorageIDs,
            applicationIDs: applicationIDs,
            profileIDs: profileIDs
        )
    }

    func allocation(
        snapshot: LegacyLibrarySnapshot,
        sources: [SourceRecord],
        journal: MigrationJournal,
        applicationStorageIDs: [UUID],
        profileStorageIDs: [UUID],
        applicationIDs: [UUID],
        profileIDs: [UUID]
    ) throws -> Allocation {
        var plannedRecords: [PlannedRecord] = []
        var applications: [ManagedApplication] = []
        var blockers: [LibraryMigrationBlocker] = []
        var globalProfileOccurrence = 0

        for (applicationOccurrence, legacyApplication) in
            snapshot.library.applications.enumerated() {
            var profiles: [LaunchProfile] = []
            for legacyProfile in legacyApplication.profiles {
                guard let source = sources.first(where: {
                    $0.profileOccurrence == globalProfileOccurrence
                }) else {
                    throw LibraryMigrationError.invalidJournal
                }
                let paths = try ManagedPathResolver(fileSystem: fileSystem).resolve(
                    baseRootURL: source.baseRoot,
                    applicationStorageID: applicationStorageIDs[applicationOccurrence],
                    profileStorageID: profileStorageIDs[globalProfileOccurrence]
                )
                let isolation = isolationConfiguration(
                    profile: legacyProfile,
                    source: source
                )
                let mapping = LibraryMigrationPathMapping(
                    applicationOccurrence: applicationOccurrence,
                    profileOccurrence: globalProfileOccurrence,
                    oldApplicationID: legacyApplication.id,
                    newApplicationID: applicationIDs[applicationOccurrence],
                    applicationStorageID: applicationStorageIDs[applicationOccurrence],
                    oldProfileID: legacyProfile.id,
                    newProfileID: profileIDs[globalProfileOccurrence],
                    profileStorageID: profileStorageIDs[globalProfileOccurrence],
                    oldCanonicalPath: source.canonicalSourceURL.path,
                    newCanonicalPath: paths.profileRoot.url.path,
                    disposition: source.sourceExists ? .retainedInPlace : .missing,
                    isolationConfiguration: isolation,
                    sourceManifestSHA256: source.sourceManifest.map(
                        manifestSHA256
                    )
                )
                if try attributesIfExists(at: paths.profileRoot.url) != nil {
                    let ownedPublication = try readPublicationState(
                        journal: journal,
                        mapping: mapping
                    )
                    let matchesOwnedManifest: Bool
                    if let expected = mapping.sourceManifestSHA256,
                       ownedPublication != nil {
                        matchesOwnedManifest =
                            manifestSHA256(
                                try directoryManifest(at: paths.profileRoot.url)
                            ) == expected
                    } else {
                        matchesOwnedManifest = false
                    }
                    if !matchesOwnedManifest {
                        blockers.append(
                            LibraryMigrationBlocker(
                                kind: .unexpectedDestination,
                                recordOccurrences: [globalProfileOccurrence],
                                canonicalPaths: [paths.profileRoot.url.path]
                            )
                        )
                    }
                }

                let rewritten = rewrittenConfiguration(
                    profile: legacyProfile,
                    source: source,
                    destination: paths
                )
                profiles.append(
                    LaunchProfile(
                        id: profileIDs[globalProfileOccurrence],
                        storageID: profileStorageIDs[globalProfileOccurrence],
                        name: legacyProfile.name,
                        argumentsText: rewritten.arguments,
                        environmentText: rewritten.environment,
                        notes: legacyProfile.notes,
                        lastLaunchedAt: legacyProfile.lastLaunchedAt
                    )
                )
                plannedRecords.append(
                    PlannedRecord(source: source, paths: paths, mapping: mapping)
                )
                globalProfileOccurrence += 1
            }

            applications.append(
                ManagedApplication(
                    id: applicationIDs[applicationOccurrence],
                    storageID: applicationStorageIDs[applicationOccurrence],
                    displayName: legacyApplication.displayName,
                    bundleIdentifier: legacyApplication.bundleIdentifier,
                    appPath: legacyApplication.appPath,
                    preset: legacyApplication.preset,
                    baseStoragePath: try canonicalBasePath(
                        for: legacyApplication,
                        applicationOccurrence: applicationOccurrence,
                        sources: sources
                    ),
                    profiles: profiles
                )
            )
        }

        try LibraryPersistence.validateCurrentApplications(applications)
        let targetData = try encodedLibrary(applications)
        let completeJournal = MigrationJournal(
            schemaVersion: journal.schemaVersion,
            migrationID: journal.migrationID,
            sourceFormat: journal.sourceFormat,
            sourceSHA256: journal.sourceSHA256,
            sourceByteCount: journal.sourceByteCount,
            targetSHA256: LibraryPersistence.sha256(targetData),
            createdAt: journal.createdAt,
            applicationMappings: snapshot.library.applications.enumerated().map {
                occurrence, legacyApplication in
                LibraryMigrationApplicationMapping(
                    applicationOccurrence: occurrence,
                    oldApplicationID: legacyApplication.id,
                    newApplicationID: applicationIDs[occurrence],
                    applicationStorageID: applicationStorageIDs[occurrence]
                )
            },
            mappings: plannedRecords.map(\.mapping)
        )
        return Allocation(
            applications: applications,
            records: plannedRecords,
            journal: completeJournal,
            blockers: uniqueBlockers(blockers)
        )
    }
}

// MARK: - Transaction

private extension LibraryMigrationCoordinator {
    func prepareControlState(
        journal: MigrationJournal,
        originalBytes: Data
    ) throws {
        let paths = controlPaths(for: journal.migrationID)
        if !fileSystem.fileExists(at: paths.directory) {
            try fileSystem.createDirectory(
                at: paths.directory,
                withIntermediateDirectories: true
            )
            try fileSystem.setPOSIXPermissions(0o700, at: migrationsRootURL)
            try fileSystem.setPOSIXPermissions(0o700, at: paths.directory)
        }

        if fileSystem.fileExists(at: paths.backup) {
            let existing = try fileSystem.readData(at: paths.backup)
            guard
                existing == originalBytes,
                LibraryPersistence.sha256(existing) == journal.sourceSHA256
            else {
                throw LibraryMigrationError.recoveryConflict
            }
        } else {
            try publishControlData(
                originalBytes,
                to: paths.backup,
                parent: paths.directory
            )
            let written = try fileSystem.readData(at: paths.backup)
            guard
                written == originalBytes,
                LibraryPersistence.sha256(written) == journal.sourceSHA256
            else {
                throw LibraryMigrationError.recoveryConflict
            }
        }

        let journalData = try encoded(journal)
        if fileSystem.fileExists(at: paths.journal) {
            let existing = try fileSystem.readData(at: paths.journal)
            guard existing == journalData else {
                throw LibraryMigrationError.invalidJournal
            }
        } else {
            try publishControlData(
                journalData,
                to: paths.journal,
                parent: paths.directory
            )
        }
    }

    func executeCopies(
        journal: MigrationJournal,
        sourceRecords: [PlannedRecord]
    ) throws {
        var stagingRoots = Set<URL>()
        for record in sourceRecords where record.source.sourceExists {
            guard let expectedManifest = record.source.sourceManifest else {
                throw LibraryMigrationError.invalidJournal
            }
            if fileSystem.fileExists(at: record.paths.profileRoot.url) {
                guard
                    try readPublicationState(
                        journal: journal,
                        mapping: record.mapping
                    ) != nil,
                    try directoryManifest(at: record.paths.profileRoot.url)
                        == expectedManifest
                else {
                    throw LibraryMigrationError.recoveryConflict
                }
                try verifySourceUnchanged(record.source)
                continue
            }
            let staging = try record.paths.stagingRoot(
                transactionID: journal.migrationID
            )
            stagingRoots.insert(staging.url)
            if !fileSystem.fileExists(at: staging.url) {
                _ = try ManagedPathResolver(fileSystem: fileSystem)
                    .revalidateForMutation(staging)
                try fileSystem.createDirectory(
                    at: staging.url,
                    withIntermediateDirectories: true
                )
                try fileSystem.setPOSIXPermissions(0o700, at: staging.url)
            }

            let occurrence = String(record.mapping.profileOccurrence)
            let firstCopy = staging.url
                .appendingPathComponent("SourceCopies", isDirectory: true)
                .appendingPathComponent(occurrence, isDirectory: true)
            let publishCopy = staging.url
                .appendingPathComponent("PublishCopies", isDirectory: true)
                .appendingPathComponent(occurrence, isDirectory: true)
            try fileSystem.createDirectory(
                at: firstCopy.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileSystem.createDirectory(
                at: publishCopy.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard
                !fileSystem.fileExists(at: firstCopy),
                !fileSystem.fileExists(at: publishCopy)
            else {
                throw LibraryMigrationError.recoveryConflict
            }

            try fileSystem.copyItem(
                at: record.source.canonicalSourceURL,
                to: firstCopy
            )
            try verifySourceUnchanged(record.source)
            guard try directoryManifest(at: firstCopy) == expectedManifest else {
                throw LibraryMigrationError.sourceChanged
            }

            try fileSystem.copyItem(at: firstCopy, to: publishCopy)
            guard try directoryManifest(at: publishCopy) == expectedManifest else {
                throw LibraryMigrationError.sourceChanged
            }

            try writePublicationState(
                journal: journal,
                mapping: record.mapping,
                state: .prepared
            )
            let ownerURL = ownerMarkerURL(
                destination: record.paths.profileRoot.url,
                mapping: record.mapping
            )
            try fileSystem.createDirectory(
                at: ownerURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard
                !fileSystem.fileExists(at: ownerURL),
                !fileSystem.fileExists(at: record.paths.profileRoot.url)
            else {
                throw LibraryMigrationError.recoveryConflict
            }
            try fileSystem.writeData(ownerData(for: journal, mapping: record.mapping), to: ownerURL)
            try fileSystem.setPOSIXPermissions(0o600, at: ownerURL)
            try fileSystem.synchronize(at: ownerURL)
            try fileSystem.synchronize(at: ownerURL.deletingLastPathComponent())

            _ = try ManagedPathResolver(fileSystem: fileSystem)
                .revalidateForMutation(record.paths.profileRoot)
            try fileSystem.moveItem(
                at: publishCopy,
                to: record.paths.profileRoot.url
            )
            try fileSystem.synchronize(at: record.paths.profileRoot.url)
            try fileSystem.synchronize(
                at: record.paths.profileRoot.url.deletingLastPathComponent()
            )
            try writePublicationState(
                journal: journal,
                mapping: record.mapping,
                state: .published
            )
            guard try directoryManifest(at: record.paths.profileRoot.url) == expectedManifest else {
                throw LibraryMigrationError.sourceChanged
            }
            try verifySourceUnchanged(record.source)
        }

        for stagingRoot in stagingRoots where fileSystem.fileExists(at: stagingRoot) {
            try fileSystem.removeItem(at: stagingRoot)
        }
    }

    func writePendingReceipt(for journal: MigrationJournal) throws {
        let paths = controlPaths(for: journal.migrationID)
        let receipt = receipt(for: journal, completedAt: now())
        let data = try encoded(receipt)
        if fileSystem.fileExists(at: paths.pendingReceipt) {
            guard try fileSystem.readData(at: paths.pendingReceipt) == data else {
                throw LibraryMigrationError.recoveryConflict
            }
        } else {
            try publishControlData(
                data,
                to: paths.pendingReceipt,
                parent: paths.directory
            )
        }
    }

    func commitLibrary(
        journal: MigrationJournal,
        applications: [ManagedApplication],
        sourceRecords: [SourceRecord]
    ) throws {
        let paths = controlPaths(for: journal.migrationID)
        let data = try encodedLibrary(applications)
        guard LibraryPersistence.sha256(data) == journal.targetSHA256 else {
            throw LibraryMigrationError.invalidJournal
        }
        guard !fileSystem.fileExists(at: paths.pendingLibrary) else {
            throw LibraryMigrationError.recoveryConflict
        }
        try fileSystem.writeData(data, to: paths.pendingLibrary)
        try fileSystem.setPOSIXPermissions(0o600, at: paths.pendingLibrary)
        try fileSystem.synchronize(at: paths.pendingLibrary)
        try fileSystem.synchronize(at: paths.directory)
        guard try currentPrimaryHash() == journal.sourceSHA256 else {
            throw LibraryMigrationError.sourceChanged
        }
        for source in sourceRecords where source.sourceExists {
            try verifySourceUnchanged(source)
        }
        try fileSystem.replaceItem(
            at: libraryURL,
            withItemAt: paths.pendingLibrary
        )
        let postReplaceHash = try currentPrimaryHash()
        guard postReplaceHash == journal.targetSHA256 else {
            if postReplaceHash == journal.sourceSHA256 {
                throw LibraryMigrationError.sourceChanged
            }
            throw LibraryMigrationError.recoveryConflict
        }
        try fileSystem.synchronize(at: libraryURL)
        try fileSystem.synchronize(at: libraryURL.deletingLastPathComponent())
    }

    func finalizeCommittedMigration(
        journal: MigrationJournal
    ) throws -> LibraryMigrationReceipt {
        let paths = controlPaths(for: journal.migrationID)
        if fileSystem.fileExists(at: paths.receipt),
           !fileSystem.fileExists(at: paths.pendingReceipt) {
            return try JSONDecoder().decode(
                LibraryMigrationReceipt.self,
                from: fileSystem.readData(at: paths.receipt)
            )
        }
        if !fileSystem.fileExists(at: paths.pendingReceipt) {
            let pendingReceipt = receipt(for: journal, completedAt: now())
            try publishControlData(
                try encoded(pendingReceipt),
                to: paths.pendingReceipt,
                parent: paths.directory
            )
        }

        for mapping in journal.mappings {
            let resolved = try resolvedPaths(for: mapping)
            _ = try readPublicationState(
                journal: journal,
                mapping: mapping
            )
            let ownerURL = ownerMarkerURL(
                destination: resolved.profileRoot.url,
                mapping: mapping
            )
            if fileSystem.fileExists(at: ownerURL) {
                guard try fileSystem.readData(at: ownerURL)
                    == ownerData(for: journal, mapping: mapping) else {
                    throw LibraryMigrationError.recoveryConflict
                }
                _ = try ManagedPathResolver(fileSystem: fileSystem)
                    .revalidateForMutation(resolved.profileRoot)
                try fileSystem.removeItem(at: ownerURL)
            }
            let publicationURL = publicationURL(
                migrationID: journal.migrationID,
                mapping: mapping
            )
            if fileSystem.fileExists(at: publicationURL) {
                try fileSystem.removeItem(at: publicationURL)
            }
        }
        try removeStagingRoots(for: journal)
        if fileSystem.fileExists(at: paths.pendingLibrary) {
            try fileSystem.removeItem(at: paths.pendingLibrary)
        }
        guard !fileSystem.fileExists(at: paths.receipt) else {
            throw LibraryMigrationError.recoveryConflict
        }
        try fileSystem.moveItem(
            at: paths.pendingReceipt,
            to: paths.receipt
        )
        try fileSystem.setPOSIXPermissions(0o600, at: paths.receipt)
        try fileSystem.synchronize(at: paths.receipt)
        try fileSystem.synchronize(at: paths.directory)
        return try JSONDecoder().decode(
            LibraryMigrationReceipt.self,
            from: fileSystem.readData(at: paths.receipt)
        )
    }
}

// MARK: - Recovery

private extension LibraryMigrationCoordinator {
    func recoverCommittedMigrationIfNeeded(
        applications: [ManagedApplication]
    ) throws -> LibraryMigrationOutcome? {
        let primaryData = try fileSystem.readData(at: libraryURL)
        let primaryHash = LibraryPersistence.sha256(primaryData)
        let incomplete = try allIncompleteJournals()
        guard !incomplete.isEmpty else { return nil }
        let matching = incomplete.filter { $0.targetSHA256 == primaryHash }
        guard matching.count == 1, incomplete.count == 1,
              let journal = matching.first else {
            throw LibraryMigrationError.recoveryConflict
        }
        try validateRetainedLegacySources(for: journal)
        try validate(journal: journal, against: applications)
        try verifyPublishedDestinations(journal)
        let receipt = try finalizeCommittedMigration(journal: journal)
        return .migrated(applications, receipt)
    }

    func validateRetainedLegacySources(
        for journal: MigrationJournal
    ) throws {
        let backup = controlPaths(for: journal.migrationID).backup
        guard let attributes = try attributesIfExists(at: backup),
              attributes.kind == .regularFile else {
            throw LibraryMigrationError.recoveryConflict
        }
        let bytes = try fileSystem.readData(at: backup)
        guard
            bytes.count == journal.sourceByteCount,
            LibraryPersistence.sha256(bytes) == journal.sourceSHA256,
            case let .migrationRequired(legacy) =
                try LibraryPersistence.decodeLibrary(from: bytes)
        else {
            throw LibraryMigrationError.recoveryConflict
        }
        do {
            try validateCommittedJournal(journal, against: legacy)
        } catch {
            throw LibraryMigrationError.recoveryConflict
        }
    }

    func validateCommittedJournal(
        _ journal: MigrationJournal,
        against legacy: LegacyLibrary
    ) throws {
        guard
            journal.sourceFormat == sourceFormat(legacy.format),
            journal.applicationMappings.count == legacy.applications.count,
            journal.mappings.count == legacy.applications.flatMap(\.profiles).count
        else {
            throw LibraryMigrationError.invalidJournal
        }

        for applicationMapping in journal.applicationMappings {
            guard
                legacy.applications.indices.contains(
                    applicationMapping.applicationOccurrence
                ),
                legacy.applications[applicationMapping.applicationOccurrence].id
                    == applicationMapping.oldApplicationID
            else {
                throw LibraryMigrationError.invalidJournal
            }
        }

        let flattened = legacy.applications.enumerated().flatMap {
            applicationOccurrence, application in
            application.profiles.map { (applicationOccurrence, application, $0) }
        }
        for mapping in journal.mappings {
            guard
                flattened.indices.contains(mapping.profileOccurrence),
                journal.applicationMappings.indices.contains(
                    mapping.applicationOccurrence
                )
            else {
                throw LibraryMigrationError.invalidJournal
            }
            let expected = flattened[mapping.profileOccurrence]
            let applicationMapping =
                journal.applicationMappings[mapping.applicationOccurrence]
            guard
                expected.0 == mapping.applicationOccurrence,
                expected.1.id == mapping.oldApplicationID,
                expected.2.id == mapping.oldProfileID,
                applicationMapping.oldApplicationID == mapping.oldApplicationID,
                applicationMapping.newApplicationID == mapping.newApplicationID,
                applicationMapping.applicationStorageID
                    == mapping.applicationStorageID,
                !mapping.oldCanonicalPath.isEmpty,
                mapping.oldCanonicalPath.hasPrefix("/"),
                (mapping.disposition == .retainedInPlace)
                    == (mapping.sourceManifestSHA256 != nil)
            else {
                throw LibraryMigrationError.invalidJournal
            }
        }
    }

    func verifyPublishedDestinations(
        _ journal: MigrationJournal
    ) throws {
        for mapping in journal.mappings {
            let resolved = try resolvedPaths(for: mapping)
            let attributes = try attributesIfExists(at: resolved.profileRoot.url)
            switch mapping.disposition {
            case .missing:
                guard attributes == nil else {
                    throw LibraryMigrationError.recoveryConflict
                }
            case .retainedInPlace:
                guard
                    attributes?.kind == .directory,
                    let expected = mapping.sourceManifestSHA256,
                    manifestSHA256(
                        try directoryManifest(at: resolved.profileRoot.url)
                    ) == expected
                else {
                    throw LibraryMigrationError.recoveryConflict
                }
            }
        }
    }

    func validate(
        journal: MigrationJournal,
        against legacy: LegacyLibrary,
        sources: [SourceRecord]
    ) throws {
        guard
            journal.sourceFormat == sourceFormat(legacy.format),
            journal.applicationMappings.count == legacy.applications.count,
            journal.mappings.count == legacy.applications.flatMap(\.profiles).count
        else {
            throw LibraryMigrationError.invalidJournal
        }

        for applicationMapping in journal.applicationMappings {
            guard
                legacy.applications.indices.contains(
                    applicationMapping.applicationOccurrence
                ),
                legacy.applications[applicationMapping.applicationOccurrence].id
                    == applicationMapping.oldApplicationID
            else {
                throw LibraryMigrationError.invalidJournal
            }
        }

        let flattened = legacy.applications.enumerated().flatMap {
            applicationOccurrence, application in
            application.profiles.map { (applicationOccurrence, application, $0) }
        }
        for mapping in journal.mappings {
            guard
                flattened.indices.contains(mapping.profileOccurrence),
                journal.applicationMappings.indices.contains(
                    mapping.applicationOccurrence
                ),
                let source = sources.first(where: {
                    $0.profileOccurrence == mapping.profileOccurrence
                })
            else {
                throw LibraryMigrationError.invalidJournal
            }
            let expected = flattened[mapping.profileOccurrence]
            let applicationMapping =
                journal.applicationMappings[mapping.applicationOccurrence]
            guard
                expected.0 == mapping.applicationOccurrence,
                expected.1.id == mapping.oldApplicationID,
                expected.2.id == mapping.oldProfileID,
                applicationMapping.oldApplicationID == mapping.oldApplicationID,
                applicationMapping.newApplicationID == mapping.newApplicationID,
                applicationMapping.applicationStorageID
                    == mapping.applicationStorageID,
                source.canonicalSourceURL.path == mapping.oldCanonicalPath,
                source.sourceExists == (mapping.disposition == .retainedInPlace),
                source.sourceManifest.map(manifestSHA256)
                    == mapping.sourceManifestSHA256
            else {
                throw LibraryMigrationError.invalidJournal
            }

            let resolved = try ManagedPathResolver(fileSystem: fileSystem).resolve(
                baseRootURL: source.baseRoot,
                applicationStorageID: mapping.applicationStorageID,
                profileStorageID: mapping.profileStorageID
            )
            guard
                resolved.profileRoot.url.path
                    == mapping.newCanonicalPath
            else {
                throw LibraryMigrationError.invalidJournal
            }
        }
    }

    func validate(
        journal: MigrationJournal,
        against applications: [ManagedApplication]
    ) throws {
        guard
            journal.applicationMappings.count == applications.count,
            journal.mappings.count == applications.flatMap(\.profiles).count
        else {
            throw LibraryMigrationError.invalidJournal
        }
        for mapping in journal.applicationMappings {
            guard applications.indices.contains(mapping.applicationOccurrence) else {
                throw LibraryMigrationError.invalidJournal
            }
            let application = applications[mapping.applicationOccurrence]
            guard
                application.id == mapping.newApplicationID,
                application.storageID == mapping.applicationStorageID
            else {
                throw LibraryMigrationError.invalidJournal
            }
        }

        let flattened = applications.enumerated().flatMap {
            applicationOccurrence, application in
            application.profiles.map { (applicationOccurrence, application, $0) }
        }
        for mapping in journal.mappings {
            guard flattened.indices.contains(mapping.profileOccurrence) else {
                throw LibraryMigrationError.invalidJournal
            }
            let expected = flattened[mapping.profileOccurrence]
            guard
                expected.0 == mapping.applicationOccurrence,
                expected.1.id == mapping.newApplicationID,
                expected.1.storageID == mapping.applicationStorageID,
                expected.2.id == mapping.newProfileID,
                expected.2.storageID == mapping.profileStorageID
            else {
                throw LibraryMigrationError.invalidJournal
            }
            let basePath = expected.1.baseStoragePath?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !basePath.isEmpty else {
                throw LibraryMigrationError.invalidJournal
            }
            let resolved = try ManagedPathResolver(fileSystem: fileSystem).resolve(
                configuredBaseRoot: basePath,
                applicationStorageID: mapping.applicationStorageID,
                profileStorageID: mapping.profileStorageID
            )
            guard resolved.profileRoot.url.path
                == mapping.newCanonicalPath else {
                throw LibraryMigrationError.invalidJournal
            }
        }
    }

    func journal(matchingSourceHash hash: String) throws -> MigrationJournal? {
        let incomplete = try allIncompleteJournals()
        let matches = incomplete.filter { $0.sourceSHA256 == hash }
        guard matches.count <= 1, matches.count == incomplete.count else {
            throw LibraryMigrationError.recoveryConflict
        }
        return matches.first
    }

    func allIncompleteJournals() throws -> [MigrationJournal] {
        let root = migrationsRootURL
        guard fileSystem.fileExists(at: root) else { return [] }
        var result: [MigrationJournal] = []
        for directory in try fileSystem.contentsOfDirectory(at: root)
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                guard try fileSystem.attributesOfItem(at: directory).kind == .directory else {
                    throw LibraryMigrationError.recoveryConflict
                }
                let receipt = directory.appendingPathComponent("receipt.json")
                let pending = directory.appendingPathComponent("receipt.pending.json")
                let journalURL = directory.appendingPathComponent("journal.json")
                guard fileSystem.fileExists(at: journalURL) else {
                    throw LibraryMigrationError.recoveryConflict
                }
                let journal = try JSONDecoder().decode(
                    MigrationJournal.self,
                    from: fileSystem.readData(at: journalURL)
                )
                guard
                    journal.schemaVersion == Self.schemaVersion,
                    directory.lastPathComponent
                        == journal.migrationID.uuidString.lowercased()
                else {
                    throw LibraryMigrationError.invalidJournal
                }
                if fileSystem.fileExists(at: receipt),
                   !fileSystem.fileExists(at: pending) {
                    continue
                }
                result.append(journal)
            }
        return result
    }

    func rollbackOwnedState(
        for journal: MigrationJournal,
        sourceRecords: [SourceRecord]
    ) throws {
        for mapping in journal.mappings {
            guard let sourceRecord = sourceRecords.first(where: {
                $0.profileOccurrence == mapping.profileOccurrence
            }) else {
                throw LibraryMigrationError.invalidJournal
            }
            let resolved = try ManagedPathResolver(fileSystem: fileSystem).resolve(
                baseRootURL: sourceRecord.baseRoot,
                applicationStorageID: mapping.applicationStorageID,
                profileStorageID: mapping.profileStorageID
            )
            guard resolved.profileRoot.url.path
                == mapping.newCanonicalPath else {
                throw LibraryMigrationError.invalidJournal
            }
            let ownerURL = ownerMarkerURL(
                destination: resolved.profileRoot.url,
                mapping: mapping
            )
            let ownerExists = fileSystem.fileExists(at: ownerURL)
            if ownerExists {
                guard try fileSystem.readData(at: ownerURL)
                    == ownerData(for: journal, mapping: mapping) else {
                    throw LibraryMigrationError.recoveryConflict
                }
            }
            let publication = try readPublicationState(
                journal: journal,
                mapping: mapping
            )
            let destination = resolved.profileRoot.url
            if fileSystem.fileExists(at: destination) {
                guard
                    ownerExists || publication != nil,
                    let expectedDigest = mapping.sourceManifestSHA256,
                    sourceRecord.sourceExists,
                    let sourceManifest = sourceRecord.sourceManifest,
                    manifestSHA256(sourceManifest) == expectedDigest,
                    manifestSHA256(try directoryManifest(at: destination))
                        == expectedDigest
                else {
                    throw LibraryMigrationError.recoveryConflict
                }
                if !ownerExists, publication != nil {
                    try writePublicationState(
                        journal: journal,
                        mapping: mapping,
                        state: .published
                    )
                    continue
                }
                _ = try ManagedPathResolver(fileSystem: fileSystem)
                    .revalidateForMutation(resolved.profileRoot)
                try fileSystem.removeItem(at: destination)
            }
            if ownerExists {
                _ = try ManagedPathResolver(fileSystem: fileSystem)
                    .revalidateForMutation(resolved.profileRoot)
                try fileSystem.removeItem(at: ownerURL)
            }
            if publication != nil {
                let publicationURL = publicationURL(
                    migrationID: journal.migrationID,
                    mapping: mapping
                )
                try fileSystem.removeItem(at: publicationURL)
            }
        }
        try removeStagingRoots(for: journal)
        let pending = controlPaths(for: journal.migrationID).pendingReceipt
        if fileSystem.fileExists(at: pending) {
            try fileSystem.removeItem(at: pending)
        }
        let pendingLibrary = controlPaths(for: journal.migrationID).pendingLibrary
        if fileSystem.fileExists(at: pendingLibrary) {
            try fileSystem.removeItem(at: pendingLibrary)
        }
        let rollbackRequired = controlPaths(for: journal.migrationID).directory
            .appendingPathComponent("rollback-required.json")
        if fileSystem.fileExists(at: rollbackRequired) {
            try fileSystem.removeItem(at: rollbackRequired)
        }
    }

    func cleanUnjournaledControlStateIfNeeded(
        journal: MigrationJournal
    ) throws {
        let paths = controlPaths(for: journal.migrationID)
        guard
            fileSystem.fileExists(at: paths.directory),
            !fileSystem.fileExists(at: paths.journal)
        else {
            return
        }
        try fileSystem.removeItem(at: paths.directory)
        if fileSystem.fileExists(at: migrationsRootURL),
           (try? fileSystem.contentsOfDirectory(at: migrationsRootURL).isEmpty) == true {
            try fileSystem.removeItem(at: migrationsRootURL)
        }
    }

    func removeStagingRoots(for journal: MigrationJournal) throws {
        var roots: [ManagedStagingRootPath] = []
        for mapping in journal.mappings {
            let resolved = try resolvedPaths(for: mapping)
            let staging = try resolved.stagingRoot(
                transactionID: journal.migrationID
            )
            if !roots.contains(where: { $0.url == staging.url }) {
                roots.append(staging)
            }
        }
        for root in roots where fileSystem.fileExists(at: root.url) {
            let validated = try ManagedPathResolver(fileSystem: fileSystem)
                .revalidateForMutation(root)
            guard validated == root.url else {
                throw LibraryMigrationError.recoveryConflict
            }
            try fileSystem.removeItem(at: validated)
        }
    }
}

// MARK: - Manifest and helpers

private extension LibraryMigrationCoordinator {
    struct DirectoryManifest: Hashable, Sendable {
        struct Entry: Hashable, Sendable {
            enum Kind: String, Hashable, Sendable {
                case directory
                case regularFile
                case symbolicLink
            }

            let relativePath: String
            let kind: Kind
            let size: UInt64?
            let posixPermissions: Int?
            let digestOrTarget: String?
        }

        let entries: [Entry]
    }

    struct MigrationJournal: Codable, Hashable, Sendable {
        let schemaVersion: Int
        let migrationID: UUID
        let sourceFormat: String
        let sourceSHA256: String
        let sourceByteCount: Int
        let targetSHA256: String
        let createdAt: Date
        let applicationMappings: [LibraryMigrationApplicationMapping]
        let mappings: [LibraryMigrationPathMapping]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case migrationID
            case sourceFormat
            case sourceSHA256
            case sourceByteCount
            case targetSHA256
            case createdAt
            case applicationMappings
            case mappings
        }

        init(
            schemaVersion: Int,
            migrationID: UUID,
            sourceFormat: String,
            sourceSHA256: String,
            sourceByteCount: Int,
            targetSHA256: String,
            createdAt: Date,
            applicationMappings: [LibraryMigrationApplicationMapping],
            mappings: [LibraryMigrationPathMapping]
        ) {
            self.schemaVersion = schemaVersion
            self.migrationID = migrationID
            self.sourceFormat = sourceFormat
            self.sourceSHA256 = sourceSHA256
            self.sourceByteCount = sourceByteCount
            self.targetSHA256 = targetSHA256
            self.createdAt = createdAt
            self.applicationMappings = applicationMappings
            self.mappings = mappings
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
            let migrationString = try container.decode(String.self, forKey: .migrationID)
            guard let migrationID = UUID(uuidString: migrationString) else {
                throw LibraryMigrationError.invalidJournal
            }
            self.migrationID = migrationID
            sourceFormat = try container.decode(String.self, forKey: .sourceFormat)
            sourceSHA256 = try container.decode(String.self, forKey: .sourceSHA256)
            sourceByteCount = try container.decode(Int.self, forKey: .sourceByteCount)
            targetSHA256 = try container.decode(String.self, forKey: .targetSHA256)
            createdAt = try container.decode(Date.self, forKey: .createdAt)
            applicationMappings = try container.decode(
                [LibraryMigrationApplicationMapping].self,
                forKey: .applicationMappings
            )
            mappings = try container.decode(
                [LibraryMigrationPathMapping].self,
                forKey: .mappings
            )
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(
                migrationID.uuidString.lowercased(),
                forKey: .migrationID
            )
            try container.encode(sourceFormat, forKey: .sourceFormat)
            try container.encode(sourceSHA256, forKey: .sourceSHA256)
            try container.encode(sourceByteCount, forKey: .sourceByteCount)
            try container.encode(targetSHA256, forKey: .targetSHA256)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(applicationMappings, forKey: .applicationMappings)
            try container.encode(mappings, forKey: .mappings)
        }
    }

    struct PublicationRecord: Codable, Hashable, Sendable {
        enum State: String, Codable, Hashable, Sendable {
            case prepared
            case published
        }

        let migrationID: String
        let applicationStorageID: String
        let profileStorageID: String
        let profileOccurrence: Int
        let manifestSHA256: String
        let state: State
    }

    struct RollbackRequiredRecord: Codable, Hashable, Sendable {
        let migrationID: String
        let reason: String
    }

    struct ControlPaths {
        let directory: URL
        let backup: URL
        let journal: URL
        let receipt: URL
        let pendingReceipt: URL
        let pendingLibrary: URL
    }

    var parallaxURL: URL {
        applicationSupportURL.appendingPathComponent("Parallax", isDirectory: true)
    }

    var libraryURL: URL {
        parallaxURL.appendingPathComponent("library.json")
    }

    var migrationsRootURL: URL {
        parallaxURL.appendingPathComponent("Migrations", isDirectory: true)
    }

    func controlPaths(for migrationID: UUID) -> ControlPaths {
        let directory = migrationsRootURL.appendingPathComponent(
            migrationID.uuidString.lowercased(),
            isDirectory: true
        )
        return ControlPaths(
            directory: directory,
            backup: directory.appendingPathComponent("library-v1.backup.json"),
            journal: directory.appendingPathComponent("journal.json"),
            receipt: directory.appendingPathComponent("receipt.json"),
            pendingReceipt: directory.appendingPathComponent("receipt.pending.json"),
            pendingLibrary: directory.appendingPathComponent("library-v2.pending.json")
        )
    }

    func publicationURL(
        migrationID: UUID,
        mapping: LibraryMigrationPathMapping
    ) -> URL {
        controlPaths(for: migrationID).directory.appendingPathComponent(
            "publication-\(mapping.profileOccurrence).json",
            isDirectory: false
        )
    }

    func publicationRecord(
        journal: MigrationJournal,
        mapping: LibraryMigrationPathMapping,
        state: PublicationRecord.State
    ) throws -> PublicationRecord {
        guard let manifest = mapping.sourceManifestSHA256 else {
            throw LibraryMigrationError.invalidJournal
        }
        return PublicationRecord(
            migrationID: journal.migrationID.uuidString.lowercased(),
            applicationStorageID:
                mapping.applicationStorageID.uuidString.lowercased(),
            profileStorageID: mapping.profileStorageID.uuidString.lowercased(),
            profileOccurrence: mapping.profileOccurrence,
            manifestSHA256: manifest,
            state: state
        )
    }

    func writePublicationState(
        journal: MigrationJournal,
        mapping: LibraryMigrationPathMapping,
        state: PublicationRecord.State
    ) throws {
        let url = publicationURL(
            migrationID: journal.migrationID,
            mapping: mapping
        )
        let data = try encoded(
            publicationRecord(
                journal: journal,
                mapping: mapping,
                state: state
            )
        )
        if fileSystem.fileExists(at: url) {
            try fileSystem.writeDataAtomically(data, to: url)
            try fileSystem.setPOSIXPermissions(0o600, at: url)
            try fileSystem.synchronize(at: url)
            try fileSystem.synchronize(at: url.deletingLastPathComponent())
        } else {
            try publishControlData(
                data,
                to: url,
                parent: url.deletingLastPathComponent()
            )
        }
    }

    func readPublicationState(
        journal: MigrationJournal,
        mapping: LibraryMigrationPathMapping
    ) throws -> PublicationRecord? {
        let url = publicationURL(
            migrationID: journal.migrationID,
            mapping: mapping
        )
        guard fileSystem.fileExists(at: url) else { return nil }
        let decoded = try JSONDecoder().decode(
            PublicationRecord.self,
            from: fileSystem.readData(at: url)
        )
        let prepared = try publicationRecord(
            journal: journal,
            mapping: mapping,
            state: decoded.state
        )
        guard decoded == prepared else {
            throw LibraryMigrationError.invalidJournal
        }
        return decoded
    }

    func markRollbackRequired(
        journal: MigrationJournal,
        reason: String
    ) throws {
        let url = controlPaths(for: journal.migrationID).directory
            .appendingPathComponent("rollback-required.json")
        let data = try encoded(
            RollbackRequiredRecord(
                migrationID: journal.migrationID.uuidString.lowercased(),
                reason: reason
            )
        )
        if fileSystem.fileExists(at: url) {
            try fileSystem.writeDataAtomically(data, to: url)
            try fileSystem.synchronize(at: url)
        } else {
            try publishControlData(
                data,
                to: url,
                parent: url.deletingLastPathComponent()
            )
        }
    }

    func directoryManifest(at root: URL) throws -> DirectoryManifest {
        var entries: [DirectoryManifest.Entry] = []
        try appendManifestEntries(root: root, current: root, result: &entries)
        return DirectoryManifest(
            entries: entries.sorted { $0.relativePath < $1.relativePath }
        )
    }

    func manifestSHA256(_ manifest: DirectoryManifest) -> String {
        let rows = manifest.entries.map { entry in
            [
                entry.relativePath,
                entry.kind.rawValue,
                entry.size.map(String.init) ?? "",
                entry.posixPermissions.map(String.init) ?? "",
                entry.digestOrTarget ?? ""
            ].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        return LibraryPersistence.sha256(Data(rows.utf8))
    }

    func verifySourceUnchanged(_ source: SourceRecord) throws {
        guard
            source.sourceExists,
            let expectedManifest = source.sourceManifest
        else {
            return
        }
        let attributes = try fileSystem.attributesOfItem(
            at: source.canonicalSourceURL
        )
        guard
            attributes.kind == .directory,
            attributes.identity == source.sourceIdentity,
            try directoryManifest(at: source.canonicalSourceURL)
                == expectedManifest
        else {
            throw LibraryMigrationError.sourceChanged
        }
    }

    func appendManifestEntries(
        root: URL,
        current: URL,
        result: inout [DirectoryManifest.Entry]
    ) throws {
        let attributes = try fileSystem.attributesOfItem(at: current)
        let relative = relativePath(of: current, under: root)
        switch attributes.kind {
        case .directory:
            result.append(
                .init(
                    relativePath: relative,
                    kind: .directory,
                    size: nil,
                    posixPermissions: attributes.posixPermissions,
                    digestOrTarget: nil
                )
            )
            for child in try fileSystem.contentsOfDirectory(at: current)
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                try appendManifestEntries(root: root, current: child, result: &result)
            }
        case .regularFile:
            let data = try fileSystem.readData(at: current)
            result.append(
                .init(
                    relativePath: relative,
                    kind: .regularFile,
                    size: UInt64(data.count),
                    posixPermissions: attributes.posixPermissions,
                    digestOrTarget: LibraryPersistence.sha256(data)
                )
            )
        case .symbolicLink:
            result.append(
                .init(
                    relativePath: relative,
                    kind: .symbolicLink,
                    size: attributes.size,
                    posixPermissions: attributes.posixPermissions,
                    digestOrTarget: try fileSystem.destinationOfSymbolicLink(at: current)
                )
            )
        case .other:
            throw LibraryMigrationError.unsupportedSourceItem(current.path)
        }
    }

    func relativePath(of url: URL, under root: URL) -> String {
        let rootComponents = root.standardizedFileURL.pathComponents
        let components = url.standardizedFileURL.pathComponents
        return components.dropFirst(rootComponents.count).joined(separator: "/")
    }

    func ownerMarkerURL(
        destination: URL,
        mapping: LibraryMigrationPathMapping
    ) -> URL {
        destination
            .deletingLastPathComponent()
            .appendingPathComponent(
                ".\(mapping.profileStorageID.uuidString.lowercased())."
                    + "\(mapping.applicationStorageID.uuidString.lowercased()).owner",
                isDirectory: false
            )
    }

    func resolvedPaths(
        for mapping: LibraryMigrationPathMapping
    ) throws -> ResolvedProfilePaths {
        let destination = URL(
            fileURLWithPath: mapping.newCanonicalPath,
            isDirectory: true
        )
        let components = destination.pathComponents
        let suffix = [
            ".parallax",
            "Applications",
            mapping.applicationStorageID.uuidString.lowercased(),
            "Profiles",
            mapping.profileStorageID.uuidString.lowercased()
        ]
        guard
            components.count > suffix.count,
            Array(components.suffix(suffix.count)) == suffix
        else {
            throw LibraryMigrationError.invalidJournal
        }
        let baseComponents = components.dropLast(suffix.count)
        let basePath = NSString.path(
            withComponents: Array(baseComponents)
        )
        let resolved = try ManagedPathResolver(fileSystem: fileSystem).resolve(
            baseRootURL: URL(fileURLWithPath: basePath, isDirectory: true),
            applicationStorageID: mapping.applicationStorageID,
            profileStorageID: mapping.profileStorageID
        )
        guard resolved.profileRoot.url.path == destination.path else {
            throw LibraryMigrationError.invalidJournal
        }
        return resolved
    }

    func ownerData(
        for journal: MigrationJournal,
        mapping: LibraryMigrationPathMapping
    ) -> Data {
        Data(
            "\(journal.migrationID.uuidString.lowercased()):"
                .appending(mapping.profileStorageID.uuidString.lowercased())
                .utf8
        )
    }

    func receipt(
        for journal: MigrationJournal,
        completedAt: Date
    ) -> LibraryMigrationReceipt {
        LibraryMigrationReceipt(
            schemaVersion: journal.schemaVersion,
            migrationID: journal.migrationID,
            sourceFormat: journal.sourceFormat,
            sourceSHA256: journal.sourceSHA256,
            sourceByteCount: journal.sourceByteCount,
            targetSHA256: journal.targetSHA256,
            backupRelativePath: "library-v1.backup.json",
            startedAt: journal.createdAt,
            completedAt: completedAt,
            committedAt: completedAt,
            legacyDataRetention: "retainedInPlace",
            applicationMappings: journal.applicationMappings,
            mappings: journal.mappings
        )
    }

    func currentPrimaryHash() throws -> String {
        LibraryPersistence.sha256(try fileSystem.readData(at: libraryURL))
    }

    func verifyPrimaryStillMatches(_ snapshot: LegacyLibrarySnapshot) throws {
        let current = try fileSystem.readData(at: libraryURL)
        guard
            current.count == snapshot.sourceByteCount,
            LibraryPersistence.sha256(current) == snapshot.sourceSHA256
        else {
            throw LibraryMigrationError.sourceChanged
        }
    }

    func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
            .withoutEscapingSlashes
        ]
        return try encoder.encode(value)
    }

    func encodedLibrary(_ applications: [ManagedApplication]) throws -> Data {
        try encoded(LibraryDocument(applications: applications))
    }

    func publishControlData(
        _ data: Data,
        to destination: URL,
        parent: URL
    ) throws {
        let pending = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).pending",
            isDirectory: false
        )
        if fileSystem.fileExists(at: pending) {
            guard try fileSystem.readData(at: pending) == data else {
                throw LibraryMigrationError.recoveryConflict
            }
        } else {
            try fileSystem.writeData(data, to: pending)
            try fileSystem.setPOSIXPermissions(0o600, at: pending)
            try fileSystem.synchronize(at: pending)
        }
        try fileSystem.moveItem(at: pending, to: destination)
        try fileSystem.setPOSIXPermissions(0o600, at: destination)
        try fileSystem.synchronize(at: destination)
        try fileSystem.synchronize(at: parent)
    }

    func legacyBasePath(for application: LegacyManagedApplication) -> String {
        let trimmed = application.baseStoragePath?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let historicalDefault = URL(
            fileURLWithPath: NSHomeDirectory(),
            isDirectory: true
        )
        .appendingPathComponent(
            "Library/Application Support/Parallax/Profiles",
            isDirectory: true
        )
        .path
        guard !trimmed.isEmpty else {
            return historicalDefault
        }
        let expanded = (trimmed as NSString).expandingTildeInPath
        return URL(
            fileURLWithPath: expanded,
            isDirectory: true
        ).standardizedFileURL.path
    }

    func canonicalBasePath(
        for application: LegacyManagedApplication,
        applicationOccurrence: Int,
        sources: [SourceRecord]
    ) throws -> String {
        if let source = sources.first(where: {
            $0.applicationOccurrence == applicationOccurrence
        }) {
            return source.canonicalBaseRoot.standardizedFileURL.path
        }
        let paths = try ManagedPathResolver(fileSystem: fileSystem).resolve(
            configuredBaseRoot: legacyBasePath(for: application),
            applicationStorageID: Self.applicationUUID,
            profileStorageID: Self.profileUUID
        )
        return paths.profileRoot.validationContext.canonicalBaseRootURL
            .standardizedFileURL.path
    }

    func sourceFormat(_ format: LegacyLibrary.Format) -> String {
        switch format {
        case let .versioned(version):
            "versioned-v\(version)"
        case .rawApplicationArray:
            "rawApplicationArray"
        }
    }

    func legacySanitizedComponent(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        let scalars = name.unicodeScalars.map {
            allowed.contains($0) ? Character($0) : "-"
        }
        let sanitized = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return sanitized.isEmpty ? "Profile" : sanitized
    }

    func isSafeLegacyComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && !value.contains("/")
            && !value.contains("\\")
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    func compatibilityKey(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping.lowercased()
    }

    func canonicalExistingOrExpected(
        _ requested: URL,
        canonicalBase: URL,
        relativeComponents: [String]
    ) -> URL {
        if fileSystem.fileExists(at: requested),
           let canonical = try? fileSystem.canonicalURL(for: requested) {
            return canonical.standardizedFileURL
        }
        return relativeComponents.reduce(canonicalBase) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
    }

    func contains(_ target: URL, within root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        guard targetComponents.count >= rootComponents.count else { return false }
        return Array(targetComponents.prefix(rootComponents.count)) == rootComponents
    }

    func attributesIfExists(
        at url: URL
    ) throws -> FileSystemItemAttributes? {
        do {
            return try fileSystem.attributesOfItem(at: url)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain,
               (
                   nsError.code == CocoaError.fileNoSuchFile.rawValue
                       || nsError.code == CocoaError.fileReadNoSuchFile.rawValue
               ) {
                return nil
            }
            if nsError.domain == NSPOSIXErrorDomain,
               (nsError.code == Int(ENOENT) || nsError.code == Int(ENOTDIR)) {
                return nil
            }
            throw error
        }
    }

    func uniqueBlockers(
        _ blockers: [LibraryMigrationBlocker]
    ) -> [LibraryMigrationBlocker] {
        Array(Set(blockers)).sorted {
            if $0.kind.rawValue == $1.kind.rawValue {
                return $0.recordOccurrences.lexicographicallyPrecedes(
                    $1.recordOccurrences
                )
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    func duplicateValues(_ values: [UUID]) -> Set<UUID> {
        Dictionary(grouping: values, by: { $0 })
            .filter { $0.value.count > 1 }
            .keys
            .reduce(into: Set<UUID>()) { $0.insert($1) }
    }

    func nextUniqueUUID(occupied: inout Set<UUID>) -> UUID {
        while true {
            let candidate = uuidGenerator()
            if occupied.insert(candidate).inserted {
                return candidate
            }
        }
    }

    func isolationConfiguration(
        profile: LegacyLaunchProfile,
        source: SourceRecord
    ) -> LibraryMigrationPathMapping.IsolationConfiguration {
        let parsedArguments = ShellWordsParser.parseResult(profile.argumentsText)
        guard parsedArguments.isSyntacticallyValid else {
            return .requiresReview
        }
        let userDataValues = userDataArguments(in: profile.argumentsText)
        let codexHomeValues = environmentValues(
            "CODEX_HOME",
            in: profile.environmentText
        )
        let generatedUserData = source.sourceURL
            .appendingPathComponent("UserData", isDirectory: true).path
        let generatedCodexHome = source.sourceURL
            .appendingPathComponent("CodexHome", isDirectory: true).path
        if userDataValues.contains(where: { $0 != generatedUserData }) {
            return .external
        }
        if codexHomeValues.contains(where: { $0 != generatedCodexHome }) {
            return .external
        }
        if !userDataValues.isEmpty || !codexHomeValues.isEmpty {
            return .generated
        }
        return .none
    }

    func rewrittenConfiguration(
        profile: LegacyLaunchProfile,
        source: SourceRecord,
        destination: ResolvedProfilePaths
    ) -> (arguments: String, environment: String) {
        let oldUserData = source.sourceURL
            .appendingPathComponent("UserData", isDirectory: true).path
        let oldCodexHome = source.sourceURL
            .appendingPathComponent("CodexHome", isDirectory: true).path
        var arguments = profile.argumentsText
        let parsedArguments = ShellWordsParser.parseResult(arguments)
        let userDataValues = userDataArguments(in: arguments)
        let hasSplitUserDataOption = parsedArguments.words
            .contains("--user-data-dir")
        if parsedArguments.isSyntacticallyValid,
           !hasSplitUserDataOption,
           userDataValues.count == 1,
           generatedPath(userDataValues[0], matches: oldUserData) {
            arguments = replacingUniqueGeneratedPath(
                userDataValues[0],
                with: destination.userData.url.path,
                in: arguments
            ) ?? arguments
        }
        var environment = profile.environmentText
        let codexHomeValues = environmentValues("CODEX_HOME", in: environment)
        if codexHomeValues.count == 1,
           generatedPath(codexHomeValues[0], matches: oldCodexHome) {
            environment = replacingUniqueGeneratedPath(
                codexHomeValues[0],
                with: destination.codexHome.url.path,
                in: environment
            ) ?? environment
        }
        return (arguments, environment)
    }

    func userDataArguments(in text: String) -> [String] {
        let result = ShellWordsParser.parseResult(text)
        guard result.isSyntacticallyValid else { return [] }
        return result.words.filter {
            $0.hasPrefix("--user-data-dir=")
        }.map {
            String($0.dropFirst("--user-data-dir=".count))
        }
    }

    func environmentValues(_ key: String, in text: String) -> [String] {
        var values: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let string = String(line)
            let trimmed = string.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=") else {
                continue
            }
            let foundKey = String(trimmed[..<separator])
                .trimmingCharacters(in: .whitespaces)
            if foundKey == key {
                let rawValue = String(
                    trimmed[trimmed.index(after: separator)...]
                ).trimmingCharacters(in: .whitespaces)
                values.append(unquotedEnvironmentValue(rawValue))
            }
        }
        return values
    }

    func unquotedEnvironmentValue(_ value: String) -> String {
        guard
            value.count >= 2,
            let first = value.first,
            first == "\"" || first == "'",
            value.last == first
        else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    func generatedPath(_ candidate: String, matches expected: String) -> Bool {
        let expanded = (candidate as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return false }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
            == URL(fileURLWithPath: expected).standardizedFileURL.path
    }

    func replacingUniqueGeneratedPath(
        _ original: String,
        with replacement: String,
        in text: String
    ) -> String? {
        let ranges = text.ranges(of: original)
        guard ranges.count == 1, let range = ranges.first else {
            return nil
        }
        var result = text
        result.replaceSubrange(range, with: replacement)
        return result
    }
}

private extension String {
    func ranges(of needle: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex,
              let range = range(
                  of: needle,
                  range: searchStart..<endIndex
              ) {
            result.append(range)
            searchStart = range.upperBound
        }
        return result
    }
}
