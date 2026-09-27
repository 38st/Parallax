import Darwin
import Foundation
import XCTest
@testable import Parallax

final class ProfileDataAuditRegressionTests: XCTestCase {
    struct Fixture {
        let root: URL
        let application: ManagedApplication
        let repository: LibraryRepository
        let coordinator: ProfileDataTransactionCoordinator
        let request: ProfileDataTransactionRequest
        let prepared: PreparedLibraryCommit
    }

    func fixture(_ operation: ProfileDataTransactionOperation = .clear,
                 boundary: (@Sendable (ProfileDataTransactionBoundary) throws -> Void)? = nil) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Parallax-PROF-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let profile = LaunchProfile(name: "Source")
        let copy = LaunchProfile(name: "Copy")
        let app = ManagedApplication(displayName: "Fixture", appPath: root.appendingPathComponent("Fixture.app").path,
                                     baseStoragePath: root.path, profiles: [profile])
        let repository = LibraryRepository(applicationSupportURL: root, backupHook: { _, _ in })
        let initial = try repository.save([app], expectedVersion: .missing)
        var target = app
        if operation == .duplicate { target.profiles.append(copy) }
        if operation == .delete || operation == .archive { target.profiles = [] }
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem())
        let source = try resolver.resolve(baseRootURL: root, applicationStorageID: app.storageID, profileStorageID: profile.storageID)
        let destination = try resolver.resolve(baseRootURL: root, applicationStorageID: app.storageID, profileStorageID: copy.storageID)
        let request = ProfileDataTransactionRequest(transactionID: UUID(), identity: .init(
            applicationID: app.id, applicationStorageID: app.storageID, sourceProfileID: profile.id,
            sourceProfileStorageID: profile.storageID, destinationProfileID: operation == .duplicate ? copy.id : nil,
            destinationProfileStorageID: operation == .duplicate ? copy.storageID : nil), operation: operation,
            source: source, destination: operation == .duplicate ? destination : nil, externalDataHandling: .notConfigured)
        return Fixture(root: root, application: app, repository: repository,
                       coordinator: try ProfileDataTransactionCoordinator(applicationSupportURL: root, transactionBoundary: boundary),
                       request: request, prepared: try repository.prepare([target], expectedVersion: initial.versionToken))
    }

    func sourceData(_ fixture: Fixture) throws {
        try FileManager.default.createDirectory(at: fixture.request.source.profileRoot.url, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: fixture.request.source.profileRoot.url.appendingPathComponent("sentinel"))
    }

    func testLargeLegacyManifestStillLoadsAndRecovers() throws {
        let f = try fixture()
        var log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: log.planBytes) as? [String: Any])
        let entries: [[String: Any]] = (0..<24_000).map { index in
            ["relativeComponents": [String(repeating: "x", count: 100) + String(index)],
             "kind": "regularFile", "byteCount": 1, "permissions": 384, "sha256": String(repeating: "a", count: 64)]
        }
        object["sourceSnapshot"] = ["identity": ["volumeID": 1, "fileID": 2, "kind": "directory"],
                                    "manifest": ["entries": entries]]
        object["version"] = 2
        let legacy = try f.coordinator.decoder.decode(ProfileDataTransactionCoordinator.Plan.self,
            from: JSONSerialization.data(withJSONObject: object))
        let bytes = try f.coordinator.canonicalBytes(legacy)
        XCTAssertGreaterThan(bytes.count, 4 * 1_024 * 1_024)
        log = .init(plan: legacy, planBytes: bytes, planHash: LibraryPersistence.sha256(bytes), records: [])
        try f.coordinator.publishPlan(log)
        try f.coordinator.appendRecord(event: .init(phase: .effect, effect: .createTransactionsDirectory),
            details: ["manifest": try f.coordinator.canonicalBytes(legacy.sourceSnapshot?.manifest).base64EncodedString()], log: &log)
        XCTAssertEqual(try f.coordinator.pendingTransactions().count, 1)
        let result = try f.repository.tryWithExclusiveAccess { access in
            try f.coordinator.recover(transactionID: f.request.transactionID, repository: f.repository, access: access)
        }
        guard case .acquired(let outcome) = result else { return XCTFail("Unexpected busy lock") }
        XCTAssertEqual(outcome.dataMutation, .rolledBack)
    }

    func testNewSnapshotDetailsDoNotEmbedManifest() throws {
        let f = try fixture()
        try sourceData(f)
        let fs = try SecureManagedFileSystem(rootURL: f.root)
        let path = try f.coordinator.securePath(f.request.source.profileRoot.url, relativeTo: f.root)
        let details = try f.coordinator.snapshotDetails(at: path, in: fs)
        XCTAssertNil(details["manifest"])
        XCTAssertNotNil(details["manifestSHA256"])
        XCTAssertNotNil(details["entryCount"])
        let log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: log.planBytes) as? [String: Any])
        let snapshot = try XCTUnwrap(object["sourceSnapshot"] as? [String: Any])
        XCTAssertNil(snapshot["manifest"])
        XCTAssertNotNil(snapshot["manifestSHA256"])
    }

    func testCompletedDiscoveryDoesNotReadPlanOrOldRecords() throws {
        let f = try fixture()
        _ = try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository)
        let plan = f.coordinator.controlURL(for: try f.coordinator.controlPlanPath(f.request.transactionID))
        try Data("completed plan need not be decoded".utf8).write(to: plan)
        let oldRecord = f.coordinator.controlURL(for: try f.coordinator.controlRecordPath(transactionID: f.request.transactionID, sequence: 1))
        try Data("completed history need not be decoded".utf8).write(to: oldRecord)
        XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
    }

    func testInterruptedDeleteWithRemovedPayloadMarkerCanFinish() throws {
        let f = try fixture(.delete)
        try sourceData(f)
        var log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
        try f.coordinator.publishPlan(log)
        let fs = try f.coordinator.secureFileSystem(for: log.plan.sourceRoot)
        try f.coordinator.prepareOwnedStaging(log: &log, hostFS: fs)
        _ = try f.coordinator.applyData(log: &log, sourceFS: fs, destinationFS: nil)
        _ = try f.repository.withExclusiveMutation(expectedVersion: f.prepared.priorVersion) { try $0.commit(f.prepared) }
        try f.coordinator.appendRecord(event: .init(phase: .intent, effect: .removeDeletedPayload), details: [:], log: &log)
        try fs.removeTree(at: log.plan.payloadOwnerPath.value)
        let result = try f.repository.tryWithExclusiveAccess { access in
            try f.coordinator.recover(transactionID: f.request.transactionID, repository: f.repository, access: access)
        }
        guard case .acquired(let outcome) = result else { return XCTFail("Unexpected busy lock") }
        XCTAssertEqual(outcome.dataMutation, .deletedManagedData)
        XCTAssertEqual(try fs.itemState(at: log.plan.payloadPath.value), .missing)
    }

    func testFailureRollsBackClearAndDuplicateBeforeReturning() throws {
        for operation in [ProfileDataTransactionOperation.clear, .duplicate] {
            let f = try fixture(operation) { boundary in
                if boundary == .beforeEffect(.commitMetadata) { throw CocoaError(.fileWriteOutOfSpace) }
            }
            try sourceData(f)
            XCTAssertEqual(try f.coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository).dataMutation, .rolledBack)
            XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.request.source.profileRoot.url.appendingPathComponent("sentinel").path))
            if let destination = f.request.destination {
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.profileRoot.url.path))
            }
        }
    }

    func testCrossRootPayloadOwnerUsesHostRoot() throws {
        let f = try fixture(.duplicate)
        try sourceData(f)
        let host = f.root.appendingPathComponent("DestinationRoot")
        try FileManager.default.createDirectory(at: host, withIntermediateDirectories: true)
        let destination = try ManagedPathResolver(fileSystem: LocalFileSystem()).resolve(
            baseRootURL: host, applicationStorageID: f.application.storageID,
            profileStorageID: try XCTUnwrap(f.request.identity.destinationProfileStorageID))
        let request = ProfileDataTransactionRequest(transactionID: f.request.transactionID, identity: f.request.identity,
            operation: .duplicate, source: f.request.source, destination: destination, externalDataHandling: .notConfigured)
        var log = try f.coordinator.preparePlan(request: request, preparedCommit: f.prepared)
        try f.coordinator.publishPlan(log)
        let hostFS = try f.coordinator.secureFileSystem(for: log.plan.hostRoot)
        let sourceFS = try f.coordinator.secureFileSystem(for: log.plan.sourceRoot)
        try f.coordinator.prepareOwnedStaging(log: &log, hostFS: hostFS)
        try sourceFS.copyTree(from: log.plan.sourcePath.value, to: log.plan.payloadPath.value, in: hostFS)
        try f.coordinator.writePayloadOwnerIfNeeded(log: &log, hostFS: hostFS)
        XCTAssertNoThrow(try f.coordinator.requirePayloadOwner(log: log, fileSystem: hostFS, at: log.plan.payloadOwnerPath.value))
    }

    func testFailedMarkerPublicationDoesNotLeaveAuthoritativeMarker() throws {
        let f = try fixture()
        try sourceData(f)
        let coordinator = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root, secureBoundary: { _, boundary in
            if boundary == .beforeRename { throw CocoaError(.fileWriteUnknown) }
        })
        XCTAssertEqual(try coordinator.execute(f.request, preparedCommit: f.prepared, repository: f.repository).dataMutation, .rolledBack)
        let owner = f.root.appendingPathComponent(".parallax/Transactions/" + f.request.transactionID.uuidString.lowercased() + ".owner")
        XCTAssertFalse(FileManager.default.fileExists(atPath: owner.path))
        XCTAssertTrue(try coordinator.pendingTransactions().isEmpty)
    }

    func testInterruptedPublishedDuplicateRollbackCanResume() throws {
        for legacy in [false, true] {
            let f = try fixture(.duplicate)
            try sourceData(f)
            var log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
            if legacy {
                var object = try XCTUnwrap(JSONSerialization.jsonObject(with: log.planBytes) as? [String: Any])
                object["version"] = 2
                var snapshot = try XCTUnwrap(object["sourceSnapshot"] as? [String: Any])
                snapshot.removeValue(forKey: "manifestSHA256")
                snapshot.removeValue(forKey: "entryCount")
                let sourceFS = try f.coordinator.secureFileSystem(for: log.plan.sourceRoot)
                let manifest = ProfileDataTransactionCoordinator.ManifestValue(try sourceFS.manifest(at: log.plan.sourcePath.value))
                snapshot["manifest"] = try JSONSerialization.jsonObject(with: f.coordinator.canonicalBytes(manifest))
                object["sourceSnapshot"] = snapshot
                let plan = try f.coordinator.decoder.decode(ProfileDataTransactionCoordinator.Plan.self,
                    from: JSONSerialization.data(withJSONObject: object))
                let bytes = try f.coordinator.canonicalBytes(plan)
                log = .init(plan: plan, planBytes: bytes, planHash: LibraryPersistence.sha256(bytes), records: [])
            }
            try f.coordinator.publishPlan(log)
            let fs = try f.coordinator.secureFileSystem(for: log.plan.sourceRoot)
            try f.coordinator.prepareOwnedStaging(log: &log, hostFS: fs)
            _ = try f.coordinator.applyData(log: &log, sourceFS: fs, destinationFS: fs)
            let destination = try XCTUnwrap(log.plan.destinationPath?.value)
            if !legacy {
                try f.coordinator.appendRecord(event: .init(phase: .intent, effect: .removeDuplicateDestination), details: [:], log: &log)
            }
            try fs.removeTree(at: f.coordinator.payloadOwnerPath(for: log, publishedContainer: destination))
            let result = try f.repository.tryWithExclusiveAccess { access in
                try f.coordinator.recover(transactionID: f.request.transactionID, repository: f.repository, access: access)
            }
            guard case .acquired(let outcome) = result else { return XCTFail("Unexpected busy lock") }
            XCTAssertEqual(outcome.dataMutation, .rolledBack)
            XCTAssertEqual(try fs.itemState(at: destination), .missing)
            XCTAssertTrue(FileManager.default.fileExists(atPath: f.request.source.profileRoot.url.appendingPathComponent("sentinel").path))
        }
    }

    func testMissingDeleteMarkerWithoutRemovalIntentPreservesPayload() throws {
        let f = try fixture(.delete)
        try sourceData(f)
        var log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
        try f.coordinator.publishPlan(log)
        let fs = try f.coordinator.secureFileSystem(for: log.plan.sourceRoot)
        try f.coordinator.prepareOwnedStaging(log: &log, hostFS: fs)
        _ = try f.coordinator.applyData(log: &log, sourceFS: fs, destinationFS: nil)
        _ = try f.repository.withExclusiveMutation(expectedVersion: f.prepared.priorVersion) { try $0.commit(f.prepared) }
        try fs.removeTree(at: log.plan.payloadOwnerPath.value)
        XCTAssertThrowsError(try f.repository.tryWithExclusiveAccess { access in
            try f.coordinator.recover(transactionID: f.request.transactionID, repository: f.repository, access: access)
        }) { XCTAssertEqual(($0 as? ProfileDataTransactionError)?.code, .unownedData) }
        XCTAssertNotEqual(try fs.itemState(at: log.plan.payloadPath.value), .missing)
    }

    @MainActor
    func testJournalInspectionFailureKeepsRecoveryRequired() throws {
        let f = try fixture()
        let store = store(f)
        let profile = try XCTUnwrap(f.application.profiles.first)
        let corrupt = f.coordinator.controlRootURL.appendingPathComponent(UUID().uuidString.lowercased() + ".plan.json")
        try Data("corrupt".utf8).write(to: corrupt)
        let lease = try store.profileActivityRegistry.acquireDataOperationLease(identities: [.init(
            applicationID: f.application.id, applicationStorageID: f.application.storageID,
            profileID: profile.id, profileStorageID: profile.storageID)])
        defer { lease.release() }
        XCTAssertNil(store.executeProfileDataTransaction(operation: .clear, application: f.application,
            sourceProfile: profile, destinationProfile: nil, candidate: [f.application], selectedProfileID: nil,
            externalDataHandling: .notConfigured))
        guard case .recoveryRequired = store.loadState else { return XCTFail("Journal read errors must not be treated as no pending work") }
    }

    @MainActor
    func store(_ f: Fixture) -> LibraryStore {
        LibraryStore(repository: f.repository, profileDataTransactions: f.coordinator,
                     profileActivityRegistry: ProfileActivityRegistry(), launcher: AuditNoopLauncher(),
                     secretStore: AuditSecretStore(), settings: AppSettings())
    }

    @MainActor
    func testMissingFolderCanBeConfirmedForEveryProfileAction() throws {
        let f = try fixture()
        let store = store(f)
        let profile = try XCTUnwrap(f.application.profiles.first)
        for operation in [DestructiveActionOperation.clearProfileData, .duplicateProfileData, .removeProfile, .archiveProfileData, .deleteProfileData] {
            store.requestDestructiveAction(operation, application: f.application, profile: profile)
            let request = try XCTUnwrap(store.pendingDestructiveActionRequest, store.errorMessage ?? "")
            XCTAssertNil(request.path.fileIdentity)
            XCTAssertNotNil(try store.currentDestructiveTarget(for: request))
            store.cancelDestructiveAction()
        }
    }

    @MainActor
    func testAsyncRemoveSpaceOnlySucceedsAndDoesNotSelectAnotherSpace() async throws {
        let f = try fixture()
        let store = store(f)
        let profile = try XCTUnwrap(f.application.profiles.first)
        try sourceData(f)
        var app = f.application
        app.profiles.append(LaunchProfile(name: "Other"))
        XCTAssertTrue(store.commit([app], selectedApplicationID: app.id, selectedProfileID: profile.id))
        store.requestProfileRemoval(for: app, profile: profile, dataRemoval: .keep)
        await store.confirmDestructiveActionAsync()
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.applications.first?.profiles.count, 1)
        XCTAssertNil(store.selectedProfileID)
        XCTAssertFalse(store.isProfileDataOperationRunning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.request.source.profileRoot.url.path))
    }

    @MainActor
    func testRemovingUnselectedProfilePreservesSelection() throws {
        let f = try fixture()
        let store = store(f)
        let profile = try XCTUnwrap(f.application.profiles.first)
        var app = f.application
        let other = LaunchProfile(name: "Selected")
        app.profiles.append(LaunchProfile(name: "Unselected"))
        app.profiles.append(other)
        XCTAssertTrue(store.commit([app], selectedApplicationID: app.id, selectedProfileID: other.id))
        XCTAssertTrue(store.remove(profile: profile, dataRemoval: .keep))
        XCTAssertEqual(store.selectedProfileID, other.id)
        store.selectedProfileID = nil
        XCTAssertTrue(store.remove(profile: other, dataRemoval: .keep))
        XCTAssertNil(store.selectedProfileID)
    }

    @MainActor
    func testFailedDuplicateRestoresNilSelection() async throws {
        let f = try fixture { boundary in
            if boundary == .beforeEffect(.commitMetadata) { throw CocoaError(.fileWriteOutOfSpace) }
        }
        try sourceData(f)
        let store = store(f)
        store.selectedApplicationID = nil
        store.selectedProfileID = nil
        store.requestProfileDuplication(for: f.application, profile: try XCTUnwrap(f.application.profiles.first))
        await store.confirmDestructiveActionAsync()
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertNil(store.selectedProfileID)
        XCTAssertTrue(try f.coordinator.pendingTransactions().isEmpty)
    }

    @MainActor
    func testKeychainOnlyDraftBlocksDestructiveAction() throws {
        let f = try fixture()
        let store = store(f)
        let profile = try XCTUnwrap(f.application.profiles.first)
        for staged in [true, false] {
            store.rememberProfileEditingDraft(applicationID: f.application.id, draft: profile, baseline: profile,
                baselineVersion: f.prepared.priorVersion,
                stagedKeychainReferences: staged ? [EnvironmentSecretReference()] : [],
                pendingKeychainDeletionReferences: staged ? [] : [EnvironmentSecretReference()])
            XCTAssertFalse(store.requireCommittedProfileDraft(application: f.application, profile: profile))
        }
    }

    @MainActor
    func testRemoveEntryAnywayRechecksActivity() throws {
        let f = try fixture()
        let store = store(f)
        let profile = try XCTUnwrap(f.application.profiles.first)
        store.prepareRemoveEntryAnywayRecovery(application: f.application, profile: profile)
        let recovery = try XCTUnwrap(store.pendingProfileRemovalRecovery)
        let lease = try store.profileActivityRegistry.acquire(identity: .init(applicationID: f.application.id,
            applicationStorageID: f.application.storageID, profileID: profile.id, profileStorageID: profile.storageID), requestID: UUID())
        defer { lease.release() }
        XCTAssertFalse(store.removeEntryAnyway(recovery))
        XCTAssertEqual(store.applications, [f.application])
    }

    @MainActor
    func testRemoveEntryAnywayPreservesSelectionInAnotherApplication() throws {
        let f = try fixture()
        let store = store(f)
        let profile = try XCTUnwrap(f.application.profiles.first)
        let selected = LaunchProfile(name: "Selected")
        let other = ManagedApplication(displayName: "Other", appPath: f.root.appendingPathComponent("Other.app").path,
                                       baseStoragePath: f.root.path, profiles: [selected])
        XCTAssertTrue(store.commit([f.application, other], selectedApplicationID: other.id, selectedProfileID: selected.id))
        store.prepareRemoveEntryAnywayRecovery(application: f.application, profile: profile)
        let recovery = try XCTUnwrap(store.pendingProfileRemovalRecovery)
        XCTAssertTrue(store.removeEntryAnyway(recovery))
        XCTAssertEqual(store.selectedApplicationID, other.id)
        XCTAssertEqual(store.selectedProfileID, selected.id)
    }

    @MainActor
    func testMissingDataRemovalReportsNoManagedDataAndExternalConfiguration() throws {
        let f = try fixture(.delete)
        let store = store(f)
        var app = f.application
        app.profiles[0].environmentText = "CODEX_HOME=/synthetic/external"
        app.profiles[0].isolationOwnership.codexHome = .explicit
        XCTAssertTrue(store.commit([app], selectedApplicationID: app.id, selectedProfileID: app.profiles[0].id))
        XCTAssertTrue(store.remove(profile: app.profiles[0], dataRemoval: .delete), store.errorMessage ?? "")
        XCTAssertEqual(store.launchStatusMessage, String(localized: "Removed \(app.profiles[0].name). No managed data existed."))
        let receipts = try FileManager.default.contentsOfDirectory(at: f.coordinator.controlRootURL,
            includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix(".receipt.json") }
        let receipt = try f.coordinator.decoder.decode(ProfileDataTransactionCoordinator.Receipt.self,
            from: Data(contentsOf: try XCTUnwrap(receipts.first)))
        XCTAssertEqual(receipt.externalDataHandling, .configurationOnly(configuredPaths: ["CODEX_HOME"]))
    }

    @MainActor
    func testClearReservesStorageUntilCleanupAndReleasesIt() throws {
        let f = try fixture()
        try sourceData(f)
        let registry = try ProfileActivityRegistry(applicationSupportURL: f.root, refreshScheduler: SupervisorTestScheduler())
        let peer = try ProfileActivityRegistry(applicationSupportURL: f.root, refreshScheduler: SupervisorTestScheduler())
        let identity = ProfileActivityIdentity(applicationID: f.application.id, applicationStorageID: f.application.storageID,
            profileID: f.request.identity.sourceProfileID, profileStorageID: f.request.identity.sourceProfileStorageID)
        let coordinator = try ProfileDataTransactionCoordinator(applicationSupportURL: f.root, transactionBoundary: { boundary in
            if boundary == .beforeEffect(.moveToStaging) || boundary == .beforeEffect(.removeStaging) {
                XCTAssertTrue(registry.isStorageReserved(applicationStorageID: identity.applicationStorageID,
                                                       profileStorageID: identity.profileStorageID))
                do {
                    let launch = try peer.acquireLaunchLease(identity: identity, requestID: UUID())
                    launch.release()
                    XCTFail("Launch admission must refuse reserved data")
                } catch { }
            }
        })
        let store = LibraryStore(repository: f.repository, profileDataTransactions: coordinator,
            profileActivityRegistry: registry, launcher: AuditNoopLauncher(), secretStore: AuditSecretStore(), settings: AppSettings())
        XCTAssertTrue(store.clearProfileData(for: f.application, profile: try XCTUnwrap(f.application.profiles.first)), store.errorMessage ?? "")
        XCTAssertFalse(registry.isStorageReserved(applicationStorageID: identity.applicationStorageID,
                                                profileStorageID: identity.profileStorageID))
    }

    @MainActor
    func testRemovalFailureDoesNotRecoverAnotherTransaction() throws {
        let f = try fixture()
        let store = store(f)
        let profile = try XCTUnwrap(f.application.profiles.first)
        store.selectedApplicationID = f.application.id
        store.selectedProfileID = profile.id
        let log = try f.coordinator.preparePlan(request: f.request, preparedCommit: f.prepared)
        try f.coordinator.publishPlan(log)
        // Another writer advances the library after this window's snapshot.
        _ = try f.repository.save([f.application], expectedVersion: f.prepared.priorVersion)
        XCTAssertFalse(store.remove(profile: profile, dataRemoval: .delete))
        XCTAssertEqual(try f.coordinator.pendingTransactions().map(\.transactionID), [f.request.transactionID])
    }

    @MainActor
    func testMissingSecretTargetReportsError() async throws {
        let f = try fixture()
        let store = store(f)
        let result = await store.storeKeychainSecret("synthetic", environmentKey: "TOKEN", for: LaunchProfile(name: "Gone"))
        XCTAssertFalse(result)
        XCTAssertNotNil(store.errorMessage)
    }
}
