import Foundation
import Darwin

struct LibraryMigrationCoordinator: Sendable {
    static let schemaVersion = 1
    static let ownerFileName = ".parallax-migration-owner"
    static let applicationUUID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000001"
    ) ?? UUID()
    static let profileUUID = UUID(
        uuidString: "00000000-0000-4000-8000-000000000002"
    ) ?? UUID()

    let fileSystem: any FileSystem
    let applicationSupportURL: URL
    let uuidGenerator: @Sendable () -> UUID
    let now: @Sendable () -> Date

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

    func migrate(
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
                originalBytes: snapshot.originalBytes,
                replacingJournal: resumableJournal
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
