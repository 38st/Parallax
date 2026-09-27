import Darwin
import Foundation
import XCTest
@testable import Parallax

@MainActor
final class IntegrationDeferredRecoveryAuditRegressionTests: XCTestCase {
    func testDamagedLeftoverNoticeDoesNotRequireLibraryRecovery() throws {
        for hasCompletedPlan in [false, true] {
            let f = try RelocationAuditFixture()
            defer { f.remove() }
            let preview = try f.preview()
            if hasCompletedPlan {
                try f.publishPlan(preview)
                let plan = try f.coordinator.loadControlPlan(preview.requestID)
                _ = try f.coordinator.writeControlReceipt(plan: plan, completion: .committed,
                    leftoverSourcePaths: [preview.source.applicationRoot.url.path])
            }
            let notice = f.coordinator.controlRootURL.appendingPathComponent(".\(preview.requestID.uuidString.lowercased()).leftovers")
            try Data("damaged informational notice".utf8).write(to: notice)
            let store = LibraryStore(repository: f.repository, storageRelocationCoordinator: f.coordinator,
                profileActivityRegistry: f.registry, settings: AppSettings())
            guard case .loaded = store.loadState else { return XCTFail("An informational notice must not block loading") }
            XCTAssertEqual(store.applications, [f.application])
        }
    }

    func testRelocationNoticeIsPresentedOnceAndDismissalWaitsForLibraryLock() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        let plan = try f.coordinator.loadControlPlan(preview.requestID)
        let path = preview.source.applicationRoot.url.path
        _ = try f.coordinator.writeControlReceipt(plan: plan, completion: .committed, leftoverSourcePaths: [path])
        let store = LibraryStore(repository: f.repository, storageRelocationCoordinator: f.coordinator,
            profileActivityRegistry: f.registry, settings: AppSettings())
        XCTAssertTrue(store.libraryOperationStatusMessage?.contains(path) == true)
        store.libraryOperationStatusMessage = nil
        store.reloadFromSharedRepository()
        store.load()
        XCTAssertNil(store.libraryOperationStatusMessage)
        let reopened = LibraryStore(repository: f.repository, storageRelocationCoordinator: f.coordinator,
            profileActivityRegistry: f.registry, settings: AppSettings())
        let lockURL = f.root.appendingPathComponent("Parallax/.library.lock")
        let descriptor = Darwin.open(lockURL.path, O_RDWR)
        guard descriptor >= 0 else { return XCTFail("Expected library lock") }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        reopened.dismissLibraryOperationStatus()
        XCTAssertEqual(try f.coordinator.recordedLeftoverSourcePaths(), [path])
        XCTAssertTrue(reopened.libraryOperationStatusMessage?.contains(path) == true)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        reopened.dismissLibraryOperationStatus()
        XCTAssertTrue(try f.coordinator.recordedLeftoverSourcePaths().isEmpty)
        reopened.reloadFromSharedRepository()
        XCTAssertNil(reopened.libraryOperationStatusMessage)
    }

    func testDeferredRelocationBlocksLaunchAndPreservesUnrelatedError() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        try f.publishPlan(f.preview())
        let profile = try XCTUnwrap(f.application.profiles.first)
        let lease = try f.registry.acquireDataOperationLease(identities: [.init(applicationID: f.application.id,
            applicationStorageID: f.application.storageID, profileID: profile.id, profileStorageID: profile.storageID)])
        defer { lease.release() }
        let launcher = DeferredRecoveryRecordingLauncher()
        let store = LibraryStore(repository: f.repository, storageRelocationCoordinator: f.coordinator,
            profileActivityRegistry: f.registry, launcher: launcher, settings: AppSettings())
        XCTAssertTrue(store.isLibraryOperationInProgress)
        store.errorMessage = "Unrelated export error"
        store.reloadFromSharedRepository()
        XCTAssertEqual(store.errorMessage, "Unrelated export error")
        store.beginLaunch(profile, application: f.application, requireGlobalConfirmation: false)
        XCTAssertEqual(launcher.opens, 0)
        XCTAssertTrue(store.errorMessage?.contains(profile.name) == true)
        let source = store.launchConfigurationSource(application: f.application, profile: profile, requestID: UUID())
        XCTAssertTrue(store.registerDirectLaunchIfNeeded(application: f.application, profile: profile, source: source))
        store.performLaunch(application: f.application, profile: profile, preparedSource: source)
        XCTAssertEqual(store.launchRequests.status(for: source.requestID)?.state, .cancelled)
        XCTAssertEqual(launcher.opens, 0)
    }

    func testRemovalReservationConflictsAreNotFailedRecoveryAttempts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let f = try RemovalAuditFixture(root: root, choice: .delete, createData: true)
        try f.interrupt(after: .stageProfile(f.application.profiles[0].storageID, 0))
        let registry = try ProfileActivityRegistry(applicationSupportURL: root, refreshScheduler: SupervisorTestScheduler())
        let profile = f.application.profiles[0]
        let lease = try registry.acquireDataOperationLease(identities: [.init(applicationID: f.application.id,
            applicationStorageID: f.application.storageID, profileID: profile.id, profileStorageID: profile.storageID)])
        let coordinator = try f.coordinator()
        let launcher = DeferredRecoveryRecordingLauncher()
        let store = LibraryStore(repository: f.repository, applicationRemovalTransactions: coordinator,
            profileActivityRegistry: registry, launcher: launcher, settings: AppSettings())
        for _ in 0..<6 { store.retryBusyLibraryLoad() }
        XCTAssertTrue(store.isLibraryOperationInProgress)
        XCTAssertNil(coordinator.recoveryAttempts.message(for: f.transactionID))
        store.beginLaunch(f.application.profiles[1], application: f.application, requireGlobalConfirmation: false)
        XCTAssertEqual(launcher.opens, 0)
        lease.release()
        store.retryBusyLibraryLoad()
        XCTAssertFalse(store.isLibraryOperationInProgress)
        XCTAssertTrue(try coordinator.pendingTransactions().isEmpty)
    }
}

extension ProfileDataAuditRegressionTests {
    @MainActor
    func testBusyLibraryLockAllowsUnaffectedSpaceButRefusesPendingTransactionSpace() throws {
        let f = try fixture()
        try sourceData(f)
        let unaffected = LaunchProfile(name: "Unaffected")
        var application = f.application
        application.profiles.append(unaffected)
        let snapshot = try f.repository.save([application], expectedVersion: f.prepared.priorVersion)
        let prepared = try f.repository.prepare([application], expectedVersion: snapshot.versionToken)
        let log = try f.coordinator.preparePlan(request: f.request, preparedCommit: prepared)
        try f.coordinator.publishPlan(log)
        let planURL = f.coordinator.controlURL(for: try f.coordinator.controlPlanPath(f.request.transactionID))
        let planBytes = try Data(contentsOf: planURL)
        let journalEntries = try FileManager.default.contentsOfDirectory(atPath: f.coordinator.controlRootURL.path).sorted()

        let descriptor = Darwin.open(f.root.appendingPathComponent("Parallax/.library.lock").path, O_RDWR)
        guard descriptor >= 0 else { return XCTFail("Expected library lock") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return XCTFail("Expected to hold library lock") }
        defer { _ = flock(descriptor, LOCK_UN) }
        let launcher = DeferredRecoveryRecordingLauncher()
        let store = LibraryStore(repository: f.repository, profileDataTransactions: f.coordinator,
            profileActivityRegistry: f.activityRegistry, launcher: launcher, settings: AppSettings(),
            libraryReloadRetryScheduler: { _, _ in {} })
        XCTAssertTrue(store.isLibraryOperationInProgress)
        XCTAssertEqual(store.pendingRecoveryIdentities, f.coordinator.activityIdentities(f.request.identity))
        let affected = try XCTUnwrap(application.profiles.first)
        store.beginLaunch(affected, application: application, requireGlobalConfirmation: false)
        XCTAssertEqual(launcher.opens, 0)
        let profileName: String = affected.name
        XCTAssertEqual(store.errorMessage, String(localized: "Wait for storage recovery to finish before opening \(profileName)."))
        store.beginLaunch(unaffected, application: application, requireGlobalConfirmation: false)
        XCTAssertEqual(launcher.opens, 1)
        XCTAssertTrue(store.isLibraryOperationInProgress)
        XCTAssertEqual(try Data(contentsOf: planURL), planBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.coordinator.controlRootURL.path).sorted(), journalEntries)
        XCTAssertEqual(try String(contentsOf: f.request.source.profileRoot.url.appendingPathComponent("sentinel")), "source")
    }

    @MainActor
    func testBusyLibraryLockRefusesLaunchWhenJournalListingFailsAndRetriesReadOnly() throws {
        let f = try fixture()
        let log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
        try f.coordinator.publishPlan(log)
        let planURL = f.coordinator.controlURL(for: try f.coordinator.controlPlanPath(f.request.transactionID))
        let planBytes = try Data(contentsOf: planURL)
        // Valid JSON that is not a valid plan makes discovery fail, rather than
        // representing an unpublished torn write that has not touched any data.
        try Data("{}".utf8).write(to: planURL)
        let descriptor = Darwin.open(f.root.appendingPathComponent("Parallax/.library.lock").path, O_RDWR)
        guard descriptor >= 0 else { return XCTFail("Expected library lock") }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return XCTFail("Expected to hold library lock") }
        defer { _ = flock(descriptor, LOCK_UN) }
        let launcher = DeferredRecoveryRecordingLauncher()
        let store = LibraryStore(repository: f.repository, profileDataTransactions: f.coordinator,
            profileActivityRegistry: f.activityRegistry, launcher: launcher, settings: AppSettings(),
            libraryReloadRetryScheduler: { _, _ in {} })
        XCTAssertTrue(store.isLibraryOperationInProgress)
        XCTAssertNil(store.pendingRecoveryIdentities)
        let profile = try XCTUnwrap(f.application.profiles.first)
        store.beginLaunch(profile, application: f.application, requireGlobalConfirmation: false)
        XCTAssertEqual(launcher.opens, 0)
        let profileName: String = profile.name
        XCTAssertEqual(store.errorMessage, String(localized: "Wait for storage recovery to finish before opening \(profileName)."))
        XCTAssertFalse(store.canLaunchDuringRecovery(identity: .init(applicationID: UUID(), applicationStorageID: UUID(),
            profileID: UUID(), profileStorageID: UUID()), profileName: "Unrelated"))

        try planBytes.write(to: planURL)
        store.retryBusyLibraryLoad()
        XCTAssertTrue(store.isLibraryOperationInProgress)
        XCTAssertEqual(store.pendingRecoveryIdentities, f.coordinator.activityIdentities(f.request.identity))
        XCTAssertTrue(store.canLaunchDuringRecovery(identity: .init(applicationID: UUID(), applicationStorageID: UUID(),
            profileID: UUID(), profileStorageID: UUID()), profileName: "Unrelated"))
        XCTAssertEqual(try f.coordinator.pendingTransactions().map(\.transactionID), [f.request.transactionID])
    }

    @MainActor
    func testPendingProfileTransactionCanClearItsBlockingOpeningRecord() throws {
        let f = try fixture(.clear) { boundary in
            if boundary == .afterEffectBeforeRecord(.moveToStaging) { throw CocoaError(.fileWriteUnknown) }
        }
        try sourceData(f)
        XCTAssertThrowsError(try f.coordinator.execute(f.request, preparedCommit: f.prepared,
            repository: f.repository, recoverOnFailure: false))
        let profile = try XCTUnwrap(f.application.profiles.first)
        let identity = ProfileActivityIdentity(applicationID: f.application.id, applicationStorageID: f.application.storageID,
            profileID: profile.id, profileStorageID: profile.storageID)
        let journal = try DurableLaunchActivityStore(applicationSupportURL: f.root)
        let owner = ProcessStartIdentity(processIdentifier: Int32.max, startTimeSeconds: 1, startTimeMicroseconds: 0)
        let requestID = UUID()
        try journal.createRequest(requestID: requestID, identity: identity, ownerProcess: owner)
        try journal.markOpening(requestID: requestID)
        let processState = TestWorkspaceProcessState()
        processState.processInspections[owner.processIdentifier] = .dead
        let registry = try ProfileActivityRegistry(applicationSupportURL: f.root,
            refreshScheduler: SupervisorTestScheduler(), processInspector: processState)
        let launcher = DeferredRecoveryRecordingLauncher()
        let store = LibraryStore(repository: f.repository, profileDataTransactions: f.coordinator,
            profileActivityRegistry: registry, launcher: launcher, settings: AppSettings())
        XCTAssertTrue(store.isLibraryOperationInProgress)
        XCTAssertTrue(store.libraryOperationStatusMessage?.contains(profile.name) == true)
        store.beginLaunch(profile, application: f.application, requireGlobalConfirmation: false)
        XCTAssertEqual(launcher.opens, 0)
        XCTAssertTrue(store.canRequestStuckLaunchRecovery(for: f.application, profile: profile))
        let request = try XCTUnwrap(store.stuckLaunchRecoveryRequest(for: f.application, profile: profile,
            processSnapshotter: processState))
        XCTAssertTrue(store.confirmClearStuckLaunchRecord(request, processSnapshotter: processState))
        store.retryBusyLibraryLoad()
        XCTAssertFalse(store.isLibraryOperationInProgress)
        XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
        XCTAssertEqual(try String(contentsOf: f.request.source.profileRoot.url.appendingPathComponent("sentinel")), "source")
    }

    func testRestoredSourceMarkerRepairWithoutStagingDirectory() throws {
        let f = try fixture()
        try sourceData(f)
        var log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
        try f.coordinator.publishPlan(log)
        try f.coordinator.appendRecord(event: .init(phase: .intent, effect: .writePayloadMarker), details: [:], log: &log)
        let marker = f.coordinator.payloadOwnerPath(for: log, publishedContainer: log.plan.sourcePath.value)
        let fs = try f.coordinator.secureFileSystem(for: log.plan.sourceRoot)
        try fs.write(Data(), to: marker)
        XCTAssertEqual(try fs.itemState(at: log.plan.stagePath.value), .missing)
        XCTAssertNoThrow(try f.coordinator.repairInterruptedMarkers(log: log))
        XCTAssertEqual(try fs.itemState(at: log.plan.stagePath.value), .missing, "Repair must not recreate retired staging")
        let expected = try f.coordinator.canonicalBytes(ProfileDataTransactionCoordinator.OwnerMarker(
            version: 1, transactionID: f.request.transactionID, planSHA256: log.planHash))
        XCTAssertEqual(try f.coordinator.readManagedFile(marker, root: log.plan.sourceRoot), expected)
        try recoverRevisionFixture(f)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.request.source.profileRoot.url.path), ["sentinel"])
    }
}

private final class DeferredRecoveryRecordingLauncher: ApplicationLaunching {
    var opens = 0
    func launch(application: ManagedApplication, profile: LaunchProfile,
                completion: @escaping @Sendable (Result<Void, Error>) -> Void) throws {
        opens += 1
        completion(.failure(CocoaError(.userCancelled)))
    }
}
