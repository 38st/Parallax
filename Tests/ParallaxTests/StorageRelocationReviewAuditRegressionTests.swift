import Foundation
import XCTest
@testable import Parallax

final class StorageRelocationReviewAuditRegressionTests: XCTestCase {
    func testParseErrorsProduceNamedPreviewBlockers() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        var app = f.application
        app.profiles[0].argumentsText = "'unfinished"
        let preview = try f.preview(application: app)
        XCTAssertEqual(preview.blockers.count, 1)
        guard case let .profileConfiguration(appName, profileName, problem) = preview.blockers.first else { return XCTFail("Expected a profile configuration blocker") }
        XCTAssertEqual(appName, "Synthetic")
        XCTAssertEqual(profileName, "Synthetic")
        XCTAssertFalse(problem.isEmpty)
    }

    func testInvalidExplicitPathsProduceProfileBlockers() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        for value in ["rel", try f.preview().source.applicationRoot.url.appendingPathComponent("data").path] {
            var app = f.application
            app.profiles[0].environmentText = "CODEX_HOME=\(value)"
            let preview = try f.preview(application: app)
            XCTAssertEqual(preview.blockers.count, 1)
            guard case let .profileConfiguration(appName, profileName, problem) = preview.blockers.first else { return XCTFail("Expected a profile configuration blocker") }
            XCTAssertEqual(appName, "Synthetic")
            XCTAssertEqual(profileName, "Synthetic")
            XCTAssertFalse(problem.isEmpty)
        }
    }

    func testPriorRecoveryWithNoPublishedCopyPreservesChangedSource() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        let data = preview.source.applicationRoot.url.appendingPathComponent("data")
        try Data("changed".utf8).write(to: data)
        XCTAssertEqual(try f.recover(preview), .rolledBack)
        XCTAssertEqual(try Data(contentsOf: data), Data("changed".utf8))
    }

    func testPersistentSourceCleanupFailureFinishesCommittedRecovery() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try f.publishCopy(preview)
        _ = try f.repository.save([preview.relocatedApplication], expectedVersion: f.version)
        let coordinator = try coordinator(f) { boundary in
            if case .beforeSourceCleanup = boundary { throw ReviewFailure.injected }
        }
        let result = try f.repository.tryWithExclusiveAccess { access in
            try coordinator.recover(transactionID: preview.requestID, repository: f.repository, access: access)
        }
        guard case .acquired(.committed) = result else { return XCTFail("Expected completion") }
        XCTAssertTrue(f.exists(preview.source.applicationRoot.url))
        XCTAssertTrue(try coordinator.pendingRelocations().isEmpty)
    }

    func testRollbackPreservesDestinationWhenSourceChanged() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        let coordinator = try coordinator(f) { boundary in
            if case .afterStaging = boundary {
                try Data("changed".utf8).write(to: preview.source.applicationRoot.url.appendingPathComponent("data"))
            }
        }
        XCTAssertThrowsError(try coordinator.execute(preview, preparedCommit: f.prepared(preview), repository: f.repository))
        XCTAssertTrue(f.exists(preview.destination.applicationRoot.url))
        XCTAssertEqual(try coordinator.pendingRelocations().map(\.transactionID), [preview.requestID])
    }

    func testRecoveryReservationConflictIsRetryable() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        let lease = try f.registry.acquireDataOperationLease(identities: f.coordinator.activityIdentities(f.application))
        defer { lease.release() }
        XCTAssertThrowsError(try f.recover(preview)) { error in
            XCTAssertTrue(error is LibraryOperationInProgressError, "\(error)")
        }
        XCTAssertEqual(try f.coordinator.pendingRelocations().map(\.transactionID), [preview.requestID])
    }

    func testRecoverySweepsAbandonedPendingFilesAndCompletedPairs() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        let temporary = try SecureManagedPath([".\(UUID().uuidString.lowercased()).pending"])
        try f.coordinator.control.write(Data("partial".utf8), to: temporary)
        _ = try f.repository.tryWithExclusiveAccess { access in
            try f.coordinator.recoverAll(repository: f.repository, access: access)
        }
        XCTAssertEqual(try f.coordinator.control.itemState(at: temporary), .missing)
        XCTAssertEqual(try f.coordinator.control.itemState(at: f.coordinator.controlPlanPath(preview.requestID)), .missing)
        XCTAssertEqual(try f.coordinator.control.itemState(at: f.coordinator.controlReceiptPath(preview.requestID)), .missing)
    }

    func testUnfinishedPlanRefusesAnotherExecutionForSameApplication() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let first = try f.preview()
        let second = try f.preview()
        try f.publishPlan(first)
        XCTAssertThrowsError(try f.coordinator.execute(second, preparedCommit: f.prepared(second), repository: f.repository)) {
            XCTAssertEqual(($0 as? StorageRelocationError)?.code, .unfinishedTransaction)
        }
        XCTAssertTrue(f.exists(first.source.applicationRoot.url))
        XCTAssertFalse(f.exists(second.destination.applicationRoot.url))
    }

    @MainActor
    func testPreparationImmediatelyPresentsCancellableStateAndRefusesSecondRequest() async throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let suite = "RelocationReview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(persistence: LibraryPersistence(applicationSupportURL: f.root), repository: f.repository,
            storageRelocationCoordinator: f.coordinator, profileActivityRegistry: f.registry,
            settings: AppSettings(userDefaults: defaults))
        store.prepareStorageRelocation(for: f.application, to: f.destination)
        let task = store.storageRelocationTask
        let preparing = store.storageRelocationPreview
        XCTAssertNotNil(preparing)
        store.prepareStorageRelocation(for: f.application, to: f.root.appendingPathComponent("Second"))
        XCTAssertNotNil(store.errorMessage)
        if let preparing { store.cancelStorageRelocation(preparing) }
        await task?.value
        XCTAssertNil(store.storageRelocationPreview)
    }

    private func coordinator(_ f: RelocationAuditFixture,
        boundary: @escaping @Sendable (StorageRelocationBoundary) throws -> Void) throws -> StorageRelocationCoordinator {
        try StorageRelocationCoordinator(applicationSupportURL: f.root, fileSystem: LocalFileSystem(),
            activityProvider: f.registry, availableCapacity: { _ in UInt64.max }, supportsPermissions: { _ in true },
            transactionBoundary: boundary)
    }
}

private enum ReviewFailure: Error { case injected }

extension StorageRelocationReviewAuditRegressionTests {
    func testDriveFlushCountDoesNotGrowWithFileCount() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let source = try f.preview().source.applicationRoot.url
        for index in 0..<100 { try Data("fixture".utf8).write(to: source.appendingPathComponent("file-\(index)")) }
        let calls = ReviewCounter()
        let coordinator = try StorageRelocationCoordinator(applicationSupportURL: f.root, fileSystem: LocalFileSystem(),
            activityProvider: f.registry, availableCapacity: { _ in UInt64.max }, supportsPermissions: { _ in true },
            synchronizeDescriptor: { _ in calls.increment() })
        let preview = try coordinator.prepare(application: f.application, destinationBaseRoot: f.destination.path, expectedVersion: f.version)
        _ = try coordinator.execute(preview, preparedCommit: f.prepared(preview), repository: f.repository)
        XCTAssertEqual(calls.value, 2, "One existing root and its publication directory")
    }

    func testCancellationStopsPreviewReadsImmediately() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let cancellation = StorageRelocationCancellation()
        let reads = ReviewCounter()
        var coordinator = try coordinator(f) { boundary in
            if case .beforePreviewRead = boundary {
                reads.increment()
                if reads.value == 3 { cancellation.cancel() }
            }
        }
        coordinator.preparationCancellation = cancellation
        XCTAssertThrowsError(try coordinator.prepare(application: f.application,
            destinationBaseRoot: f.destination.path, expectedVersion: f.version)) {
            XCTAssertEqual(($0 as? StorageRelocationError)?.code, .cancelled)
        }
        XCTAssertEqual(reads.value, 3)
        XCTAssertTrue(try coordinator.pendingRelocations().isEmpty)
    }

    func testOtherApplicationsReferencingMovedStorageAreNamedAndBlocked() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let path = try f.preview().source.applicationRoot.url.appendingPathComponent("Shared").path
        for field in ["arguments", "CODEX_HOME", "CLAUDE_CONFIG_DIR"] {
            let profile = LaunchProfile(name: "Dependent", argumentsText: field == "arguments" ? ShellWordsParser.quote("--user-data-dir=\(path)") : "",
                environmentText: field == "arguments" ? "" : "\(field)=\(path)", isolationOwnership: .explicit)
            let other = ManagedApplication(displayName: "Other", appPath: "/synthetic/Other.app", preset: .custom,
                baseStoragePath: f.root.appendingPathComponent("Other").path, profiles: [profile])
            let preview = try f.coordinator.prepare(application: f.application, destinationBaseRoot: f.destination.path,
                expectedVersion: f.version, applications: [f.application, other])
            XCTAssertEqual(preview.blockers, [.dependentProfile(applicationName: "Other", profileName: "Dependent", path: try f.coordinator.pathResolver.resolveExternalPath(path).canonicalURL.path)])
        }
    }

    func testLeftoverNoticeSurvivesPruningAndNamesTheSource() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try f.publishCopy(preview)
        _ = try f.repository.save([preview.relocatedApplication], expectedVersion: f.version)
        try Data("extra".utf8).write(to: preview.source.applicationRoot.url.appendingPathComponent("extra"))
        guard case .committed(let outcome) = try f.recover(preview) else { return XCTFail("Expected committed recovery") }
        XCTAssertEqual(outcome.leftoverSourcePaths, [preview.source.applicationRoot.url.path])
        _ = try f.repository.tryWithExclusiveAccess { access in
            try f.coordinator.maintainControlState(repository: f.repository, access: access)
        }
        XCTAssertEqual(try f.coordinator.recordedLeftoverSourcePaths(), outcome.leftoverSourcePaths)
        XCTAssertEqual(try f.coordinator.control.itemState(at: f.coordinator.controlPlanPath(preview.requestID)), .missing)
        XCTAssertTrue(f.exists(preview.source.applicationRoot.url))
    }

    func testInterruptedPruningConvergesFromEitherRemainingControlFile() throws {
        for removedSuffix in ["plan", "receipt"] {
            let f = try RelocationAuditFixture()
            defer { f.remove() }
            let preview = try f.preview()
            try f.publishPlan(preview)
            _ = try f.recover(preview)
            let plan = try f.coordinator.loadControlPlan(preview.requestID)
            let receipt = try XCTUnwrap(f.coordinator.loadControlReceiptIfPresent(plan: plan))
            let marker = try f.coordinator.privateControlPath(preview.requestID, suffix: ".retired")
            try f.coordinator.control.write(f.coordinator.canonicalBytes(receipt), to: marker)
            let removed = try removedSuffix == "plan" ? f.coordinator.controlPlanPath(preview.requestID) : f.coordinator.controlReceiptPath(preview.requestID)
            try f.coordinator.control.removeTree(at: removed)
            XCTAssertTrue(try f.coordinator.pendingRelocations().isEmpty)
            _ = try f.repository.tryWithExclusiveAccess { access in
                try f.coordinator.maintainControlState(repository: f.repository, access: access)
            }
            XCTAssertEqual(try f.coordinator.control.itemState(at: marker), .missing)
            XCTAssertTrue(try f.coordinator.pendingRelocations().isEmpty)
        }
    }

    func testLegacyPlanReaderHasFinite256MiBCap() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let id = UUID()
        let url = f.coordinator.controlURL(for: try f.coordinator.controlPlanPath(id))
        XCTAssertEqual(StorageRelocationCoordinator.maximumLegacyControlBytes, 256 * 1_024 * 1_024)
        try Data().write(to: url)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.truncate(atOffset: UInt64(StorageRelocationCoordinator.maximumLegacyControlBytes + 1))
        XCTAssertThrowsError(try f.coordinator.loadControlPlan(id)) {
            XCTAssertEqual(($0 as? StorageRelocationError)?.code, .invalidJournal)
        }
    }

    func testRegistryBackedRecoveryAfterOwnerCrash() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let inspector = ReviewProcessInspector()
        let oldRegistry = try ProfileActivityRegistry(applicationSupportURL: f.root, refreshScheduler: SupervisorTestScheduler(), processInspector: inspector)
        let lease = try oldRegistry.acquireDataOperationLease(identities: f.coordinator.activityIdentities(f.application))
        defer { lease.release() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        inspector.replaceOwner()
        let restarted = try ProfileActivityRegistry(applicationSupportURL: f.root, refreshScheduler: SupervisorTestScheduler(), processInspector: inspector)
        let report = try restarted.reconcileDurableActivity()
        XCTAssertEqual(report.removedDeadCount, 1)
        let coordinator = try StorageRelocationCoordinator(applicationSupportURL: f.root, fileSystem: LocalFileSystem(),
            activityProvider: restarted, availableCapacity: { _ in UInt64.max }, supportsPermissions: { _ in true })
        let result = try f.repository.tryWithExclusiveAccess { access in
            try coordinator.recover(transactionID: preview.requestID, repository: f.repository, access: access)
        }
        guard case .acquired(.rolledBack) = result else { return XCTFail("Expected rollback after proven owner exit") }
        XCTAssertTrue(try coordinator.pendingRelocations().isEmpty)
    }

    func testManifestChecksAcceptCanonicalNamesAndEntryOrder() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let identity = StorageRelocationItemIdentity(volumeID: 1, fileID: 1, kind: "directory")
        let nfc = StorageRelocationManifestEntry(relativeComponents: ["caf\u{e9}"], kind: "regularFile", byteCount: 1, permissions: 0o600, sha256: "digest")
        let nfd = StorageRelocationManifestEntry(relativeComponents: ["cafe\u{301}"], kind: "regularFile", byteCount: 1, permissions: 0o600, sha256: "digest")
        let root = StorageRelocationManifestEntry(relativeComponents: [], kind: "directory", byteCount: 0, permissions: 0o700, sha256: nil)
        XCTAssertTrue(try f.coordinator.snapshotMatches(.init(identity: identity, manifest: [root, nfd]),
            expected: .init(identity: identity, manifest: [nfc, root])))
        XCTAssertTrue(f.coordinator.manifestIsSubset([nfd], of: [root, nfc]))
    }
}

private final class ReviewCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class ReviewProcessInspector: ProcessIdentityInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 100
    func replaceOwner() { lock.withLock { generation = 200 } }
    func inspect(processIdentifier: pid_t) -> ProcessIdentityInspection {
        lock.withLock {
            .live(ProcessStartIdentity(processIdentifier: processIdentifier, startTimeSeconds: generation, startTimeMicroseconds: 1))
        }
    }
}

extension StorageRelocationReviewAuditRegressionTests {
    func testTargetRecoveryRejectsDestinationChangedBeforeSourceRemoval() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try f.publishCopy(preview)
        _ = try f.repository.save([preview.relocatedApplication], expectedVersion: f.version)
        let coordinator = try coordinator(f) { boundary in
            if case .beforeSourceCleanup = boundary {
                try Data("changed destination".utf8).write(to: preview.destination.applicationRoot.url.appendingPathComponent("data"))
            }
        }
        XCTAssertThrowsError(try f.repository.tryWithExclusiveAccess { access in
            try coordinator.recover(transactionID: preview.requestID, repository: f.repository, access: access)
        })
        XCTAssertTrue(f.exists(preview.source.applicationRoot.url))
        XCTAssertEqual(try coordinator.pendingRelocations().map(\.transactionID), [preview.requestID])
    }

    func testCopyManifestFailureHasClearErrorAndPreservesSource() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        let fs = MigrationOccurrenceFailingFileSystem()
        fs.beforeOperation = { event in
            if event.operation == .copyItem { throw SecureManagedFileSystemError.manifestMismatch }
        }
        let coordinator = try StorageRelocationCoordinator(applicationSupportURL: f.root, fileSystem: fs,
            activityProvider: f.registry, availableCapacity: { _ in UInt64.max }, supportsPermissions: { _ in true })
        XCTAssertThrowsError(try coordinator.execute(preview, preparedCommit: f.prepared(preview), repository: f.repository)) {
            XCTAssertEqual(($0 as? StorageRelocationError)?.code, .copyVerificationFailed)
        }
        XCTAssertTrue(f.exists(preview.source.applicationRoot.url))
        XCTAssertFalse(f.exists(preview.destination.applicationRoot.url))
    }

    func testSupersededLocalizationKeysAreAbsent() throws {
        for language in ["en", "es"] {
            let url = try XCTUnwrap(PackagedRuntimeResources.bundle.url(forResource: language, withExtension: "lproj"))
            let bundle = try XCTUnwrap(Bundle(url: url))
            for key in ["%@ are active. Quit them before moving storage.",
                "Explicit external CODEX_HOME and user-data locations are not moved or rewritten.",
                "The selected application conflicts with existing record(s): %@. No application was changed."] {
                XCTAssertEqual(bundle.localizedString(forKey: key, value: "missing", table: "Localizable"), "missing")
            }
        }
    }

    @MainActor
    func testCommittedFailureReportsLeftoverSourceInsteadOfUnqualifiedSuccess() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let suite = "RelocationReviewNotice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = try coordinator(f) { boundary in
            if case .beforeSourceCleanup = boundary { throw ReviewFailure.injected }
        }
        let store = LibraryStore(persistence: LibraryPersistence(applicationSupportURL: f.root), repository: f.repository,
            storageRelocationCoordinator: coordinator, profileActivityRegistry: f.registry,
            settings: AppSettings(userDefaults: defaults))
        let preview = try f.preview()
        store.storageRelocationPreview = preview
        XCTAssertTrue(store.confirmStorageRelocation(preview))
        XCTAssertTrue(try XCTUnwrap(store.launchStatusMessage).contains(preview.source.applicationRoot.url.path))
        XCTAssertTrue(f.exists(preview.source.applicationRoot.url))
    }
}

extension StorageRelocationReviewAuditRegressionTests {
    func testPruningRejectsDamagedReceiptEvenAfterPlanWasRemoved() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        _ = try f.recover(preview)
        let plan = try f.coordinator.loadControlPlan(preview.requestID)
        let receipt = try XCTUnwrap(f.coordinator.loadControlReceiptIfPresent(plan: plan))
        let marker = try f.coordinator.privateControlPath(preview.requestID, suffix: ".retired")
        try f.coordinator.control.write(f.coordinator.canonicalBytes(receipt), to: marker)
        try f.coordinator.control.removeTree(at: f.coordinator.controlPlanPath(preview.requestID))
        let receiptPath = try f.coordinator.controlReceiptPath(preview.requestID)
        try Data("damaged".utf8).write(to: f.coordinator.controlURL(for: receiptPath))
        XCTAssertThrowsError(try f.repository.tryWithExclusiveAccess { access in
            try f.coordinator.maintainControlState(repository: f.repository, access: access)
        })
        XCTAssertNotEqual(try f.coordinator.control.itemState(at: receiptPath), .missing)
        XCTAssertNotEqual(try f.coordinator.control.itemState(at: marker), .missing)
    }

    @MainActor
    func testStoreIncludesOtherApplicationsWhenPreparingPreview() async throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let path = try f.preview().source.applicationRoot.url.appendingPathComponent("Shared").path
        let other = ManagedApplication(displayName: "Other", appPath: "/synthetic/Other.app", preset: .custom,
            baseStoragePath: f.root.appendingPathComponent("Other").path,
            profiles: [LaunchProfile(name: "Dependent", environmentText: "CLAUDE_CONFIG_DIR=\(path)", isolationOwnership: .explicit)])
        _ = try f.repository.save([f.application, other], expectedVersion: f.version)
        let suite = "RelocationReviewReferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LibraryStore(persistence: LibraryPersistence(applicationSupportURL: f.root), repository: f.repository,
            storageRelocationCoordinator: f.coordinator, profileActivityRegistry: f.registry,
            settings: AppSettings(userDefaults: defaults))
        store.prepareStorageRelocation(for: f.application, to: f.destination)
        await store.storageRelocationTask?.value
        XCTAssertEqual(try XCTUnwrap(store.storageRelocationPreview).blockers,
            [.dependentProfile(applicationName: "Other", profileName: "Dependent",
                path: try f.coordinator.pathResolver.resolveExternalPath(path).canonicalURL.path)])
    }
}

extension StorageRelocationReviewAuditRegressionTests {
    func testPruningKeepsCompletionProofUntilBothRemovalsAreDurable() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        _ = try f.recover(preview)
        let coordinator = try coordinator(f) { boundary in
            if case .beforeRetirementMarkerRemoval(let id) = boundary {
                XCTAssertEqual(try f.coordinator.control.itemState(at: f.coordinator.controlPlanPath(id)), .missing)
                XCTAssertEqual(try f.coordinator.control.itemState(at: f.coordinator.controlReceiptPath(id)), .missing)
                throw ReviewFailure.injected
            }
        }
        XCTAssertThrowsError(try f.repository.tryWithExclusiveAccess { access in
            try coordinator.maintainControlState(repository: f.repository, access: access)
        })
        let marker = try coordinator.privateControlPath(preview.requestID, suffix: ".retired")
        XCTAssertNotEqual(try coordinator.control.itemState(at: marker), .missing)
        XCTAssertTrue(try coordinator.pendingRelocations().isEmpty)
        _ = try f.repository.tryWithExclusiveAccess { access in
            try f.coordinator.maintainControlState(repository: f.repository, access: access)
        }
        XCTAssertEqual(try coordinator.control.itemState(at: marker), .missing)
    }
}
