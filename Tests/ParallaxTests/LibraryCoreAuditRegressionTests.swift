import Foundation
import XCTest
@testable import Parallax

final class LibraryCoreAuditRegressionTests: XCTestCase {
    func testTryLockReportsBusyWithoutRunningBodyAndReleasesAfterThrow() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let second = LibraryRepository(applicationSupportURL: fixture.support)
        let result = try fixture.repository.tryWithExclusiveAccess {
            for repository in [fixture.repository, second] {
                let nested = try repository.tryWithExclusiveAccess {
                    XCTFail("A contending lock must not execute its body")
                }
                guard case .busy = nested else {
                    return XCTFail("Expected contention even for the same repository value")
                }
            }
        }
        guard case .acquired = result else { return XCTFail("Expected available lock") }
        XCTAssertThrowsError(try second.tryWithExclusiveAccess {
            // A body error must not be mistaken for lock contention.
            throw LibraryAdvisoryLockError.timedOut(url: fixture.primaryURL, timeout: 17)
        }) { error in
            guard case LibraryAdvisoryLockError.timedOut(_, 17) = error else {
                return XCTFail("Expected the original body error")
            }
        }
        let saved = try fixture.repository.save([], expectedVersion: fixture.version)
        XCTAssertEqual(saved.applications, [])
    }

    @MainActor
    func testLoadWithoutRepositoryAlsoPreservesSelection() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let store = LibraryStore(persistence: LibraryPersistence(applicationSupportURL: fixture.support))
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertNil(store.selectedProfileID)
        store.selectedApplicationID = fixture.application.id
        store.selectedProfileID = fixture.application.profiles[1].id
        store.load()
        XCTAssertEqual(store.selectedProfileID, fixture.application.profiles[1].id)
    }

    @MainActor
    func testRecoveryPassBeyondLimitFailsClosed() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.load(from: fixture.repository, recoveryPass: 5)
        guard case .recoveryRequired = store.loadState else {
            return XCTFail("Nonconverging recovery must fail closed")
        }
        XCTAssertNil(store.currentLibraryVersion)
        XCTAssertTrue(store.applications.isEmpty)
    }

    @MainActor
    func testLoadPreservesValidSelectionAndNeverSelectsFirstItem() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertNil(store.selectedProfileID)
        store.selectedApplicationID = fixture.application.id
        store.selectedProfileID = fixture.application.profiles[0].id
        store.load()
        XCTAssertEqual(store.selectedApplicationID, fixture.application.id)
        XCTAssertEqual(store.selectedProfileID, fixture.application.profiles[0].id)
        var changed = fixture.application
        changed.profiles.removeFirst()
        _ = try fixture.repository.save([changed], expectedVersion: fixture.version)
        store.load()
        XCTAssertEqual(store.selectedApplicationID, fixture.application.id)
        XCTAssertNil(store.selectedProfileID)
        _ = try fixture.repository.save([], expectedVersion: try fixture.snapshot().versionToken)
        store.load()
        XCTAssertNil(store.selectedApplicationID)
    }

    @MainActor
    func testLiveMutationPreventsSecondStoreFromRecoveringRelocation() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let relocation = try fixture.interruptRelocation()
        let firstStore = fixture.makeStore()
        var secondStore: LibraryStore?
        try fixture.repository.withExclusiveMutation(expectedVersion: fixture.version) { _ in
            secondStore = fixture.makeStore(relocation: relocation)
            XCTAssertEqual(try relocation.pendingRelocations().count, 1)
            XCTAssertEqual(secondStore?.applications, firstStore.applications)
        }
        let store = try XCTUnwrap(secondStore)
        store.reloadFromSharedRepository()
        XCTAssertTrue(try relocation.pendingRelocations().isEmpty)
        guard case .loaded = store.loadState else {
            return XCTFail("An abandoned operation must recover once its lock is free")
        }
    }

    @MainActor
    func testNewStoreDuringLiveRelocationPreservesPublishedData() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem())
        let source = try resolver.resolveApplication(configuredBaseRoot: fixture.support.path, applicationStorageID: fixture.application.storageID)
        try FileManager.default.createDirectory(at: source.applicationRoot.url, withIntermediateDirectories: true)
        let sentinel = source.applicationRoot.url.appendingPathComponent("payload")
        try Data("only copy".utf8).write(to: sentinel)
        let destination = fixture.support.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let coordinator = try StorageRelocationCoordinator(
            applicationSupportURL: fixture.support,
            fileSystem: LocalFileSystem(), pathResolver: resolver,
            activityProvider: ProfileActivityRegistry(), availableCapacity: { _ in UInt64.max }
        )
        let backup = LibraryBackupStore(recoveryRoot: fixture.support.appendingPathComponent("Recovery"))
        let repository = LibraryRepository(applicationSupportURL: fixture.support, backupHook: { bytes, reason in
            _ = try backup.createBackup(of: bytes, reason: reason)
        })
        let preview = try coordinator.prepare(application: fixture.application, destinationBaseRoot: destination.path, expectedVersion: fixture.version)
        let prepared = try repository.prepare([preview.relocatedApplication], expectedVersion: fixture.version)
        var peerStore: LibraryStore?
        let outcome = try coordinator.execute(preview, preparedCommit: prepared, repository: repository) { progress in
            if progress == .committingMetadata {
                peerStore = fixture.makeStore(relocation: coordinator)
                XCTAssertTrue(FileManager.default.fileExists(atPath: preview.destination.applicationRoot.url.appendingPathComponent("payload").path))
            }
        }
        XCTAssertEqual(outcome.versionToken, prepared.targetVersion)
        XCTAssertEqual(try Data(contentsOf: preview.destination.applicationRoot.url.appendingPathComponent("payload")), Data("only copy".utf8))
        peerStore?.reloadFromSharedRepository()
        XCTAssertEqual(peerStore?.currentLibraryVersion, prepared.targetVersion)
    }

    @MainActor
    func testInfrastructureFailurePreventsStartupRecoveryEffects() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let relocation = try fixture.interruptRelocation()
        let store = fixture.makeStore(
            relocation: relocation,
            infrastructureError: CocoaError(.fileReadNoPermission)
        )
        XCTAssertNotNil(store.infrastructureFailureMessage)
        XCTAssertEqual(try relocation.pendingRelocations().count, 1)
    }

    @MainActor
    func testBusyLoadDoesNotInspectProfileOrApplicationRemovalJournals() throws {
        for applicationRemoval in [false, true] {
            let fixture = try CoreAuditFixture()
            defer { fixture.remove() }
            let profileTransactions: ProfileDataTransactionCoordinator?
            let removalTransactions: ApplicationRemovalTransactionCoordinator?
            if applicationRemoval {
                profileTransactions = nil
                removalTransactions = try ApplicationRemovalTransactionCoordinator(applicationSupportURL: fixture.support)
                let root = fixture.support.appendingPathComponent("Parallax/ApplicationRemovalTransactions")
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data("incomplete".utf8).write(to: root.appendingPathComponent("\(UUID().uuidString).json"))
            } else {
                profileTransactions = try fixture.corruptProfileJournal()
                removalTransactions = nil
            }
            var peer: LibraryStore?
            try fixture.repository.withExclusiveMutation(expectedVersion: fixture.version) { _ in
                peer = LibraryStore(
                    persistence: LibraryPersistence(applicationSupportURL: fixture.support),
                    repository: LibraryRepository(applicationSupportURL: fixture.support),
                    profileDataTransactions: profileTransactions,
                    applicationRemovalTransactions: removalTransactions
                )
                guard case .loaded = peer?.loadState else {
                    return XCTFail("A live journal must not be interpreted as abandoned")
                }
            }
            peer?.reloadFromSharedRepository()
            guard case .recoveryRequired = peer?.loadState else {
                return XCTFail("A corrupt abandoned journal must still fail closed")
            }
        }
    }

    @MainActor
    func testMissingPrimaryStillChecksPendingTransactions() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let transactions = try fixture.corruptProfileJournal()
        try FileManager.default.removeItem(at: fixture.primaryURL)
        let store = fixture.makeStore(transactions: transactions)
        guard case .recoveryRequired = store.loadState else {
            return XCTFail("A missing primary must not hide a pending journal")
        }
    }

    @MainActor
    func testPeerReloadCannotClearUnrecoveredTransaction() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let transactions = try fixture.corruptProfileJournal()
        let store = fixture.makeStore(transactions: transactions)
        guard case .recoveryRequired = store.loadState else {
            return XCTFail("Expected invalid-journal recovery")
        }
        store.reloadFromSharedRepository()
        guard case .recoveryRequired = store.loadState else {
            return XCTFail("A peer reload must check pending transactions")
        }
    }

    @MainActor
    func testPeerMigrationClearsLegacyReadOnlyState() throws {
        let workspace = try MigrationFixtureWorkspace()
        defer { workspace.remove() }
        try workspace.installFixture(named: "slash-containing-storage-name.json")
        let persistence = LibraryPersistence(applicationSupportURL: workspace.applicationSupportURL)
        let store = LibraryStore(
            persistence: persistence,
            repository: LibraryRepository(applicationSupportURL: workspace.applicationSupportURL)
        )
        XCTAssertNotNil(store.migrationRequiredLibrary)
        try persistence.save([])
        store.reloadFromSharedRepository()
        XCTAssertNil(store.migrationRequiredLibrary)
        XCTAssertTrue(store.canMutateLibrary())
    }

    @MainActor
    func testPassiveReloadDoesNotRetryBlockedMigration() throws {
        let workspace = try MigrationFixtureWorkspace()
        defer { workspace.remove() }
        try workspace.installFixture(named: "slash-containing-storage-name.json")
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        let store = LibraryStore(
            persistence: LibraryPersistence(fileSystem: fileSystem, applicationSupportURL: workspace.applicationSupportURL),
            repository: LibraryRepository(fileSystem: fileSystem, applicationSupportURL: workspace.applicationSupportURL)
        )
        let initialCanonicalizations = fileSystem.occurrenceCount(of: .canonicalize)
        store.reloadFromSharedRepository()
        XCTAssertEqual(fileSystem.occurrenceCount(of: .canonicalize), initialCanonicalizations)
    }

    @MainActor
    func testMigrationDoesNotRunWhilePeerHoldsLibraryLock() throws {
        let workspace = try MigrationFixtureWorkspace()
        defer { workspace.remove() }
        try workspace.installFixture(named: "valid-v1-library.json")
        let prior = try Data(contentsOf: workspace.libraryURL)
        let lock = LibraryAdvisoryLock(url: workspace.parallaxURL.appendingPathComponent(".library.lock"))
        try lock.withExclusiveLock {
            let store = LibraryStore(
                persistence: LibraryPersistence(applicationSupportURL: workspace.applicationSupportURL),
                repository: LibraryRepository(applicationSupportURL: workspace.applicationSupportURL)
            )
            XCTAssertNotNil(store.migrationRequiredLibrary)
            XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), prior)
        }
    }

    @MainActor
    func testCommittedMigrationIsFinalizedOnStoreLoad() throws {
        let workspace = try MigrationFixtureWorkspace()
        defer { workspace.remove() }
        try workspace.installFixture(named: "valid-v1-library.json")
        try workspace.materializeLegacySources()
        let failing = MigrationOccurrenceFailingFileSystem(
            failureRule: .init(.replaceItem, occurrence: 1, timing: .after)
        )
        let coordinator = LibraryMigrationCoordinator(fileSystem: failing, applicationSupportURL: workspace.applicationSupportURL)
        XCTAssertThrowsError(try coordinator.migrateIfNeeded())
        let migrationRoot = workspace.parallaxURL.appendingPathComponent("Migrations")
        let directory = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: migrationRoot, includingPropertiesForKeys: nil).first)
        let receipt = directory.appendingPathComponent("receipt.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: workspace.applicationSupportURL),
            repository: LibraryRepository(applicationSupportURL: workspace.applicationSupportURL)
        )
        guard case .loaded = store.loadState else { return XCTFail("Expected finalized library") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path))
    }

    @MainActor
    func testMigrationBlockerMessageIncludesReasonAndPath() throws {
        let workspace = try MigrationFixtureWorkspace()
        defer { workspace.remove() }
        try workspace.installFixture(named: "reserved-archives-storage-name.json")
        let coordinator = LibraryMigrationCoordinator(fileSystem: LocalFileSystem(), applicationSupportURL: workspace.applicationSupportURL)
        guard case .requiresResolution(let plan) = try coordinator.migrateIfNeeded() else {
            return XCTFail("Expected a blocker")
        }
        let path = try XCTUnwrap(plan.blockers.flatMap(\.canonicalPaths).first)
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: workspace.applicationSupportURL),
            repository: LibraryRepository(applicationSupportURL: workspace.applicationSupportURL)
        )
        let message = try XCTUnwrap(store.errorMessage)
        XCTAssertEqual(store.migrationBlockers, plan.blockers)
        XCTAssertTrue(message.contains(path))
        XCTAssertNotEqual(message, LibraryPersistenceError.migrationRequired(format: try XCTUnwrap(store.migrationRequiredLibrary).format).localizedDescription)
    }

    @MainActor
    func testPublicationRefreshesACompletedOperationsStaleCandidate() async throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let destination = fixture.support.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let relocation = try StorageRelocationCoordinator(
            applicationSupportURL: fixture.support,
            fileSystem: LocalFileSystem(),
            pathResolver: ManagedPathResolver(fileSystem: LocalFileSystem()),
            activityProvider: ProfileActivityRegistry(),
            availableCapacity: { _ in UInt64.max }
        )
        let backup = LibraryBackupStore(recoveryRoot: fixture.support.appendingPathComponent("Recovery"))
        let repository = ContinuationPeerCommitRepository(base: LibraryRepository(
            applicationSupportURL: fixture.support,
            backupHook: { bytes, reason in _ = try backup.createBackup(of: bytes, reason: reason) }
        ))
        let store = LibraryStore(
            persistence: repository.persistence,
            repository: repository,
            storageRelocationCoordinator: relocation,
            profileActivityRegistry: ProfileActivityRegistry()
        )
        let preview = try relocation.prepare(application: fixture.application, destinationBaseRoot: destination.path, expectedVersion: fixture.version)
        store.storageRelocationPreview = preview
        store.beginStorageRelocation(preview)
        let task = try XCTUnwrap(store.storageRelocationTask)
        await task.value
        let current = try fixture.snapshot()
        XCTAssertEqual(store.storageRelocationProgress, .completed)
        XCTAssertEqual(current.applications.first?.displayName, "Peer after operation")
        XCTAssertEqual(store.applications, current.applications)
        XCTAssertEqual(store.currentLibraryVersion, current.versionToken)
        XCTAssertEqual(current.revision.rawValue, fixture.version.revision.rawValue + 2)
    }

    @MainActor
    func testStaleWriterRefreshesStoreForNextSave() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        var peer = fixture.application
        peer.displayName = "Peer"
        let winner = try fixture.repository.save([peer], expectedVersion: fixture.version)
        XCTAssertFalse(store.save())
        XCTAssertEqual(store.applications, [peer])
        XCTAssertEqual(store.currentLibraryVersion, winner.versionToken)
        XCTAssertTrue(store.save())
    }

    @MainActor
    func testTargetCommitFailureRefreshesAndBroadcastsWithoutRecovery() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let failing = MigrationOccurrenceFailingFileSystem(
            failureRule: .init(.replaceItem, occurrence: 1, timing: .after)
        )
        let broadcaster = LibraryChangeBroadcaster()
        let store = fixture.makeStore(fileSystem: failing, broadcaster: broadcaster)
        var candidate = fixture.application
        candidate.displayName = "Committed"
        XCTAssertFalse(store.commit([candidate], selectedApplicationID: nil, selectedProfileID: nil))
        XCTAssertEqual(store.applications, [candidate])
        XCTAssertEqual(store.currentLibraryVersion, try fixture.snapshot().versionToken)
        XCTAssertNotNil(broadcaster.latestEvent)
        guard case .loaded = store.loadState else { return XCTFail("Known target is healthy") }
    }

    @MainActor
    func testEditPersistenceHandlesTargetAndNeitherCommitFailures() throws {
        for targetSurvives in [true, false] {
            for profileEdit in [true, false] {
                let fixture = try CoreAuditFixture()
                defer { fixture.remove() }
                let failing = MigrationOccurrenceFailingFileSystem()
                failing.afterOperation = { event in
                    guard event.operation == .replaceItem, let primary = event.firstURL else { return }
                    if !targetSurvives { try Data("invalid".utf8).write(to: primary) }
                    throw CocoaError(.fileWriteUnknown)
                }
                let store = fixture.makeStore(fileSystem: failing)
                if profileEdit {
                    var profile = fixture.application.profiles[0]
                    profile.notes = "Saved"
                    XCTAssertThrowsError(try store.persistProfileEdit(profile, applicationID: fixture.application.id, expectedVersion: fixture.version))
                } else {
                    var application = fixture.application
                    application.displayName = "Saved"
                    XCTAssertThrowsError(try store.persistApplicationEdit(application, expectedVersion: fixture.version))
                }
                if targetSurvives {
                    XCTAssertEqual(store.currentLibraryVersion, try fixture.snapshot().versionToken)
                    guard case .loaded = store.loadState else { return XCTFail("Known target is healthy") }
                } else {
                    guard case .recoveryRequired = store.loadState else { return XCTFail("Unknown primary must fail closed") }
                }
            }
        }
    }

    @MainActor
    func testEditPersistenceCannotClearRecoveryState() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        store.loadState = .recoveryRequired(originalBytes: nil, message: "Fixture")
        XCTAssertThrowsError(try store.persistApplicationEdit(fixture.application, expectedVersion: fixture.version))
        XCTAssertThrowsError(try store.persistProfileEdit(fixture.application.profiles[0], applicationID: fixture.application.id, expectedVersion: fixture.version))
        XCTAssertEqual(try fixture.snapshot().versionToken, fixture.version)
    }

    @MainActor
    func testConflictMessagesUseFieldLabels() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        XCTAssertFalse(store.handleProfileEditResult(.conflicts([.argumentsText, .childEnvironmentPolicy])))
        let message = try XCTUnwrap(store.errorMessage)
        XCTAssertFalse(message.contains("argumentsText"))
        XCTAssertFalse(message.contains("childEnvironmentPolicy"))
    }

    @MainActor
    func testRepositoryOnlyInjectionUsesItsPersistenceRoot() throws {
        let fixture = try CoreAuditFixture()
        defer { fixture.remove() }
        let guardFileSystem = MigrationOccurrenceFailingFileSystem()
        guardFileSystem.beforeOperation = { event in
            if event.operation == .applicationSupportURL { throw CocoaError(.fileReadNoPermission) }
        }
        let store = LibraryStore(repository: fixture.repository, fileSystem: guardFileSystem)
        let persistence = try XCTUnwrap(store.persistence as? LibraryPersistence)
        XCTAssertEqual(try persistence.libraryURL(), fixture.primaryURL)
        XCTAssertEqual(guardFileSystem.occurrenceCount(of: .applicationSupportURL), 0)
    }
}

private struct CoreAuditFixture {
    let support: URL
    let application: ManagedApplication
    let repository: LibraryRepository
    let version: LibraryVersionToken
    var primaryURL: URL { support.appendingPathComponent("Parallax/library.json") }

    init() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-CoreAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        application = ManagedApplication(
            displayName: "Fixture", appPath: "/Synthetic/Fixture.app",
            baseStoragePath: support.path,
            profiles: [LaunchProfile(name: "First"), LaunchProfile(name: "Second")]
        )
        repository = LibraryRepository(applicationSupportURL: support)
        version = try repository.save([application], expectedVersion: .missing).versionToken
    }

    func remove() { try? FileManager.default.removeItem(at: support) }

    func snapshot() throws -> LibraryRepositorySnapshot {
        guard case .loaded(let snapshot) = repository.load() else { throw CocoaError(.fileReadCorruptFile) }
        return snapshot
    }

    @MainActor
    func makeStore(
        relocation: StorageRelocationCoordinator? = nil,
        transactions: ProfileDataTransactionCoordinator? = nil,
        infrastructureError: Error? = nil,
        fileSystem: any FileSystem = LocalFileSystem(),
        broadcaster: LibraryChangeBroadcaster? = nil
    ) -> LibraryStore {
        LibraryStore(
            persistence: LibraryPersistence(fileSystem: fileSystem, applicationSupportURL: support),
            repository: LibraryRepository(fileSystem: fileSystem, applicationSupportURL: support),
            profileDataTransactions: transactions,
            storageRelocationCoordinator: relocation,
            profileActivityRegistry: ProfileActivityRegistry(),
            profileActivityBootstrapError: infrastructureError,
            libraryChangeBroadcaster: broadcaster
        )
    }

    func corruptProfileJournal() throws -> ProfileDataTransactionCoordinator {
        let coordinator = try ProfileDataTransactionCoordinator(applicationSupportURL: support)
        let path = support.appendingPathComponent("Parallax/ProfileTransactions/\(UUID().uuidString.lowercased()).plan.json")
        try Data("invalid".utf8).write(to: path)
        return coordinator
    }

    @MainActor
    func interruptRelocation() throws -> StorageRelocationCoordinator {
        let destination = support.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let coordinator = try StorageRelocationCoordinator(
            applicationSupportURL: support,
            fileSystem: LocalFileSystem(),
            pathResolver: ManagedPathResolver(fileSystem: LocalFileSystem()),
            activityProvider: ProfileActivityRegistry(),
            availableCapacity: { _ in UInt64.max },
            transactionBoundary: { boundary in
                if case .afterPlanDurable = boundary { throw CocoaError(.fileWriteUnknown) }
            }
        )
        let preview = try coordinator.prepare(application: application, destinationBaseRoot: destination.path, expectedVersion: version)
        let prepared = try repository.prepare([preview.relocatedApplication], expectedVersion: version)
        XCTAssertThrowsError(try coordinator.execute(preview, preparedCommit: prepared, repository: repository))
        XCTAssertEqual(try coordinator.pendingRelocations().count, 1)
        return coordinator
    }
}


/// Commits a peer's change after the detached executor releases its lock, before
/// returning the executor's older outcome to the real main-actor continuation.
private struct ContinuationPeerCommitRepository: LibraryRepositoryPersisting {
    let base: LibraryRepository
    var persistence: any LibraryRepositoryPersistence { base.persistence }

    func load() -> LibraryRepositoryLoadOutcome { base.load() }
    func prepare(_ applications: [ManagedApplication], expectedVersion: LibraryVersionToken) throws -> PreparedLibraryCommit {
        try base.prepare(applications, expectedVersion: expectedVersion)
    }
    func tryWithExclusiveAccess<T>(_ body: (LibraryExclusiveAccess) throws -> T) throws -> LibraryExclusiveAccessResult<T> {
        try base.tryWithExclusiveAccess(body)
    }
    func save(_ applications: [ManagedApplication], expectedVersion: LibraryVersionToken, backupReason: LibraryBackupReason?) throws -> LibraryRepositorySnapshot {
        try base.save(applications, expectedVersion: expectedVersion, backupReason: backupReason)
    }
    func withExclusiveMutation<T>(expectedVersion: LibraryVersionToken, _ body: (LibraryMutationCommitCapability) throws -> T) throws -> T {
        let result = try base.withExclusiveMutation(expectedVersion: expectedVersion, body)
        guard case .loaded(let snapshot) = base.load(), !snapshot.applications.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var peer = snapshot.applications
        peer[0].displayName = "Peer after operation"
        _ = try base.save(peer, expectedVersion: snapshot.versionToken)
        return result
    }
}
