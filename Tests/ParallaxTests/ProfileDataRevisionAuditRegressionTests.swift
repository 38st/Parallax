import Foundation
import XCTest
@testable import Parallax

extension ProfileDataAuditRegressionTests {
    func recoverRevisionFixture(_ f: Fixture, coordinator: ProfileDataTransactionCoordinator? = nil) throws {
        let result = try f.repository.tryWithExclusiveAccess { access in
            try (coordinator ?? f.coordinator).recover(transactionID: f.request.transactionID, repository: f.repository, access: access)
        }
        guard case .acquired = result else { return XCTFail("Unexpected busy library") }
    }

    func testLegacyTornPlanWithoutEffectsIsQuarantined() throws {
        let f = try fixture()
        let path = try f.coordinator.controlPlanPath(f.request.transactionID)
        try f.coordinator.control.write(Data("{\"version\":".utf8), to: path)
        XCTAssertEqual(try f.coordinator.pendingTransactions().count, 1)
        try recoverRevisionFixture(f)
        XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.coordinator.controlRootURL.path).contains { $0.contains("quarantine") })
    }

    func testLegacyTornTailRecordRecoversButMidChainDamageIsPreserved() throws {
        for hasLaterRecord in [false, true] {
            let f = try fixture()
            var log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
            try f.coordinator.publishPlan(log)
            try f.coordinator.appendRecord(event: .init(phase: .intent, effect: .createTransactionsDirectory), details: [:], log: &log)
            let torn = try f.coordinator.controlRecordPath(transactionID: f.request.transactionID, sequence: 2)
            try f.coordinator.control.write(Data(), to: torn)
            if hasLaterRecord {
                let later = try f.coordinator.controlRecordPath(transactionID: f.request.transactionID, sequence: 3)
                try f.coordinator.control.write(Data("{}".utf8), to: later)
                XCTAssertThrowsError(try f.coordinator.pendingTransactions())
                XCTAssertThrowsError(try recoverRevisionFixture(f))
                XCTAssertEqual(try f.coordinator.readControlFile(torn), Data())
            } else {
                XCTAssertEqual(try f.coordinator.pendingTransactions().count, 1)
                try recoverRevisionFixture(f)
                XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
            }
        }
    }

    func testLegacyTornReceiptAfterIntentIsRecreated() throws {
        let f = try fixture(.delete) { boundary in
            if boundary == .beforeEffect(.writeReceipt) { throw CocoaError(.fileWriteUnknown) }
        }
        XCTAssertThrowsError(try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository, recoverOnFailure: false))
        try f.coordinator.control.write(Data("{\"version\":".utf8), to: f.coordinator.controlReceiptPath(f.request.transactionID))
        XCTAssertEqual(try f.coordinator.pendingTransactions().count, 1)
        let restarted = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root, activityRegistry: f.activityRegistry)
        try recoverRevisionFixture(f, coordinator: restarted)
        XCTAssertTrue(try restarted.pendingTransactions().isEmpty)
    }

    func testLegacyPrefixMarkersRecoverOnlyWithUnfinishedWriteIntent() throws {
        for payload in [false, true] {
            for prefixLength in [-1, 0, 12] {
                let validPrefix = prefixLength >= 0
                let effect: ProfileDataTransactionEffect = payload ? .writePayloadMarker : .writeOwnerMarker
                let f = try fixture(.clear) { boundary in
                    if boundary == .beforeEffect(effect) { throw CocoaError(.fileWriteUnknown) }
                }
                try sourceData(f)
                XCTAssertThrowsError(try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository, recoverOnFailure: false))
                let log = try f.coordinator.loadLog(transactionID: f.request.transactionID)
                let bytes = try f.coordinator.canonicalBytes(ProfileDataTransactionCoordinator.OwnerMarker(
                    version: 1, transactionID: f.request.transactionID, planSHA256: log.planHash))
                let path = payload ? log.plan.payloadOwnerPath.value : log.plan.stageOwnerPath.value
                let fs = try f.coordinator.secureFileSystem(for: log.plan.hostRoot)
                try fs.write(validPrefix ? Data(bytes.prefix(max(0, prefixLength))) : Data("foreign".utf8), to: path)
                let restarted = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root, activityRegistry: f.activityRegistry)
                if validPrefix {
                    XCTAssertEqual(try restarted.pendingTransactions().count, 1)
                    try recoverRevisionFixture(f, coordinator: restarted)
                    XCTAssertTrue(try restarted.pendingTransactions().isEmpty)
                    XCTAssertEqual(try String(contentsOf: f.request.source.profileRoot.url.appendingPathComponent("sentinel")), "source")
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.request.source.profileRoot.url.path), ["sentinel"])
                } else {
                    XCTAssertThrowsError(try recoverRevisionFixture(f, coordinator: restarted))
                    XCTAssertEqual(try f.coordinator.readManagedFile(path, root: log.plan.hostRoot), Data("foreign".utf8))
                }
            }
        }
    }

    func testCommittedInProcessRecoveryReturnsActualOutcome() throws {
        let f = try fixture(.delete) { boundary in
            if boundary == .afterEffectBeforeRecord(.commitMetadata) { throw CocoaError(.fileWriteUnknown) }
        }
        try sourceData(f)
        let outcome = try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository)
        XCTAssertEqual(outcome.dataMutation, .deletedManagedData)
        XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
    }
}

extension ProfileDataAuditRegressionTests {
    @MainActor
    func testAsyncDestructiveActionPreservesSelectionMadeWhileAwaiting() async throws {
        for action in [DestructiveActionOperation.clearProfileData, .duplicateProfileData, .archiveProfileData, .deleteProfileData] {
            let entered = expectation(description: "Data operation reached commit")
            let resume = DispatchSemaphore(value: 0)
            defer { resume.signal() }
            let f = try fixture(.clear) { boundary in
                if boundary == .beforeEffect(.commitMetadata) { entered.fulfill(); resume.wait() }
            }
            try sourceData(f)
            let store = store(f)
            var app = f.application
            let other = LaunchProfile(name: "Other")
            app.profiles.append(other)
            let profile = try XCTUnwrap(app.profiles.first)
            XCTAssertTrue(store.commit([app], selectedApplicationID: app.id, selectedProfileID: profile.id))
            store.requestDestructiveAction(action, application: app, profile: profile)
            let operation = Task { await store.confirmDestructiveActionAsync() }
            // The event holds the commit until selection changes; the bound only detects a hang.
            await fulfillment(of: [entered], timeout: 60)
            store.selectedProfileID = other.id
            resume.signal()
            await operation.value
            XCTAssertEqual(store.selectedProfileID, other.id)
        }
    }
}

extension ProfileSecretAuditRegressionTests {
    func testStaleSecretWriterDiscardsUnpublishedItem() async throws {
        let (store, repository, secrets, profile) = try fixture()
        var updated = store.applications
        updated[0].displayName = "Peer edit"
        _ = try repository.base.save(updated, expectedVersion: XCTUnwrap(store.libraryVersionToken))
        let result = await store.storeKeychainSecret("synthetic", environmentKey: "TOKEN", for: profile)
        XCTAssertFalse(result)
        let stored = await secrets.stored
        let removed = await secrets.removed
        XCTAssertEqual(removed, stored)
    }
}

extension ProfileSecretAuditRegressionTests {
    func testFailedSecretDeletionRestoresReferenceAfterUnrelatedProfileEdit() async throws {
        let (store, _, secrets, profile) = try fixture()
        let saved = await store.storeKeychainSecret("synthetic", environmentKey: "TOKEN", for: profile)
        XCTAssertTrue(saved)
        let original = try XCTUnwrap(store.applications.first?.profiles.first)
        await secrets.failRemoval()
        await secrets.setRemovalHook {
            var changed = store.applications
            changed[0].profiles[0].name = "Edited during deletion"
            XCTAssertTrue(store.commit(changed, selectedApplicationID: store.selectedApplicationID, selectedProfileID: store.selectedProfileID))
        }
        let removed = await store.removeKeychainSecret(environmentKey: "TOKEN", for: original)
        XCTAssertFalse(removed)
        let current = try XCTUnwrap(store.applications.first?.profiles.first)
        XCTAssertEqual(current.name, "Edited during deletion")
        XCTAssertEqual(current.environmentText, original.environmentText)
    }
}

private final class ProfileRevisionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    func take() -> Bool { lock.withLock { defer { value = false }; return value } }
}

extension ProfileDataAuditRegressionTests {
    func testDeletionReallyInterruptedMidTreePreservesReplacementIdentity() throws {
        for replace in [false, true] {
            let f = try fixture(.delete)
            try sourceData(f)
            let child = f.request.source.profileRoot.url.appendingPathComponent("zz-interrupt")
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Data("remaining".utf8).write(to: child.appendingPathComponent("remaining"))
            let log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
            let payload = f.coordinator.absoluteURL(log.plan.payloadPath.value, root: log.plan.hostRoot)
            let marker = f.coordinator.absoluteURL(log.plan.payloadOwnerPath.value, root: log.plan.hostRoot)
            let deleting = ProfileRevisionFlag()
            let coordinator = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root, activityRegistry: f.activityRegistry, transactionBoundary: { boundary in
                if boundary == .beforeEffect(.removeDeletedPayload) { deleting.set() }
            }, secureBoundary: { _, boundary in
                if boundary == .beforeOpenComponent("zz-interrupt"),
                   FileManager.default.fileExists(atPath: payload.path),
                   !FileManager.default.fileExists(atPath: marker.path), deleting.take() {
                    throw CocoaError(.fileWriteUnknown)
                }
            })
            XCTAssertThrowsError(try coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository, recoverOnFailure: false))
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: payload.appendingPathComponent("sentinel").path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: payload.appendingPathComponent("zz-interrupt/remaining").path))
            if replace {
                try FileManager.default.moveItem(at: payload, to: payload.appendingPathExtension("preserved"))
                try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
                try Data("independent".utf8).write(to: payload.appendingPathComponent("user-data"))
                XCTAssertThrowsError(try recoverRevisionFixture(f)) { error in
                    XCTAssertTrue(error.localizedDescription.contains(payload.path))
                }
                XCTAssertEqual(try String(contentsOf: payload.appendingPathComponent("user-data")), "independent")
            } else {
                try recoverRevisionFixture(f)
                XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
            }
        }
    }

    func testMarkerTemporaryStaysInStagingAndRecoverySweepsControlTemps() throws {
        let f = try fixture(.clear)
        try sourceData(f)
        let log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
        let stage = f.coordinator.absoluteURL(log.plan.stagePath.value, root: log.plan.hostRoot)
        let payload = f.coordinator.absoluteURL(log.plan.payloadPath.value, root: log.plan.hostRoot)
        let armed = ProfileRevisionFlag()
        let coordinator = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root, activityRegistry: f.activityRegistry, transactionBoundary: { boundary in
            if boundary == .beforeEffect(.writePayloadMarker) { armed.set() }
        }, secureBoundary: { _, boundary in
            if boundary == .beforeRename, armed.take() {
                let stageNames = try FileManager.default.contentsOfDirectory(atPath: stage.path)
                let payloadNames = try FileManager.default.contentsOfDirectory(atPath: payload.path)
                XCTAssertTrue(stageNames.contains { $0.hasPrefix(".parallax-write-") })
                XCTAssertFalse(payloadNames.contains { $0.hasPrefix(".parallax-write-") })
                throw CocoaError(.fileWriteUnknown)
            }
        })
        XCTAssertThrowsError(try coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository, recoverOnFailure: false))
        let temps = [f.coordinator.controlRootURL, stage.deletingLastPathComponent(), stage].map {
            $0.appendingPathComponent(".parallax-write-" + UUID().uuidString.lowercased())
        }
        for temp in temps { try Data("partial".utf8).write(to: temp) }
        try recoverRevisionFixture(f)
        for temp in temps { XCTAssertFalse(FileManager.default.fileExists(atPath: temp.path)) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.request.source.profileRoot.url.path), ["sentinel"])
    }

    func testJournalReadCapIsFiniteAndLegacySizedDataIsAccepted() throws {
        let f = try fixture()
        let path = try f.coordinator.controlPlanPath(UUID())
        let url = f.coordinator.controlURL(for: path)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(ProfileDataTransactionCoordinator.maximumJournalBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try f.coordinator.readControlFile(path))
        XCTAssertEqual(ProfileDataTransactionCoordinator.maximumJournalBytes, 64 * 1_024 * 1_024)
    }

    func testUndecodableReceiptProofRecordReportsJournalPath() throws {
        let f = try fixture { boundary in
            if boundary == .afterRecord(.writeReceipt) { throw CocoaError(.fileWriteUnknown) }
        }
        XCTAssertThrowsError(try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository, recoverOnFailure: false))
        let log = try f.coordinator.loadLog(transactionID: f.request.transactionID)
        let path = try f.coordinator.controlRecordPath(transactionID: f.request.transactionID, sequence: log.records.count - 1)
        let url = f.coordinator.controlURL(for: path)
        try Data("{".utf8).write(to: url)
        XCTAssertThrowsError(try f.coordinator.pendingTransactions()) { error in
            XCTAssertEqual((error as? ProfileDataTransactionError)?.code, .invalidJournal)
            XCTAssertTrue(error.localizedDescription.contains(url.path))
        }
    }

    func testCompletedHistoryIsBoundedAndInterruptedPruningResumes() throws {
        let f = try fixture()
        var version = f.prepared.priorVersion
        var lastID = f.request.transactionID
        for _ in 0..<12 {
            let id = UUID()
            let request = ProfileDataTransactionRequest(transactionID: id, identity: f.request.identity,
                operation: .clear, source: f.request.source, destination: nil, externalDataHandling: .notConfigured)
            let prepared = try f.repository.prepare([f.application], expectedVersion: version)
            _ = try f.coordinator.execute(request, preparedCommit: prepared, repository: f.repository)
            version = prepared.targetVersion
            lastID = id
        }
        let plans = try FileManager.default.contentsOfDirectory(atPath: f.coordinator.controlRootURL.path).filter { $0.hasSuffix(".plan.json") }
        XCTAssertEqual(plans.count, ProfileDataTransactionCoordinator.retainedCompletedTransactions)
        let interrupted = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root,
            activityRegistry: f.activityRegistry, transactionBoundary: { boundary in
                if boundary == .afterRecord(.writeReceipt) { throw CocoaError(.fileWriteUnknown) }
            })
        lastID = UUID()
        let request = ProfileDataTransactionRequest(transactionID: lastID, identity: f.request.identity,
            operation: .clear, source: f.request.source, destination: nil, externalDataHandling: .notConfigured)
        let prepared = try f.repository.prepare([f.application], expectedVersion: version)
        XCTAssertThrowsError(try interrupted.execute(request, preparedCommit: prepared, repository: f.repository, recoverOnFailure: false))
        let log = try f.coordinator.loadLog(transactionID: lastID)
        let receipt = try XCTUnwrap(f.coordinator.validatedReceiptIfPresent(log: log))
        let marker = ProfileDataTransactionCoordinator.PruningMarker(receipt: receipt,
            intent: log.records[log.records.count - 2], effect: try XCTUnwrap(log.records.last))
        try f.coordinator.control.write(f.coordinator.canonicalBytes(marker), to: f.coordinator.pruningPath(lastID))
        try FileManager.default.removeItem(at: f.coordinator.controlURL(for: f.coordinator.controlRecordPath(transactionID: lastID, sequence: log.records.count)))
        XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
        _ = try f.repository.tryWithExclusiveAccess { access in
            try f.coordinator.performMaintenance(repository: f.repository, access: access)
        }
        XCTAssertFalse(try f.coordinator.hasPruningMarker(lastID))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.coordinator.controlURL(for: try f.coordinator.controlPlanPath(lastID)).path))
    }

    func testRecoveryFailurePreservesBothErrorsAndRestoredData() throws {
        let f = try fixture(.clear) { boundary in
            if boundary == .beforeEffect(.commitMetadata) { throw CocoaError(.fileWriteNoPermission) }
            if boundary == .beforeEffect(.removeOwnerMarker) { throw CocoaError(.fileReadUnknown) }
        }
        try sourceData(f)
        XCTAssertThrowsError(try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository)) { error in
            guard let failure = error as? ProfileDataTransactionRecoveryFailure else { return XCTFail("Expected both errors") }
            XCTAssertEqual((failure.operationError as NSError).code, CocoaError.fileWriteNoPermission.rawValue)
            XCTAssertEqual((failure.recoveryError as NSError).code, CocoaError.fileReadUnknown.rawValue)
        }
        XCTAssertEqual(try String(contentsOf: f.request.source.profileRoot.url.appendingPathComponent("sentinel")), "source")
        XCTAssertEqual(try f.coordinator.pendingTransactions().count, 1)
    }

    func testInProcessEffectTimingMatrixConverges() throws {
        let cases: [(ProfileDataTransactionOperation, [ProfileDataTransactionEffect])] = [
            (.duplicate, [.createTransactionsDirectory, .writeOwnerMarker, .createStaging, .copyToStaging,
                          .writePayloadMarker, .publishDestination, .commitMetadata, .removePayloadMarker,
                          .removeStaging, .removeOwnerMarker, .writeReceipt]),
            (.clear, [.moveToStaging, .publishArchive]),
            (.archive, [.moveToStaging, .publishArchive]),
            (.delete, [.moveToStaging, .removeDeletedPayload]),
            (.relocate, [.copyToStaging, .publishDestination, .removeRelocatedSource])
        ]
        for (operation, effects) in cases {
            for effect in effects {
                for timing in [ProfileDataTransactionBoundary.beforeEffect(effect), .afterEffectBeforeRecord(effect), .afterRecord(effect)] {
                    let once = ProfileRevisionFlag()
                    once.set()
                    let f = try revisionMatrixFixture(operation) { boundary in
                        if boundary == timing, once.take() { throw CocoaError(.fileWriteUnknown) }
                    }
                    try sourceData(f)
                    let outcome = try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository,
                        activityRegistry: ProfileActivityRegistry())
                    XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty, "\(operation) \(timing)")
                    if outcome.dataMutation == .rolledBack {
                        XCTAssertEqual(try String(contentsOf: f.request.source.profileRoot.url.appendingPathComponent("sentinel")), "source")
                        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.request.source.profileRoot.url.path), ["sentinel"])
                        XCTAssertNotNil(outcome.operationFailure)
                    } else if outcome.dataMutation == .archivedManagedData {
                        XCTAssertEqual(try String(contentsOf: XCTUnwrap(outcome.archiveURL).appendingPathComponent("sentinel")), "source")
                    } else if let destination = f.request.destination {
                        XCTAssertEqual(try String(contentsOf: destination.profileRoot.url.appendingPathComponent("sentinel")), "source")
                    } else {
                        XCTAssertEqual(outcome.dataMutation, .deletedManagedData)
                        XCTAssertFalse(FileManager.default.fileExists(atPath: f.request.source.profileRoot.url.path))
                    }
                }
            }
        }
    }

    func revisionMatrixFixture(_ operation: ProfileDataTransactionOperation,
        boundary: @escaping @Sendable (ProfileDataTransactionBoundary) throws -> Void) throws -> Fixture {
        guard operation == .relocate else { return try fixture(operation, boundary: boundary) }
        let f = try fixture(.clear, boundary: boundary)
        let destinationRoot = f.root.appendingPathComponent("Relocated")
        try FileManager.default.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let profile = try XCTUnwrap(f.application.profiles.first)
        let destination = try ManagedPathResolver(fileSystem: LocalFileSystem()).resolve(baseRootURL: destinationRoot,
            applicationStorageID: f.application.storageID, profileStorageID: profile.storageID)
        var target = f.application
        target.baseStoragePath = destinationRoot.path
        let prepared = try f.repository.prepare([target], expectedVersion: f.prepared.priorVersion)
        let request = ProfileDataTransactionRequest(transactionID: f.request.transactionID, identity: .init(
            applicationID: target.id, applicationStorageID: target.storageID, sourceProfileID: profile.id,
            sourceProfileStorageID: profile.storageID, destinationProfileID: profile.id, destinationProfileStorageID: profile.storageID),
            operation: .relocate, source: f.request.source, destination: destination, externalDataHandling: .notConfigured)
        return Fixture(root: f.root, application: f.application, repository: f.repository,
            activityRegistry: f.activityRegistry, coordinator: f.coordinator, request: request, prepared: prepared)
    }
}

private final class ProfileRevisionBusyRepository: LibraryRepositoryPersisting, @unchecked Sendable {
    let base: LibraryRepository
    private let lock = NSLock()
    private var busy = false
    init(_ base: LibraryRepository) { self.base = base }
    func simulatePeerOperation() { lock.withLock { busy = true } }
    var persistence: any LibraryRepositoryPersistence { base.persistence }
    func load() -> LibraryRepositoryLoadOutcome { base.load() }
    func prepare(_ applications: [ManagedApplication], expectedVersion: LibraryVersionToken) throws -> PreparedLibraryCommit {
        try base.prepare(applications, expectedVersion: expectedVersion)
    }
    func save(_ applications: [ManagedApplication], expectedVersion: LibraryVersionToken, backupReason: LibraryBackupReason?) throws -> LibraryRepositorySnapshot {
        try base.save(applications, expectedVersion: expectedVersion, backupReason: backupReason)
    }
    func tryWithExclusiveAccess<T>(_ body: (LibraryExclusiveAccess) throws -> T) throws -> LibraryExclusiveAccessResult<T> {
        if lock.withLock({ busy }) { return .busy }
        return try base.tryWithExclusiveAccess(body)
    }
    func withExclusiveMutation<T>(expectedVersion: LibraryVersionToken, _ body: (LibraryMutationCommitCapability) throws -> T) throws -> T {
        if lock.withLock({ busy }) { throw CocoaError(.fileWriteUnknown) }
        return try base.withExclusiveMutation(expectedVersion: expectedVersion, body)
    }
}

extension ProfileDataAuditRegressionTests {
    @MainActor
    func testFailureReconciliationDoesNotInspectPeerJournalsWhileBusy() throws {
        let f = try fixture()
        let repository = ProfileRevisionBusyRepository(f.repository)
        let store = LibraryStore(repository: repository, profileDataTransactions: f.coordinator,
            profileActivityRegistry: ProfileActivityRegistry(), launcher: AuditNoopLauncher(),
            secretStore: AuditSecretStore(), settings: AppSettings())
        let log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
        try f.coordinator.publishPlan(log)
        repository.simulatePeerOperation()
        XCTAssertNil(store.executeProfileDataTransaction(operation: .clear, application: f.application,
            sourceProfile: try XCTUnwrap(f.application.profiles.first), destinationProfile: nil,
            candidate: [f.application], selectedProfileID: nil, externalDataHandling: .notConfigured))
        guard case .loaded = store.loadState else { return XCTFail("A peer's live operation must not require recovery") }
        XCTAssertEqual(try f.coordinator.pendingTransactions().count, 1)
    }
}

extension ProfileDataAuditRegressionTests {
    func testUnpublishedPlanFailureDoesNotClaimRecoveryFailed() throws {
        let f = try fixture()
        try sourceData(f)
        let once = ProfileRevisionFlag()
        once.set()
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: f.coordinator.controlRootURL.path) }
        let coordinator = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root, activityRegistry: f.activityRegistry, secureBoundary: { _, _ in
            if once.take() {
                try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: f.coordinator.controlRootURL.path)
            }
        })
        XCTAssertThrowsError(try coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository)) { error in
            XCTAssertFalse(error is ProfileDataTransactionRecoveryFailure)
        }
        XCTAssertTrue(try coordinator.pendingTransactions().isEmpty)
        XCTAssertEqual(try String(contentsOf: f.request.source.profileRoot.url.appendingPathComponent("sentinel")), "source")
    }
}

extension ProfileDataAuditRegressionTests {
    func testReplacementPayloadWithCopiedOwnerMarkerIsPreserved() throws {
        let f = try fixture(.delete) { boundary in
            if boundary == .beforeEffect(.removeDeletedPayload) { throw CocoaError(.fileWriteUnknown) }
        }
        try sourceData(f)
        XCTAssertThrowsError(try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository, recoverOnFailure: false))
        let log = try f.coordinator.loadLog(transactionID: f.request.transactionID)
        let payload = f.coordinator.absoluteURL(log.plan.payloadPath.value, root: log.plan.hostRoot)
        let marker = f.coordinator.absoluteURL(log.plan.payloadOwnerPath.value, root: log.plan.hostRoot)
        let markerBytes = try Data(contentsOf: marker)
        try FileManager.default.moveItem(at: payload, to: payload.appendingPathExtension("original"))
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try markerBytes.write(to: marker)
        let userData = payload.appendingPathComponent("user-data")
        try Data("independent".utf8).write(to: userData)
        let restarted = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root, activityRegistry: f.activityRegistry)
        XCTAssertThrowsError(try recoverRevisionFixture(f, coordinator: restarted))
        XCTAssertEqual(try String(contentsOf: userData), "independent")
    }
}


extension ProfileDataAuditRegressionTests {
    func testInProcessRecoveryPrunesCompletedHistory() throws {
        let f = try fixture(.clear) { boundary in
            if boundary == .afterEffectBeforeRecord(.commitMetadata) { throw CocoaError(.fileWriteUnknown) }
        }
        var version = f.prepared.priorVersion
        for _ in 0..<12 {
            let request = ProfileDataTransactionRequest(transactionID: UUID(), identity: f.request.identity,
                operation: .clear, source: f.request.source, destination: nil, externalDataHandling: .notConfigured)
            let prepared = try f.repository.prepare([f.application], expectedVersion: version)
            let outcome = try f.coordinator.execute(request, preparedCommit: prepared, repository: f.repository)
            XCTAssertEqual(outcome.dataMutation, .noManagedData)
            version = prepared.targetVersion
        }
        let plans = try FileManager.default.contentsOfDirectory(atPath: f.coordinator.controlRootURL.path).filter { $0.hasSuffix(".plan.json") }
        XCTAssertEqual(plans.count, ProfileDataTransactionCoordinator.retainedCompletedTransactions)
        XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
    }
}
