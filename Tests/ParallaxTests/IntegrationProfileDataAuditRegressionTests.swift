import Darwin
import Foundation
import XCTest
@testable import Parallax

extension ProfileDataAuditRegressionTests {
    func testCompleteIncompatibleJSONIsNeverTorn() throws {
        for kind in ["plan", "record", "receipt"] {
            let f = try fixture(.clear) { boundary in
                if boundary == .beforeEffect(.writeReceipt) { throw CocoaError(.fileWriteUnknown) }
            }
            let path: SecureManagedPath
            if kind == "plan" {
                path = try f.coordinator.controlPlanPath(f.request.transactionID)
            } else {
                XCTAssertThrowsError(try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository, recoverOnFailure: false))
                let log = try f.coordinator.loadLog(transactionID: f.request.transactionID)
                path = kind == "record"
                    ? try f.coordinator.controlRecordPath(transactionID: f.request.transactionID, sequence: log.records.count + 1)
                    : try f.coordinator.controlReceiptPath(f.request.transactionID)
            }
            let bytes = Data("{\"version\":999,\"futureSchema\":true}".utf8)
            try f.coordinator.control.write(bytes, to: path)
            XCTAssertThrowsError(try f.coordinator.pendingTransactions(), kind)
            XCTAssertThrowsError(try recoverRevisionFixture(f), kind)
            XCTAssertEqual(try f.coordinator.readControlFile(path), bytes)
        }
    }

    func testMissingRecoveryPlanReportsTransactionNotFound() throws {
        let f = try fixture()
        XCTAssertThrowsError(try recoverRevisionFixture(f)) {
            XCTAssertEqual(($0 as? ProfileDataTransactionError)?.code, .transactionNotFound)
        }
    }

    func testReceiptWithoutPublicationIntentIsPreserved() throws {
        let f = try fixture()
        let log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
        try f.coordinator.publishPlan(log)
        let path = try f.coordinator.controlReceiptPath(f.request.transactionID)
        try f.coordinator.control.write(Data(), to: path)
        XCTAssertThrowsError(try f.coordinator.pendingTransactions())
        XCTAssertThrowsError(try recoverRevisionFixture(f))
        XCTAssertEqual(try f.coordinator.readControlFile(path), Data())
    }

    func testPrefixMarkerAfterRecordedEffectIsPreserved() throws {
        let f = try fixture(.clear) { boundary in
            if boundary == .afterRecord(.writePayloadMarker) { throw CocoaError(.fileWriteUnknown) }
        }
        try sourceData(f)
        XCTAssertThrowsError(try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository, recoverOnFailure: false))
        let log = try f.coordinator.loadLog(transactionID: f.request.transactionID)
        let marker = f.coordinator.absoluteURL(log.plan.payloadOwnerPath.value, root: log.plan.hostRoot)
        try Data().write(to: marker)
        XCTAssertThrowsError(try recoverRevisionFixture(f))
        XCTAssertEqual(try Data(contentsOf: marker), Data())
    }

    func testPrefixMarkerInPublishedFolderCannotAuthorizeRollback() throws {
        for operation in [ProfileDataTransactionOperation.clear, .duplicate] {
            let f = try fixture(operation) { boundary in
                if boundary == .beforeEffect(.writePayloadMarker) { throw CocoaError(.fileWriteUnknown) }
            }
            try sourceData(f)
            XCTAssertThrowsError(try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository, recoverOnFailure: false))
            var log = try f.coordinator.loadLog(transactionID: f.request.transactionID)
            if operation == .duplicate {
                try f.coordinator.appendRecord(event: .init(phase: .intent, effect: .publishDestination), details: [:], log: &log)
            }
            let container = try XCTUnwrap(operation == .clear ? log.plan.archivePath?.value : log.plan.destinationPath?.value)
            let url = f.coordinator.absoluteURL(container, root: log.plan.hostRoot)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let marker = f.coordinator.absoluteURL(f.coordinator.payloadOwnerPath(for: log, publishedContainer: container), root: log.plan.hostRoot)
            try Data().write(to: marker)
            try Data("foreign".utf8).write(to: url.appendingPathComponent("foreign"))
            XCTAssertThrowsError(try recoverRevisionFixture(f))
            XCTAssertEqual(try Data(contentsOf: marker), Data())
            XCTAssertEqual(try String(contentsOf: url.appendingPathComponent("foreign")), "foreign")
        }
    }

    @MainActor
    func testStartupSweepsProfileTemporaryWithoutPendingTransaction() throws {
        let f = try fixture()
        let temp = f.coordinator.controlRootURL.appendingPathComponent(".parallax-write-" + UUID().uuidString.lowercased())
        try Data("partial".utf8).write(to: temp)
        let store = store(f)
        XCTAssertEqual(store.applications, [f.application])
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path))
    }

    @MainActor
    func testStartupActiveProfileRecoveryWaitsWithoutDamagingLibrary() throws {
        let f = try fixture()
        let log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
        try f.coordinator.publishPlan(log)
        let registry = try ProfileActivityRegistry(applicationSupportURL: f.root, refreshScheduler: SupervisorTestScheduler())
        let identity = ProfileActivityIdentity(applicationID: f.application.id, applicationStorageID: f.application.storageID,
            profileID: f.request.identity.sourceProfileID, profileStorageID: f.request.identity.sourceProfileStorageID)
        let requestID = UUID()
        let lease = try registry.acquireLaunchLease(identity: identity, requestID: requestID)
        let store = store(f)
        XCTAssertEqual(store.applications, [f.application])
        XCTAssertTrue(store.isLibraryOperationInProgress)
        XCTAssertNotNil(store.libraryOperationStatusMessage)
        XCTAssertNil(store.startOverAuthorization())
        try registry.completeDurableLaunch(requestID: requestID, completion: .terminated)
        lease.release()
        store.retryBusyLibraryLoad()
        XCTAssertFalse(store.isLibraryOperationInProgress)
        XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
    }

    @MainActor
    func testExternalClaudeConfigurationIsReported() throws {
        let f = try fixture()
        let store = store(f)
        var profile = try XCTUnwrap(f.application.profiles.first)
        profile.environmentText = "CLAUDE_CONFIG_DIR=/synthetic/external"
        XCTAssertEqual(store.externalDataHandling(for: profile), .configurationOnly(configuredPaths: ["CLAUDE_CONFIG_DIR"]))
        profile.environmentText = "CLAUDE_CONFIG_DIR=\(f.request.source.claudeConfig.url.path)"
        XCTAssertEqual(store.externalDataHandling(for: profile), .notConfigured)
        profile.environmentText = ""
        XCTAssertEqual(store.externalDataHandling(for: profile), .notConfigured)
    }
}

// Older coordinator tests now exercise the production capability-taking API.
extension ProfileDataTransactionCoordinator {
    func recoverUnderTestLock(transactionID: UUID, repository: any LibraryRepositoryPersisting) throws -> ProfileDataTransactionOutcome {
        switch try repository.tryWithExclusiveAccess({ access in
            try recover(transactionID: transactionID, repository: repository, access: access)
        }) {
        case .acquired(let outcome): return outcome
        case .busy: throw LibraryOperationInProgressError()
        }
    }
}

extension ProfileDataAuditRegressionTests {
    func testPayloadMarkerQuarantineStaysInTransactionStaging() throws {
        let f = try fixture(.clear) { boundary in
            if boundary == .beforeEffect(.writePayloadMarker) { throw CocoaError(.fileWriteUnknown) }
        }
        try sourceData(f)
        XCTAssertThrowsError(try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository, recoverOnFailure: false))
        let log = try f.coordinator.loadLog(transactionID: f.request.transactionID)
        let marker = f.coordinator.absoluteURL(log.plan.payloadOwnerPath.value, root: log.plan.hostRoot)
        try Data().write(to: marker)
        let stage = f.coordinator.absoluteURL(log.plan.stagePath.value, root: log.plan.hostRoot)
        let observed = LaunchTestLocked(false)
        let coordinator = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root, transactionBoundary: { boundary in
            if boundary == .beforeEffect(.removeStaging) {
                observed.mutate { $0 = true }
                XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: stage.path).contains { $0.hasPrefix(".parallax-quarantine-") })
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.request.source.profileRoot.url.path), ["sentinel"])
            }
        })
        try recoverRevisionFixture(f, coordinator: coordinator)
        XCTAssertTrue(observed.value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
    }
}

extension ProfileDataAuditRegressionTests {
    @MainActor
    func testStartupProfileActivityLockContentionIsRetryable() throws {
        let f = try fixture()
        try f.coordinator.publishPlan(f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared))
        let durable = try DurableLaunchActivityStore(applicationSupportURL: f.root)
        let descriptor = open(durable.rootURL.appendingPathComponent(".profile-acquisition.lock").path, O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let store = store(f)
        XCTAssertEqual(store.applications, [f.application])
        XCTAssertTrue(store.isLibraryOperationInProgress)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        store.retryBusyLibraryLoad()
        XCTAssertFalse(store.isLibraryOperationInProgress)
        XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
    }
}
