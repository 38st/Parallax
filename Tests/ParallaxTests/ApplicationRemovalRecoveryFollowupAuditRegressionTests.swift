import Darwin
import Foundation
import XCTest
@testable import Parallax

final class ApplicationRemovalRecoveryFollowupAuditRegressionTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = root.appendingPathComponent("RemovalRecoveryFollowup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testProductionIdentityReadsUUIDForStorageBelowVolumeRoot() throws {
        let storage = root.appendingPathComponent("Storage/Nested")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        let identity = try ApplicationRemovalTransactionRootIdentity.read(SecureManagedFileSystem(rootURL: storage))
        XCTAssertNotNil(identity.volumeUUID)
        XCTAssertNotNil(identity.volumeUUID.flatMap(UUID.init(uuidString:)))
    }

    func testRecoveryReportsUnavailableStorageAfterDisconnect() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .commitMetadata)
        try FileManager.default.moveItem(at: fixture.base, to: root.appendingPathComponent("Disconnected"))
        XCTAssertThrowsError(try fixture.recover()) { error in
            XCTAssertEqual((error as? ApplicationRemovalTransactionError)?.code, .storageUnavailable)
        }
        XCTAssertEqual(try fixture.journal.pendingTransactions(), [fixture.transactionID])
    }

    func testFinderMetadataDoesNotPreventFinishOrRollback() throws {
        for committed in [false, true] {
            let fixture = try fixture(.delete)
            try fixture.interrupt(after: committed ? .commitMetadata : .stageProfile(fixture.application.profiles[0].storageID, 0))
            let staging = URL(fileURLWithPath: fixture.manifest.stagingRootPath)
            for name in [".DS_Store", "._profile"] {
                try Data("Finder metadata".utf8).write(to: staging.appendingPathComponent(name))
            }
            XCTAssertEqual(try fixture.recover().completion, committed ? .committed : .rolledBack)
            XCTAssertTrue(try fixture.journal.pendingTransactions().isEmpty)
        }
    }

    func testLegacyPartialRollbackAcceptsRecreatedSource() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .stageProfile(fixture.application.profiles[0].storageID, 0))
        let restored = fixture.sources[1]
        try FileManager.default.moveItem(at: restored, to: root.appendingPathComponent("OldRestoredSource"))
        try FileManager.default.createDirectory(at: restored, withIntermediateDirectories: true)
        try Data("recreated".utf8).write(to: restored.appendingPathComponent("replacement.txt"))
        try fixture.journal.persist(fixture.manifest)
        XCTAssertEqual(try fixture.recover().completion, .rolledBack)
        XCTAssertEqual(try String(contentsOf: restored.appendingPathComponent("replacement.txt"), encoding: .utf8), "recreated")
        XCTAssertEqual(try String(contentsOf: fixture.sources[0].appendingPathComponent("payload.txt"), encoding: .utf8), "payload 0")
    }

    func testInferredCommitReportsMissingData() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .commitMetadata)
        var manifest = try fixture.journal.loadManifest(transactionID: fixture.transactionID)
        manifest.phase = .prepared
        try fixture.journal.persist(manifest)
        try FileManager.default.removeItem(atPath: manifest.entries[0].stagedPath)
        XCTAssertThrowsError(try fixture.recover()) { error in
            XCTAssertEqual((error as? ApplicationRemovalTransactionError)?.code, .missingManagedData)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifest.entries[1].stagedPath))
    }

    func testRestoredLibraryRollsBackCommittedRemoval() throws {
        for choice in [ApplicationRemovalDataChoice.archive, .delete] {
            let fixture = try fixture(choice)
            try fixture.interrupt(after: .commitMetadata)
            guard case .loaded(let removed) = fixture.repository.load() else { return XCTFail() }
            _ = try fixture.repository.save([fixture.application], expectedVersion: removed.versionToken)
            XCTAssertEqual(try fixture.recover().completion, .rolledBack)
            for (index, source) in fixture.sources.enumerated() {
                XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8), "payload \(index)")
            }
        }
    }

    func testRestoredLibraryNeverPurgesPartiallyDeletedTombstone() throws {
        let fixture = try fixture(.delete)
        let coordinator = try fixture.coordinator { boundary in
            if case .afterEffectBeforeRecord(.purgeChild(_, _)) = boundary {
                throw ApplicationRemovalTransactionInterruption.simulatedCrash
            }
        }
        XCTAssertThrowsError(try fixture.execute(coordinator))
        guard case .loaded(let removed) = fixture.repository.load() else { return XCTFail() }
        _ = try fixture.repository.save([fixture.application], expectedVersion: removed.versionToken)
        let before = try FileManager.default.subpathsOfDirectory(atPath: fixture.base.path).sorted()
        XCTAssertThrowsError(try fixture.recover())
        // Recovery can restore other complete profiles, but must preserve the tombstone payload.
        let tombstone = try ApplicationRemovalTransactionPaths.tombstone(fixture.manifest.entries[0], transactionID: fixture.transactionID)
        let secure = try SecureManagedFileSystem(rootURL: fixture.base)
        XCTAssertFalse(try ApplicationRemovalTransactionFileSystem.children(of: tombstone, in: secure).isEmpty)
        XCTAssertFalse(before.isEmpty)
        XCTAssertEqual(try fixture.journal.pendingTransactions(), [fixture.transactionID])
    }

    func testUnsupportedTreeMessageNamesSpaceAndItem() throws {
        let fixture = try fixture(.delete)
        let link = fixture.sources[0].appendingPathComponent("SingletonLock")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "stale-host")
        XCTAssertThrowsError(try fixture.execute(fixture.coordinator())) { error in
            XCTAssertEqual((error as? ApplicationRemovalTransactionError)?.code, .unsupportedProfileTree)
            XCTAssertTrue(error.localizedDescription.contains("SingletonLock"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains(fixture.application.profiles[0].name), error.localizedDescription)
        }
        XCTAssertTrue(try fixture.journal.pendingTransactions().isEmpty)
    }

    private func fixture(_ choice: ApplicationRemovalDataChoice) throws -> RemovalAuditFixture {
        try RemovalAuditFixture(root: root.appendingPathComponent(UUID().uuidString), choice: choice, createData: true)
    }
}

extension ApplicationRemovalRecoveryFollowupAuditRegressionTests {
    @MainActor
    func testInfrastructureFailureCannotRetireRemovalJournal() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .stageProfile(fixture.application.profiles[0].storageID, 0))
        let coordinator = try fixture.coordinator()
        let review = try coordinator.recoveryReview(transactionID: fixture.transactionID)
        let store = LibraryStore(repository: fixture.repository, applicationRemovalTransactions: coordinator,
            profileActivityRegistry: ProfileActivityRegistry(), profileActivityBootstrapError: FollowupAuditError.infrastructure,
            settings: AppSettings())
        XCTAssertNotNil(store.infrastructureFailureMessage)
        store.keepApplicationRemovalFilesAndContinue(review)
        XCTAssertEqual(try fixture.journal.pendingTransactions(), [fixture.transactionID])
        guard case .recoveryRequired = store.loadState else { return XCTFail("Infrastructure recovery must remain active") }
        XCTAssertTrue(store.applications.isEmpty)
    }

    @MainActor
    func testKeepFilesReloadsAndRetriesRemainingJournals() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .stageProfile(fixture.application.profiles[0].storageID, 0))
        try FileManager.default.createDirectory(at: fixture.sources[0], withIntermediateDirectories: true)
        let coordinator = try fixture.coordinator()
        let store = LibraryStore(repository: fixture.repository, applicationRemovalTransactions: coordinator,
            profileActivityRegistry: ProfileActivityRegistry(), settings: AppSettings())
        let original = fixture.manifest
        let other = ApplicationRemovalTransactionManifest(transactionID: UUID(), applicationID: original.applicationID,
            applicationStorageID: original.applicationStorageID, dataChoice: .keep,
            priorRevision: original.priorRevision, priorSHA256: original.priorSHA256,
            targetRevision: original.targetRevision, targetSHA256: original.targetSHA256,
            stagingRootPath: original.stagingRootPath, phase: .prepared, entries: [])
        try fixture.journal.persist(other)
        store.keepApplicationRemovalFilesAndContinue(try coordinator.recoveryReview(transactionID: fixture.transactionID))
        XCTAssertTrue(try fixture.journal.pendingTransactions().isEmpty)
        XCTAssertEqual(store.applications, [fixture.application])
        XCTAssertTrue(store.canMutateLibrary())
    }

    @MainActor
    func testKeepFilesReportsLibraryProblemAccurately() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .stageProfile(fixture.application.profiles[0].storageID, 0))
        try FileManager.default.createDirectory(at: fixture.sources[0], withIntermediateDirectories: true)
        let coordinator = try fixture.coordinator()
        let store = LibraryStore(repository: fixture.repository, applicationRemovalTransactions: coordinator,
            profileActivityRegistry: ProfileActivityRegistry(), settings: AppSettings())
        try Data("damaged library".utf8).write(to: fixture.root.appendingPathComponent("Parallax/library.json"))
        store.keepApplicationRemovalFilesAndContinue(try coordinator.recoveryReview(transactionID: fixture.transactionID))
        XCTAssertTrue(store.errorMessage?.contains("library") == true, store.errorMessage ?? "No error")
        XCTAssertEqual(try fixture.journal.pendingTransactions(), [fixture.transactionID])
    }
}

private enum FollowupAuditError: Error { case infrastructure }

extension ApplicationRemovalRecoveryFollowupAuditRegressionTests {
    @MainActor
    func testPendingRecoveryAPIExplainsHealthyLibraryAndRetryConverges() async throws {
        let fixture = try fixture(.delete)
        let coordinator = try fixture.coordinator()
        let store = LibraryStore(repository: fixture.repository, applicationRemovalTransactions: coordinator,
            profileActivityRegistry: ProfileActivityRegistry(), settings: AppSettings())
        try fixture.interrupt(after: .stageProfile(fixture.application.profiles[0].storageID, 0))
        guard case .loaded(let snapshot) = fixture.repository.load() else { return XCTFail() }
        XCTAssertTrue(store.presentPendingApplicationRemovalRecovery(
            ApplicationRemovalTransactionError(code: .storageUnavailable), loadedLibrary: snapshot))
        XCTAssertTrue(store.isPendingApplicationRemovalRecovery)
        XCTAssertNotNil(store.applicationRemovalRecoveryDetail)
        XCTAssertNil(store.startOverAuthorization())
        XCTAssertTrue(store.applications.isEmpty)
        XCTAssertNil(store.libraryVersionToken)
        store.isShowingApplicationRemovalConfirmation = false
        XCTAssertTrue(store.isPendingApplicationRemovalRecovery, "Close must not lose the recovery reason")
        store.clearPendingApplicationRemovalRecoveryReason()
        XCTAssertFalse(store.isPendingApplicationRemovalRecovery)
        XCTAssertTrue(store.presentPendingApplicationRemovalRecovery(
            ApplicationRemovalTransactionError(code: .storageUnavailable), loadedLibrary: snapshot))
        store.retryApplicationRemovalRecovery()
        await store.refreshApplicationRemovalRecoveryReviews()
        XCTAssertTrue(store.canMutateLibrary())
        XCTAssertFalse(store.isPendingApplicationRemovalRecovery)
        XCTAssertNil(store.applicationRemovalRecoveryDetail)
        XCTAssertTrue(store.applicationRemovalRecoveryJournals.isEmpty)
    }

    @MainActor
    func testInfrastructureFailureRejectsPendingRecoveryAPI() async throws {
        let fixture = try fixture(.delete)
        let coordinator = try fixture.coordinator()
        let store = LibraryStore(repository: fixture.repository, applicationRemovalTransactions: coordinator,
            profileActivityRegistry: ProfileActivityRegistry(), profileActivityBootstrapError: FollowupAuditError.infrastructure,
            settings: AppSettings())
        guard case .loaded(let snapshot) = fixture.repository.load() else { return XCTFail() }
        XCTAssertFalse(store.presentPendingApplicationRemovalRecovery(
            ApplicationRemovalTransactionError(code: .storageUnavailable), loadedLibrary: snapshot))
        store.retryApplicationRemovalRecovery()
        await store.refreshApplicationRemovalRecoveryReviews()
        XCTAssertFalse(store.isPendingApplicationRemovalRecovery)
        XCTAssertTrue(store.applicationRemovalRecoveryJournals.isEmpty)
        XCTAssertEqual(store.errorMessage, store.infrastructureFailureMessage)
    }

    @MainActor
    func testRecoveryInventoryCachesPerJournalStatusAndRefreshesExplicitly() async throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .stageProfile(fixture.application.profiles[0].storageID, 0))
        try FileManager.default.createDirectory(at: fixture.sources[0], withIntermediateDirectories: true)
        let coordinator = try fixture.coordinator()
        let store = LibraryStore(repository: fixture.repository, applicationRemovalTransactions: coordinator,
            profileActivityRegistry: ProfileActivityRegistry(), settings: AppSettings())
        // The existing journal failed during load; this new journal has never been attempted.
        let original = fixture.manifest
        let unattempted = ApplicationRemovalTransactionManifest(transactionID: UUID(), applicationID: original.applicationID,
            applicationStorageID: original.applicationStorageID, dataChoice: .keep,
            priorRevision: original.priorRevision, priorSHA256: original.priorSHA256,
            targetRevision: original.targetRevision, targetSHA256: original.targetSHA256,
            stagingRootPath: original.stagingRootPath, phase: .prepared, entries: [])
        try fixture.journal.persist(unattempted)
        let unreadableID = UUID()
        let unreadableURL = fixture.journal.rootURL.appendingPathComponent("\(unreadableID.uuidString.lowercased()).json")
        try Data("invalid journal".utf8).write(to: unreadableURL)
        await store.refreshApplicationRemovalRecoveryReviews()
        let cached = store.applicationRemovalRecoveryJournals
        XCTAssertEqual(cached.count, 3)
        XCTAssertEqual(cached.first(where: { $0.id == unattempted.transactionID })?.status, .notAttempted)
        XCTAssertEqual(cached.first(where: { $0.id == fixture.transactionID })?.status,
            .failed(ApplicationRemovalTransactionError(code: .conflictingManagedData).localizedDescription))
        guard case .unreadable = cached.first(where: { $0.id == unreadableID })?.status else { return XCTFail() }
        XCTAssertNil(cached.first(where: { $0.id == unreadableID })?.review)
        try fixture.journal.removeManifest(transactionID: unattempted.transactionID)
        try FileManager.default.removeItem(at: unreadableURL)
        XCTAssertEqual(store.applicationRemovalRecoveryJournals.count, 3, "Rendering must not reread the journals")
        await store.refreshApplicationRemovalRecoveryReviews()
        XCTAssertEqual(store.applicationRemovalRecoveryJournals.count, 1)
    }

    @MainActor
    func testRecoveryInventoryReportsListingFailureAndEmptyFinishedState() async throws {
        let fixture = try fixture(.delete)
        let coordinator = try fixture.coordinator()
        let store = LibraryStore(repository: fixture.repository, applicationRemovalTransactions: coordinator,
            profileActivityRegistry: ProfileActivityRegistry(), settings: AppSettings())
        try FileManager.default.createDirectory(at: fixture.journal.rootURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: fixture.journal.rootURL)
        await store.refreshApplicationRemovalRecoveryReviews()
        XCTAssertNotNil(store.applicationRemovalRecoveryListingError)
        XCTAssertFalse(store.isRefreshingApplicationRemovalRecovery)
        XCTAssertTrue(store.applicationRemovalRecoveryJournals.isEmpty)
        try FileManager.default.removeItem(at: fixture.journal.rootURL)
        await store.refreshApplicationRemovalRecoveryReviews()
        XCTAssertNil(store.applicationRemovalRecoveryListingError)
        XCTAssertFalse(store.isRefreshingApplicationRemovalRecovery)
        XCTAssertTrue(store.applicationRemovalRecoveryJournals.isEmpty)
    }

    func testRestoredLibraryRecoversFinalizedArchiveWithoutMarker() throws {
        let fixture = try fixture(.archive)
        try fixture.interrupt(after: .finalizeArchive(fixture.application.profiles[0].storageID, 0))
        guard case .loaded(let removed) = fixture.repository.load() else { return XCTFail() }
        _ = try fixture.repository.save([fixture.application], expectedVersion: removed.versionToken)
        XCTAssertEqual(try fixture.recover().completion, .rolledBack)
        for (index, source) in fixture.sources.enumerated() {
            XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("payload.txt"), encoding: .utf8), "payload \(index)")
        }
    }

    func testFinderMetadataNamesNeverAuthorizeRemovingDirectories() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .commitMetadata)
        let intruder = URL(fileURLWithPath: fixture.manifest.stagingRootPath).appendingPathComponent("._intruder")
        try FileManager.default.createDirectory(at: intruder, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: intruder.appendingPathComponent("payload"))
        XCTAssertThrowsError(try fixture.recover())
        XCTAssertEqual(try String(contentsOf: intruder.appendingPathComponent("payload"), encoding: .utf8), "keep")
        XCTAssertEqual(try fixture.journal.pendingTransactions(), [fixture.transactionID])
    }
}

extension ApplicationRemovalFlowAuditRegressionTests {
    @MainActor
    func testKeptCopiesRemainReviewableAfterRelaunchAndBlockLaterArchiveDelete() async throws {
        let fixture = try fixture(boundary: { boundary in
            if case .afterEffectBeforeRecord(.stageProfile(_, 0)) = boundary {
                throw ApplicationRemovalTransactionInterruption.simulatedCrash
            }
        })
        for profile in fixture.app.profiles {
            let source = try fixture.store.managedPaths(for: fixture.app, profile: profile).profileRoot.url
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("preserved payload".utf8).write(to: source.appendingPathComponent("payload"))
        }
        fixture.store.beginApplicationRemoval(fixture.app, dataChoice: .delete)
        fixture.store.confirmApplicationRemoval()
        await fixture.store.refreshApplicationRemovalRecoveryReviews()
        let review = try XCTUnwrap(fixture.store.pendingApplicationRemovalRecoveries.first)
        fixture.store.keepApplicationRemovalFilesAndContinue(review)
        XCTAssertTrue(fixture.store.isShowingApplicationRemovalConfirmation, "Preserved locations must remain readable until Close")
        XCTAssertTrue(fixture.store.libraryOperationStatusMessage?.contains("empty data folders") == true)
        for location in review.locations {
            XCTAssertTrue(fixture.store.libraryOperationStatusMessage?.contains(location.path) == true)
        }
        let base = URL(fileURLWithPath: try XCTUnwrap(fixture.app.baseStoragePath))
        let coordinator = try ApplicationRemovalTransactionCoordinator(applicationSupportURL: base.deletingLastPathComponent())
        let reopened = LibraryStore(repository: fixture.repository, backupStore: fixture.backups,
            applicationRemovalTransactions: coordinator, profileActivityRegistry: fixture.registry, settings: AppSettings())
        await reopened.refreshApplicationRemovalRecoveryReviews()
        let receipt = try XCTUnwrap(reopened.preservedApplicationRemovalFiles.first)
        XCTAssertEqual(receipt.locations, review.locations)
        XCTAssertEqual(receipt.applicationStorageID, fixture.app.storageID)
        for choice in [ApplicationRemovalDataChoice.archive, .delete] {
            reopened.beginApplicationRemoval(fixture.app, dataChoice: choice)
            reopened.confirmApplicationRemoval()
            XCTAssertTrue(reopened.errorMessage?.contains("preserved copies") == true, reopened.errorMessage ?? "No error")
            XCTAssertTrue(reopened.applications.contains(where: { $0.id == fixture.app.id }))
            XCTAssertTrue(try coordinator.pendingTransactions().isEmpty)
        }
        let preservedPayloads = receipt.locations.filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("payload").path)
        }
        XCTAssertEqual(preservedPayloads.count, 2)
    }
}

extension ApplicationRemovalRecoveryFollowupAuditRegressionTests {
    @MainActor
    func testRecoveryInventoryReadDoesNotBlockMainActor() async throws {
        let fixture = try fixture(.delete)
        let started = expectation(description: "Background inventory read started")
        let release = DispatchSemaphore(value: 0)
        let coordinator = try ApplicationRemovalTransactionCoordinator(applicationSupportURL: fixture.root,
            recoveryInventoryWillRead: {
                let onMain = Thread.isMainThread
                XCTAssertFalse(onMain)
                started.fulfill()
                if !onMain { release.wait() }
            })
        let store = LibraryStore(repository: fixture.repository, applicationRemovalTransactions: coordinator,
            profileActivityRegistry: ProfileActivityRegistry(), settings: AppSettings())
        let task = Task { await store.refreshApplicationRemovalRecoveryReviews() }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(store.isRefreshingApplicationRemovalRecovery)
        store.isShowingApplicationRemovalConfirmation = false
        XCTAssertFalse(store.isShowingApplicationRemovalConfirmation)
        XCTAssertTrue(store.applicationRemovalRecoveryJournals.isEmpty)
        release.signal()
        await task.value
        XCTAssertFalse(store.isRefreshingApplicationRemovalRecovery)
    }
}
