import AppKit
import Foundation
import Observation
import XCTest
@testable import Parallax

final class LibraryCoreReviewAuditRegressionTests: XCTestCase {
    @MainActor
    func testFailedMigrationDoesNotBlockStartOverPrimary() throws {
        let workspace = try MigrationFixtureWorkspace()
        defer { workspace.remove() }
        try workspace.installFixture(named: "valid-v1-library.json")
        try workspace.materializeLegacySources()
        let failing = MigrationOccurrenceFailingFileSystem(
            failureRule: .init(.replaceItem, occurrence: 1, timing: .before)
        )
        XCTAssertThrowsError(try LibraryMigrationCoordinator(
            fileSystem: failing, applicationSupportURL: workspace.applicationSupportURL
        ).migrateIfNeeded())
        let persistence = LibraryPersistence(applicationSupportURL: workspace.applicationSupportURL)
        try persistence.save([])
        let store = LibraryStore(persistence: persistence, repository: LibraryRepository(applicationSupportURL: workspace.applicationSupportURL))
        guard case .loaded = store.loadState else { return XCTFail("Start Over's readable v2 primary must load") }
        XCTAssertTrue(store.canMutateLibrary())
        XCTAssertTrue(store.applications.isEmpty)
    }

    @MainActor
    func testSavedCurrentLibraryIgnoresStaleMigrationAndStrayEntries() throws {
        let workspace = try interruptedCommittedMigration()
        defer { workspace.remove() }
        let repository = LibraryRepository(applicationSupportURL: workspace.applicationSupportURL)
        guard case .loaded(let snapshot) = repository.load() else { return XCTFail("Expected committed primary") }
        let updated = try repository.save(snapshot.applications, expectedVersion: snapshot.versionToken)
        let root = workspace.parallaxURL.appendingPathComponent("Migrations")
        try Data("Finder".utf8).write(to: root.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("unfinished"), withIntermediateDirectories: true)
        let store = LibraryStore(persistence: repository.persistence, repository: repository)
        guard case .loaded = store.loadState else { return XCTFail("Unrelated migration leftovers must not block a current primary") }
        XCTAssertEqual(store.currentLibraryVersion, updated.versionToken)
        XCTAssertTrue(store.canMutateLibrary())
    }

    @MainActor
    func testMatchingMigrationFinalizationFailureIsOnlyAWarning() throws {
        let workspace = try interruptedCommittedMigration()
        defer { workspace.remove() }
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        fileSystem.beforeOperation = { event in
            if event.operation == .moveItem { throw CocoaError(.fileWriteNoPermission) }
        }
        let repository = LibraryRepository(fileSystem: fileSystem, applicationSupportURL: workspace.applicationSupportURL)
        let store = LibraryStore(persistence: repository.persistence, repository: repository)
        guard case .loaded = store.loadState else { return XCTFail("Finalization must not fail a readable primary") }
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.canMutateLibrary())
    }

    @MainActor
    func testUnsafeLockLeavesReadableLibraryReadOnlyWithoutRecovery() throws {
        let fixture = try CoreReviewFixture()
        defer { fixture.remove() }
        let lockURL = fixture.support.appendingPathComponent("Parallax/.library.lock")
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: fixture.primaryURL)
        let original = try Data(contentsOf: fixture.primaryURL)
        let store = fixture.makeStore()
        guard case .loaded = store.loadState else { return XCTFail("A lock failure must not hide the readable library") }
        XCTAssertEqual(store.applications, [fixture.application])
        XCTAssertFalse(store.canMutateLibrary())
        XCTAssertNotNil(store.errorMessage)
        XCTAssertEqual(try Data(contentsOf: fixture.primaryURL), original)
    }

    @MainActor
    func testStaleWriterExplainsDiscardAndRefresh() throws {
        let fixture = try CoreReviewFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        _ = try fixture.repository.save([], expectedVersion: fixture.version)
        XCTAssertFalse(store.save())
        XCTAssertEqual(store.errorMessage, String(localized: "Your change was not saved because the library changed in another Parallax process. This window was refreshed. Review it before trying again."))
        XCTAssertTrue(store.applications.isEmpty)
    }

    @MainActor
    func testStaleEditFailureKeepsRefreshedWindowMessage() throws {
        let fixture = try CoreReviewFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        _ = try fixture.repository.save([fixture.application], expectedVersion: fixture.version)
        XCTAssertThrowsError(try store.persistApplicationEdit(fixture.application, expectedVersion: fixture.version)) { error in
            let failure = LibraryEditPersistenceFailure(message: error.localizedDescription)
            XCTAssertFalse(store.handleApplicationEditResult(.persistenceFailed(failure)))
            XCTAssertEqual(store.errorMessage, String(localized: "Your change was not saved because the library changed in another Parallax process. This window was refreshed. Review it before trying again."))
        }
    }

    @MainActor
    func testCommittedTargetRetainsCandidateSelection() throws {
        let fixture = try CoreReviewFixture()
        defer { fixture.remove() }
        let failing = MigrationOccurrenceFailingFileSystem(failureRule: .init(.replaceItem, occurrence: 1, timing: .after))
        let store = fixture.makeStore(fileSystem: failing)
        let added = ManagedApplication(displayName: "Added", appPath: "/Synthetic/Added.app", profiles: [LaunchProfile(name: "Selected")])
        XCTAssertFalse(store.commit([fixture.application, added], selectedApplicationID: added.id, selectedProfileID: added.profiles[0].id))
        XCTAssertEqual(store.selectedApplicationID, added.id)
        XCTAssertEqual(store.selectedProfileID, added.profiles[0].id)
    }

    @MainActor
    func testSuccessfulReloadClearsBusyMutationError() throws {
        let fixture = try CoreReviewFixture()
        defer { fixture.remove() }
        let store = fixture.makeStore()
        _ = try fixture.repository.tryWithExclusiveAccess {
            store.reloadFromSharedRepository()
            XCTAssertFalse(store.canMutateLibrary())
            XCTAssertNotNil(store.errorMessage)
        }
        store.reloadFromSharedRepository()
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.libraryOperationStatusMessage)
        XCTAssertTrue(store.canMutateLibrary())
    }

    @MainActor
    func testMigrationUsesRepositoryPersistenceConsistently() throws {
        let workspace = try MigrationFixtureWorkspace()
        defer { workspace.remove() }
        try workspace.installFixture(named: "valid-v1-library.json")
        let unrelated = try CoreReviewFixture()
        defer { unrelated.remove() }
        let repository = LibraryRepository(applicationSupportURL: workspace.applicationSupportURL)
        let unrelatedBytes = try Data(contentsOf: unrelated.primaryURL)
        let store = LibraryStore(persistence: unrelated.repository.persistence, repository: repository)
        guard case .loaded = store.loadState else { return XCTFail("Migration must use the locked repository's persistence") }
        guard case .loaded(let snapshot) = repository.load() else { return XCTFail("Expected migrated repository") }
        XCTAssertEqual(store.applications, snapshot.applications)
        XCTAssertEqual(try Data(contentsOf: unrelated.primaryURL), unrelatedBytes)
    }

    @MainActor
    func testBusyLoadRetriesAutomaticallyWithoutBroadcast() throws {
        let fixture = try CoreReviewFixture()
        defer { fixture.remove() }
        let clock = ManualLibraryReloadClock()
        var store: LibraryStore?
        _ = try fixture.repository.tryWithExclusiveAccess {
            store = fixture.makeStore(retryScheduler: clock.schedule)
            XCTAssertTrue(store?.isLibraryOperationInProgress == true)
            XCTAssertEqual(clock.delays, [.milliseconds(100)])
            clock.advance()
            XCTAssertEqual(clock.delays, [.milliseconds(100), .milliseconds(200)])
        }
        clock.advance()
        let loaded = try XCTUnwrap(store)
        XCTAssertFalse(loaded.isLibraryOperationInProgress)
        XCTAssertTrue(loaded.canMutateLibrary())
        XCTAssertFalse(clock.hasPendingRetry)
    }

    @MainActor
    func testDismissRetriesBusyLoadImmediately() throws {
        let fixture = try CoreReviewFixture()
        defer { fixture.remove() }
        let clock = ManualLibraryReloadClock()
        var store: LibraryStore?
        _ = try fixture.repository.tryWithExclusiveAccess {
            store = fixture.makeStore(retryScheduler: clock.schedule)
        }
        let loaded = try XCTUnwrap(store)
        loaded.dismissLibraryOperationStatus()
        XCTAssertEqual(clock.delays.last, .zero)
        clock.advance()
        XCTAssertTrue(loaded.canMutateLibrary())
    }

    func testExclusiveCapabilityRejectsExpiredAndWrongLibraryAccess() throws {
        let fixture = try CoreReviewFixture()
        defer { fixture.remove() }
        let other = try CoreReviewFixture()
        defer { other.remove() }
        var retained: LibraryExclusiveAccess?
        _ = try fixture.repository.tryWithExclusiveAccess { access in
            retained = access
            XCTAssertNoThrow(try access.validate(for: fixture.repository))
            XCTAssertNoThrow(try access.validate(for: LibraryRepository(applicationSupportURL: fixture.support)))
            XCTAssertThrowsError(try access.validate(for: other.repository))
            let coordinator = try StorageRelocationCoordinator(
                applicationSupportURL: fixture.support, fileSystem: LocalFileSystem(),
                pathResolver: ManagedPathResolver(fileSystem: LocalFileSystem()), activityProvider: ProfileActivityRegistry()
            )
            XCTAssertEqual(try coordinator.recoverAll(repository: fixture.repository, access: access).count, 0)
        }
        let expired = try XCTUnwrap(retained)
        XCTAssertThrowsError(try expired.validate(for: fixture.repository)) { error in
            guard case LibraryRepositoryError.invalidExclusiveAccess = error else { return XCTFail("Expected expired capability") }
        }
    }

    func testNestedMutationFailsFastWithExplicitLockError() throws {
        let fixture = try CoreReviewFixture()
        defer { fixture.remove() }
        let peer = LibraryRepository(applicationSupportURL: fixture.support)
        _ = try fixture.repository.tryWithExclusiveAccess { _ in
            for repository in [fixture.repository, peer] {
                XCTAssertThrowsError(try repository.save([], expectedVersion: fixture.version)) { error in
                    guard case LibraryAdvisoryLockError.nestedAcquisition = error else { return XCTFail("Expected nested-acquisition error, got \(error)") }
                }
                XCTAssertThrowsError(try repository.withExclusiveMutation(expectedVersion: fixture.version) { _ in XCTFail("Nested body must not run") }) { error in
                    guard case LibraryAdvisoryLockError.nestedAcquisition = error else { return XCTFail("Expected nested-acquisition error, got \(error)") }
                }
            }
        }
        XCTAssertNoThrow(try peer.save([], expectedVersion: fixture.version))
    }

    @MainActor
    func testBusyLegacyLoadRetriesMigrationOnceLockIsReleased() throws {
        let workspace = try MigrationFixtureWorkspace()
        defer { workspace.remove() }
        try workspace.installFixture(named: "valid-v1-library.json")
        let repository = LibraryRepository(applicationSupportURL: workspace.applicationSupportURL)
        let clock = ManualLibraryReloadClock()
        var store: LibraryStore?
        _ = try repository.tryWithExclusiveAccess {
            store = LibraryStore(persistence: repository.persistence, repository: repository, libraryReloadRetryScheduler: clock.schedule)
            XCTAssertTrue(store?.isLibraryOperationInProgress == true)
        }
        clock.advance()
        let loaded = try XCTUnwrap(store)
        guard case .loaded = loaded.loadState else { return XCTFail("A busy legacy load must eventually leave loading") }
        XCTAssertTrue(loaded.canMutateLibrary())
        XCTAssertNil(loaded.migrationRequiredLibrary)
    }

    @MainActor
    func testWindowActivationRetriesBusyLoad() async throws {
        let fixture = try CoreReviewFixture()
        defer { fixture.remove() }
        let clock = ManualLibraryReloadClock()
        var store: LibraryStore?
        _ = try fixture.repository.tryWithExclusiveAccess {
            store = fixture.makeStore(retryScheduler: clock.schedule)
        }
        let loaded = try XCTUnwrap(store)
        let refreshed = expectation(description: "Activation retries library load")
        withObservationTracking {
            _ = loaded.isLibraryOperationInProgress
        } onChange: {
            refreshed.fulfill()
        }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertTrue(loaded.canMutateLibrary())
        XCTAssertFalse(clock.hasPendingRetry)
    }

    @MainActor
    func testLockPermissionFailuresDoNotRequireLibraryRecovery() throws {
        for code in [POSIXErrorCode.EACCES, .EROFS, .ELOOP, .EPERM] {
            let fixture = try CoreReviewFixture()
            defer { fixture.remove() }
            let fileSystem = MigrationOccurrenceFailingFileSystem()
            fileSystem.beforeOperation = { event in
                if event.operation == .createDirectory { throw POSIXError(code) }
            }
            let store = fixture.makeStore(fileSystem: fileSystem)
            guard case .loaded = store.loadState else { return XCTFail("Lock access failure \(code) must be read-only") }
            XCTAssertEqual(store.applications, [fixture.application])
            XCTAssertFalse(store.canMutateLibrary())
            XCTAssertFalse(store.isLibraryOperationInProgress)
        }
    }

    @MainActor
    func testMatchingMigrationFinalizesDespiteUnrelatedJournals() throws {
        let workspace = try interruptedCommittedMigration()
        defer { workspace.remove() }
        let root = workspace.parallaxURL.appendingPathComponent("Migrations")
        let original = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        var journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: original.appendingPathComponent("journal.json"))) as? [String: Any])
        let otherID = UUID().uuidString.lowercased()
        journal["migrationID"] = otherID
        journal["targetSHA256"] = String(repeating: "0", count: 64)
        let other = root.appendingPathComponent(otherID)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: journal).write(to: other.appendingPathComponent("journal.json"))
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("unfinished"), withIntermediateDirectories: true)
        let repository = LibraryRepository(applicationSupportURL: workspace.applicationSupportURL)
        let store = LibraryStore(persistence: repository.persistence, repository: repository)
        guard case .loaded = store.loadState else { return XCTFail("Expected readable current library") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.appendingPathComponent("receipt.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("receipt.json").path))
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testMalformedMigrationJournalIsANonBlockingWarning() throws {
        let fixture = try CoreReviewFixture()
        defer { fixture.remove() }
        let directory = fixture.support.appendingPathComponent("Parallax/Migrations/\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("journal.json"))
        let store = fixture.makeStore()
        guard case .loaded = store.loadState else { return XCTFail("Inspection failure must not hide the current library") }
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.canMutateLibrary())
    }

    @MainActor
    func testMultipleMatchingMigrationJournalsRemainUnfinalized() throws {
        let workspace = try interruptedCommittedMigration()
        defer { workspace.remove() }
        let root = workspace.parallaxURL.appendingPathComponent("Migrations")
        let original = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        var journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: original.appendingPathComponent("journal.json"))) as? [String: Any])
        let otherID = UUID().uuidString.lowercased()
        journal["migrationID"] = otherID
        let other = root.appendingPathComponent(otherID)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: journal).write(to: other.appendingPathComponent("journal.json"))
        let repository = LibraryRepository(applicationSupportURL: workspace.applicationSupportURL)
        let store = LibraryStore(persistence: repository.persistence, repository: repository)
        guard case .loaded = store.loadState else { return XCTFail("A readable primary must remain loaded") }
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(store.canMutateLibrary())
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.appendingPathComponent("receipt.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("receipt.json").path))
    }

    func testLocalizedListUsesResolvedBundleLanguage() throws {
        let englishURL = try XCTUnwrap(PackagedRuntimeResources.bundle.url(forResource: "en", withExtension: "lproj"))
        let english = try XCTUnwrap(Bundle(url: englishURL))
        XCTAssertEqual(LibraryLocalizedList.string(from: ["Arguments", "Environment"], bundle: english), "Arguments and Environment")
    }

    private func interruptedCommittedMigration() throws -> MigrationFixtureWorkspace {
        let workspace = try MigrationFixtureWorkspace()
        addTeardownBlock { workspace.remove() }
        try workspace.installFixture(named: "valid-v1-library.json")
        try workspace.materializeLegacySources()
        let failing = MigrationOccurrenceFailingFileSystem(failureRule: .init(.replaceItem, occurrence: 1, timing: .after))
        XCTAssertThrowsError(try LibraryMigrationCoordinator(fileSystem: failing, applicationSupportURL: workspace.applicationSupportURL).migrateIfNeeded())
        return workspace
    }
}

private struct CoreReviewFixture {
    let support: URL
    let application: ManagedApplication
    let repository: LibraryRepository
    let version: LibraryVersionToken
    var primaryURL: URL { support.appendingPathComponent("Parallax/library.json") }

    init() throws {
        support = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-CoreReview-\(UUID().uuidString)")
        let cleanupRoot = support
        var initialized = false
        defer {
            if !initialized { try? removeTestDirectory(at: cleanupRoot) }
        }
        application = ManagedApplication(displayName: "Fixture", appPath: "/Synthetic/Fixture.app", baseStoragePath: support.path, profiles: [LaunchProfile(name: "Space")])
        repository = LibraryRepository(applicationSupportURL: support)
        version = try repository.save([application], expectedVersion: .missing).versionToken
        initialized = true
    }

    func remove() { try? removeTestDirectory(at: support) }

    @MainActor
    func makeStore(
        fileSystem: any FileSystem = LocalFileSystem(),
        retryScheduler: @escaping LibraryReloadRetryScheduler = LibraryReloadRetry.schedule
    ) -> LibraryStore {
        LibraryStore(
            persistence: LibraryPersistence(fileSystem: fileSystem, applicationSupportURL: support),
            repository: LibraryRepository(fileSystem: fileSystem, applicationSupportURL: support),
            profileActivityRegistry: ProfileActivityRegistry(),
            libraryReloadRetryScheduler: retryScheduler
        )
    }
}


@MainActor
private final class ManualLibraryReloadClock {
    private var pending: (@MainActor @Sendable () -> Void)?
    private(set) var delays: [Duration] = []
    var hasPendingRetry: Bool { pending != nil }

    func schedule(after delay: Duration, action: @escaping @MainActor @Sendable () -> Void) -> @MainActor () -> Void {
        delays.append(delay)
        pending = action
        return { self.pending = nil }
    }

    func advance() {
        let action = pending
        pending = nil
        action?()
    }
}
