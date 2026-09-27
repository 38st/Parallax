import Darwin
import Foundation
import XCTest
@testable import Parallax

final class StorageRelocationAuditRegressionTests: XCTestCase {
    func testLargeManifestPlanRemainsBoundedAndDiscoverable() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let original = try fixture.preview()
        let snapshot = try XCTUnwrap(original.sourceApplicationSnapshot)
        let entries = (0..<20_000).map { index in
            StorageRelocationManifestEntry(
                relativeComponents: [String(repeating: "long-directory-", count: 8), "file-\(index)"],
                kind: "regularFile", byteCount: 1, permissions: 0o600,
                sha256: String(repeating: "a", count: 64))
        }
        let preview = StorageRelocationPreview(
            requestID: original.requestID, applicationID: original.applicationID,
            applicationStorageID: original.applicationStorageID, expectedVersion: original.expectedVersion,
            originalApplication: original.originalApplication, relocatedApplication: original.relocatedApplication,
            source: original.source, destination: original.destination, sourceEstimate: original.sourceEstimate,
            sourceApplicationFingerprint: original.sourceApplicationFingerprint,
            sourceArchiveFingerprint: original.sourceArchiveFingerprint,
            sourceApplicationSnapshot: StorageRelocationOwnedTreeSnapshot(identity: snapshot.identity, manifest: entries),
            sourceArchiveSnapshot: original.sourceArchiveSnapshot,
            destinationAvailableBytes: original.destinationAvailableBytes, strategy: original.strategy,
            generatedRewrites: original.generatedRewrites, preservedExternalPaths: original.preservedExternalPaths,
            blockers: original.blockers)
        let plan = try fixture.coordinator.makeControlPlan(preview: preview, preparedCommit: fixture.prepared(preview))
        XCTAssertLessThan(try fixture.coordinator.canonicalBytes(plan).count, 4 * 1_024 * 1_024)
        try fixture.coordinator.writeControlPlan(plan)
        XCTAssertEqual(try fixture.coordinator.pendingRelocations().map(\.transactionID), [preview.requestID])
    }

    func testRejectedPlanReadbackDoesNotLeavePendingJournal() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        let plan = try fixture.coordinator.makeControlPlan(preview: preview, preparedCommit: fixture.prepared(preview))
        let invalid = StorageRelocationControlPlan(unsigned: plan.unsigned, planSHA256: "invalid")
        XCTAssertThrowsError(try fixture.coordinator.writeControlPlan(invalid))
        XCTAssertTrue(try fixture.coordinator.pendingRelocations().isEmpty)
    }

    func testReceiptBeforeCommitPreservesSourceAndPriorLibrary() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        let prepared = try fixture.prepared(preview)
        XCTAssertThrowsError(try fixture.coordinator.execute(preview, preparedCommit: prepared, repository: fixture.repository) { phase in
            if phase == .committingMetadata {
                do {
                    let plan = try fixture.coordinator.loadControlPlan(preview.requestID)
                    try fixture.coordinator.writeControlReceipt(plan: plan, completion: .rolledBack)
                } catch { XCTFail("Could not inject receipt: \(error)") }
            }
        })
        XCTAssertTrue(fixture.exists(preview.source.applicationRoot.url))
        guard case .loaded(let loaded) = fixture.repository.load() else { return XCTFail("Missing library") }
        XCTAssertEqual(loaded.versionToken, fixture.version)
    }

    func testReceiptBeforeSourceCleanupPreservesSource() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        XCTAssertThrowsError(try fixture.coordinator.execute(preview, preparedCommit: fixture.prepared(preview), repository: fixture.repository) { phase in
            if phase == .cleaningSource {
                do {
                    let plan = try fixture.coordinator.loadControlPlan(preview.requestID)
                    try fixture.coordinator.writeControlReceipt(plan: plan, completion: .rolledBack)
                } catch { XCTFail("Could not inject receipt: \(error)") }
            }
        })
        XCTAssertTrue(fixture.exists(preview.source.applicationRoot.url))
    }

    func testDestinationChangeBeforeCommitPreservesSourceAndPriorLibrary() throws {
        try assertDestinationTamperPreservesSource(phase: .committingMetadata, expectCommitted: false)
    }

    func testDestinationChangeBeforeSourceCleanupPreservesSource() throws {
        try assertDestinationTamperPreservesSource(phase: .cleaningSource, expectCommitted: true)
    }

    private func assertDestinationTamperPreservesSource(phase: StorageRelocationProgress, expectCommitted: Bool) throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        let prepared = try fixture.prepared(preview)
        XCTAssertThrowsError(try fixture.coordinator.execute(preview, preparedCommit: prepared, repository: fixture.repository) { progress in
            if phase == progress {
                do { try Data("tampered".utf8).write(to: preview.destination.applicationRoot.url.appendingPathComponent("data")) }
                catch { XCTFail("Could not inject change: \(error)") }
            }
        })
        XCTAssertTrue(fixture.exists(preview.source.applicationRoot.url))
        guard case .loaded(let loaded) = fixture.repository.load() else { return XCTFail("Missing library") }
        XCTAssertEqual(loaded.versionToken, expectCommitted ? prepared.targetVersion : fixture.version)
    }

    func testPriorRecoveryRemovesPartialTransactionStaging() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        try fixture.publishPlan(preview)
        let staging = preview.destination.stagingRoot(transactionID: preview.requestID)
        let partial = staging.url.appendingPathComponent("Application")
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try Data("partial bytes".utf8).write(to: partial.appendingPathComponent("data"))
        XCTAssertEqual(try fixture.recover(preview), .rolledBack)
        XCTAssertFalse(fixture.exists(staging.url))
        XCTAssertTrue(try fixture.coordinator.pendingRelocations().isEmpty)
    }

    func testPriorRecoveryFinishesPartialPublishedDelete() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        try fixture.publishPlan(preview)
        try fixture.publishCopy(preview)
        try FileManager.default.removeItem(at: preview.destination.applicationRoot.url.appendingPathComponent("data"))
        XCTAssertEqual(try fixture.recover(preview), .rolledBack)
        XCTAssertFalse(fixture.exists(preview.destination.applicationRoot.url))
    }

    func testTargetRecoveryFinishesPartialSourceDelete() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        try fixture.publishPlan(preview)
        try fixture.publishCopy(preview)
        _ = try fixture.repository.save([preview.relocatedApplication], expectedVersion: fixture.version)
        try FileManager.default.removeItem(at: preview.source.applicationRoot.url.appendingPathComponent("data"))
        guard case .committed = try fixture.recover(preview) else { return XCTFail("Expected commit") }
        XCTAssertFalse(fixture.exists(preview.source.applicationRoot.url))
    }

    func testTargetRecoveryPreservesChangedSourceWithoutLockout() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        try fixture.publishPlan(preview)
        try fixture.publishCopy(preview)
        _ = try fixture.repository.save([preview.relocatedApplication], expectedVersion: fixture.version)
        try Data("Finder metadata".utf8).write(to: preview.source.applicationRoot.url.appendingPathComponent(".DS_Store"))
        guard case .committed = try fixture.recover(preview) else { return XCTFail("Expected commit") }
        XCTAssertTrue(fixture.exists(preview.source.applicationRoot.url.appendingPathComponent(".DS_Store")))
        XCTAssertTrue(try fixture.coordinator.pendingRelocations().isEmpty)
    }

    func testTargetRecoveryAllowsMissingSourceBase() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        try fixture.publishPlan(preview)
        try fixture.publishCopy(preview)
        _ = try fixture.repository.save([preview.relocatedApplication], expectedVersion: fixture.version)
        try FileManager.default.removeItem(at: fixture.source)
        guard case .committed = try fixture.recover(preview) else { return XCTFail("Expected commit") }
        XCTAssertTrue(try fixture.coordinator.pendingRelocations().isEmpty)
    }

    func testPreviewAllowsMissingSourceBase() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.source)
        let preview = try fixture.preview()
        XCTAssertNil(preview.sourceApplicationSnapshot)
        XCTAssertEqual(preview.sourceEstimate, .zero)
    }

    func testExplicitManagedUserDataIsBlockedInsteadOfPreservedAsExternal() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        var application = fixture.application
        application.profiles[0].isolationOwnership.userData = .explicit
        let preview = try fixture.preview(application: application)
        XCTAssertTrue(preview.blockers.contains(.configuredPathInsideManagedStorage))
        XCTAssertTrue(preview.preservedExternalPaths.isEmpty)
    }

    func testLegacySplitUserDataIsRewritten() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        var application = fixture.application
        let path = try XCTUnwrap(fixture.coordinator.userDataValue(in: application.profiles[0]))
        application.profiles[0].argumentsText = "--user-data-dir " + ShellWordsParser.quote(path)
        application.profiles[0].isolationOwnership.userData = .legacyUnknown
        let preview = try fixture.preview(application: application)
        XCTAssertEqual(preview.generatedRewrites.map(\.field), [.userData])
        XCTAssertFalse(preview.relocatedApplication.profiles[0].argumentsText.contains(path))
    }

    func testManagedClaudeConfigIsBlockedInsteadOfPreserved() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        var application = fixture.application
        let source = try fixture.preview().source.applicationRoot.url
        application.profiles[0].environmentText = "CLAUDE_CONFIG_DIR=\(source.path)/ClaudeConfig"
        XCTAssertTrue(try fixture.preview(application: application).blockers.contains(.configuredPathInsideManagedStorage))
    }

    func testCRLFEnvironmentRewritePreservesOtherVariables() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let text = "CODEX_HOME=/old\r\nKEEP=one\r\nLAST=two"
        let updated = try fixture.coordinator.settingEnvironmentValue("CODEX_HOME", to: "/new", in: text)
        XCTAssertEqual(LaunchEnvironmentParser.parse(updated).effectiveValues, ["CODEX_HOME": "/new", "KEEP": "one", "LAST": "two"])
    }

    func testDestinationCannotNestInsideAnotherApplicationNamespace() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let nested = fixture.destination.appendingPathComponent(".parallax/Applications/\(UUID().uuidString.lowercased())/Profiles")
        let preview = try fixture.coordinator.prepare(application: fixture.application, destinationBaseRoot: nested.path, expectedVersion: fixture.version)
        XCTAssertTrue(preview.blockers.contains(.overlappingStorageLocations))
    }

    func testExecutionReservesProfilesUntilCleanupCompletes() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        let profile = try XCTUnwrap(fixture.application.profiles.first)
        let identity = ProfileActivityIdentity(applicationID: fixture.application.id, applicationStorageID: fixture.application.storageID,
            profileID: profile.id, profileStorageID: profile.storageID)
        _ = try fixture.coordinator.execute(preview, preparedCommit: fixture.prepared(preview), repository: fixture.repository) { progress in
            guard progress == .stagingApplication || progress == .cleaningSource else { return }
            do {
                let lease = try fixture.registry.acquireLaunchLease(identity: identity, requestID: UUID(),
                    concurrentLaunchPolicy: .expertOverride(.init(acknowledgesProfileDataCorruptionRisk: true)))
                lease.release()
                XCTFail("Relocation must reserve every affected profile")
            } catch {
                guard case ProfileActivityRegistryError.storageReservedForDataOperation = error else {
                    return XCTFail("Unexpected admission error: \(error)")
                }
            }
        }
        XCTAssertFalse(fixture.registry.isActive(identity: identity))
    }
}

struct RelocationAuditFixture: Sendable {
    let root: URL
    let source: URL
    let destination: URL
    let application: ManagedApplication
    let repository: LibraryRepository
    let coordinator: StorageRelocationCoordinator
    let registry: ProfileActivityRegistry
    let version: LibraryVersionToken

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RelocationAudit-\(UUID().uuidString)", isDirectory: true)
        source = root.appendingPathComponent("Source", isDirectory: true)
        destination = root.appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem())
        let applicationStorageID = UUID()
        let profileStorageID = UUID()
        let paths = try resolver.resolve(configuredBaseRoot: source.path, applicationStorageID: applicationStorageID, profileStorageID: profileStorageID)
        let profile = LaunchProfile(storageID: profileStorageID, name: "Synthetic",
            argumentsText: ShellWordsParser.quote("--user-data-dir=\(paths.userData.url.path)"),
            isolationOwnership: ProfileIsolationOwnership(userData: .generated, codexHome: .explicit))
        application = ManagedApplication(storageID: applicationStorageID, displayName: "Synthetic", appPath: "/synthetic/Browser.app",
            preset: .chromium, baseStoragePath: source.path, profiles: [profile])
        let applicationPaths = try resolver.resolveApplication(configuredBaseRoot: source.path, applicationStorageID: applicationStorageID)
        try FileManager.default.createDirectory(at: applicationPaths.applicationRoot.url, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: applicationPaths.applicationRoot.url.appendingPathComponent("data"))
        repository = LibraryRepository(applicationSupportURL: root, backupHook: { _, _ in })
        version = try repository.save([application], expectedVersion: .missing).versionToken
        registry = ProfileActivityRegistry()
        coordinator = try StorageRelocationCoordinator(applicationSupportURL: root, fileSystem: LocalFileSystem(),
            activityProvider: registry, availableCapacity: { _ in UInt64.max }, supportsPermissions: { _ in true },
            now: { Date(timeIntervalSinceReferenceDate: 812_345_678.1234567) })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func preview(application: ManagedApplication? = nil) throws -> StorageRelocationPreview {
        try coordinator.prepare(application: application ?? self.application, destinationBaseRoot: destination.path, expectedVersion: version)
    }
    func prepared(_ preview: StorageRelocationPreview) throws -> PreparedLibraryCommit {
        try repository.prepare([preview.relocatedApplication], expectedVersion: version)
    }
    func publishPlan(_ preview: StorageRelocationPreview) throws {
        let plan = try coordinator.makeControlPlan(preview: preview, preparedCommit: prepared(preview))
        try coordinator.writeControlPlan(plan)
    }
    func publishCopy(_ preview: StorageRelocationPreview) throws {
        try FileManager.default.createDirectory(at: preview.destination.applicationRoot.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: preview.source.applicationRoot.url, to: preview.destination.applicationRoot.url)
    }
    func recover(_ preview: StorageRelocationPreview) throws -> StorageRelocationRecoveryOutcome {
        switch try repository.tryWithExclusiveAccess({ access in
            try coordinator.recover(transactionID: preview.requestID, repository: repository, access: access)
        }) {
        case .acquired(let value): return value
        case .busy: throw StorageRelocationError(.rollbackRequired)
        }
    }
}

extension StorageRelocationAuditRegressionTests {
    func testCanonicallyEquivalentNamesHaveTheSameFingerprint() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let copy = fixture.root.appendingPathComponent("Unicode")
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try writeRawNamedFile(parent: copy, name: "cafe\u{301}")
        let original = fixture.root.appendingPathComponent("OriginalUnicode")
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        try writeRawNamedFile(parent: original, name: "caf\u{e9}")
        XCTAssertEqual(try fixture.coordinator.fingerprint(at: original), try fixture.coordinator.fingerprint(at: copy))
    }

    private func writeRawNamedFile(parent: URL, name: String) throws {
        let descriptor = open(parent.path + "/" + name, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { close(descriptor) }
        let bytes = Array("same".utf8)
        let count = bytes.withUnsafeBytes { buffer in
            Darwin.write(descriptor, buffer.baseAddress, buffer.count)
        }
        XCTAssertEqual(count, bytes.count)
    }

    func testStaleChromiumSymlinkHasActionablePreviewError() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let root = try fixture.preview().source.applicationRoot.url
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("SingletonLock").path, withDestinationPath: "old-host-123")
        XCTAssertThrowsError(try fixture.preview()) { error in
            XCTAssertEqual((error as? StorageRelocationError)?.code.rawValue, "unsafeSource")
        }
    }

    @MainActor
    func testSuccessKeepsMissingSelectionNil() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let store = try makeStore(fixture)
        store.selectedApplicationID = nil
        store.selectedProfileID = nil
        let preview = try fixture.preview()
        store.storageRelocationPreview = preview
        XCTAssertTrue(store.confirmStorageRelocation(preview))
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertNil(store.selectedProfileID)
    }

    @MainActor
    func testSuccessKeepsAnotherApplicationsSelection() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let profile = LaunchProfile(name: "Other", isolationOwnership: .explicit)
        let other = ManagedApplication(displayName: "Other", appPath: "/synthetic/Other.app", preset: .custom,
            baseStoragePath: fixture.root.appendingPathComponent("OtherStorage").path, profiles: [profile])
        let version = try fixture.repository.save([fixture.application, other], expectedVersion: fixture.version).versionToken
        let store = try makeStore(fixture)
        store.selectedApplicationID = other.id
        store.selectedProfileID = profile.id
        let preview = try fixture.coordinator.prepare(application: fixture.application,
            destinationBaseRoot: fixture.destination.path, expectedVersion: version)
        store.storageRelocationPreview = preview
        XCTAssertTrue(store.confirmStorageRelocation(preview))
        XCTAssertEqual(store.selectedApplicationID, other.id)
        XCTAssertEqual(store.selectedProfileID, profile.id)
    }

    @MainActor
    func testCancelledAttemptKeepsSelectionAndRequiresNewPreview() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let store = try makeStore(fixture)
        store.selectedApplicationID = nil
        store.selectedProfileID = nil
        let preview = try fixture.preview()
        store.storageRelocationPreview = preview
        store.finishFailedStorageRelocation(preview, code: .cancelled, operationMessage: "Synthetic cancellation",
            coordinator: fixture.coordinator, repository: fixture.repository)
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertNil(store.selectedProfileID)
        XCTAssertNil(store.storageRelocationPreview)
        XCTAssertNotEqual(try fixture.preview().requestID, preview.requestID)
    }

    @MainActor
    func testFailureKeepsSelectionAndInvalidatesPreview() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let store = try makeStore(fixture)
        store.selectedApplicationID = fixture.application.id
        store.selectedProfileID = nil
        let preview = try fixture.preview()
        store.storageRelocationPreview = preview
        try Data("changed".utf8).write(to: preview.source.applicationRoot.url.appendingPathComponent("data"))
        XCTAssertFalse(store.confirmStorageRelocation(preview))
        XCTAssertEqual(store.selectedApplicationID, fixture.application.id)
        XCTAssertNil(store.selectedProfileID)
        XCTAssertNil(store.storageRelocationPreview)
    }

    @MainActor
    func testFailureDoesNotRecoverUnrelatedTransaction() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let store = try makeStore(fixture)
        let unrelated = try fixture.preview()
        try fixture.publishPlan(unrelated)
        let failed = try fixture.preview()
        store.storageRelocationPreview = failed
        store.finishFailedStorageRelocation(failed, code: .cancelled, operationMessage: "Synthetic cancellation",
            coordinator: fixture.coordinator, repository: fixture.repository)
        XCTAssertEqual(try fixture.coordinator.pendingRelocations().map(\.transactionID), [unrelated.requestID])
    }

    @MainActor
    func testFailureRecoveryDoesNotRunWhileLibraryLockIsBusy() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let store = try makeStore(fixture)
        let preview = try fixture.preview()
        try fixture.publishPlan(preview)
        _ = try fixture.repository.tryWithExclusiveAccess { _ in
            store.finishFailedStorageRelocation(preview, code: .cancelled, operationMessage: "Synthetic cancellation",
                coordinator: fixture.coordinator, repository: fixture.repository)
            XCTAssertEqual(try fixture.coordinator.pendingRelocations().map(\.transactionID), [preview.requestID])
        }
    }

    @MainActor
    private func makeStore(_ fixture: RelocationAuditFixture, coordinator: StorageRelocationCoordinator? = nil, broadcaster: LibraryChangeBroadcaster? = nil) throws -> LibraryStore {
        let suite = "RelocationAudit.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return LibraryStore(persistence: LibraryPersistence(applicationSupportURL: fixture.root), repository: fixture.repository,
            storageRelocationCoordinator: coordinator ?? fixture.coordinator, profileActivityRegistry: fixture.registry,
            settings: AppSettings(userDefaults: defaults), libraryChangeBroadcaster: broadcaster)
    }
}

extension StorageRelocationAuditRegressionTests {
    func testOversizedPlanIsRejectedBeforePublication() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        let plan = try fixture.coordinator.makeControlPlan(preview: preview, preparedCommit: fixture.prepared(preview))
        let huge = try rewrittenPlan(plan, coordinator: fixture.coordinator) {
            $0["sourceBasePath"] = "/" + String(repeating: "a", count: 4 * 1_024 * 1_024)
        }
        XCTAssertThrowsError(try fixture.coordinator.writeControlPlan(huge))
        XCTAssertTrue(try fixture.coordinator.pendingRelocations().isEmpty)
    }

    func testPreviousBuildOversizedInlinePlanStillLoads() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let preview = try fixture.preview()
        let snapshot = try XCTUnwrap(preview.sourceApplicationSnapshot)
        let entries = (0..<20_000).map { index in
            StorageRelocationManifestEntry(relativeComponents: [String(repeating: "directory-", count: 15), "file-\(index)"],
                kind: "regularFile", byteCount: 1, permissions: 0o600, sha256: String(repeating: "a", count: 64))
        }
        let legacySnapshot = StorageRelocationOwnedTreeSnapshot(identity: snapshot.identity, manifest: entries)
        let legacyObject = try JSONSerialization.jsonObject(with: fixture.coordinator.canonicalBytes(legacySnapshot))
        let plan = try fixture.coordinator.makeControlPlan(preview: preview, preparedCommit: fixture.prepared(preview))
        let legacy = try rewrittenPlan(plan, coordinator: fixture.coordinator) {
            $0["version"] = 1
            $0["sourceApplicationSnapshot"] = legacyObject
        }
        let bytes = try fixture.coordinator.canonicalBytes(legacy)
        XCTAssertGreaterThan(bytes.count, 4 * 1_024 * 1_024)
        try fixture.coordinator.control.write(bytes, to: fixture.coordinator.controlPlanPath(preview.requestID))
        XCTAssertEqual(try fixture.coordinator.pendingRelocations().map(\.transactionID), [preview.requestID])
    }

    private func rewrittenPlan(_ plan: StorageRelocationControlPlan, coordinator: StorageRelocationCoordinator,
        change: (inout [String: Any]) -> Void) throws -> StorageRelocationControlPlan {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: coordinator.canonicalBytes(plan.unsigned)) as? [String: Any])
        change(&object)
        let unsigned = try coordinator.decoder.decode(StorageRelocationControlPlan.Unsigned.self,
            from: JSONSerialization.data(withJSONObject: object))
        return StorageRelocationControlPlan(unsigned: unsigned,
            planSHA256: LibraryPersistence.sha256(try coordinator.canonicalBytes(unsigned)))
    }
}


extension StorageRelocationAuditRegressionTests {
    @MainActor
    func testPostCommitFailurePublishesNewLibraryToOtherWindows() throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let coordinator = try StorageRelocationCoordinator(applicationSupportURL: fixture.root,
            fileSystem: LocalFileSystem(), activityProvider: fixture.registry, availableCapacity: { _ in UInt64.max },
            supportsPermissions: { _ in true },
            transactionBoundary: { event in
                if case .beforeSourceCleanup = event { throw RelocationAuditError.interrupted }
            })
        let broadcaster = LibraryChangeBroadcaster()
        let store = try makeStore(fixture, coordinator: coordinator, broadcaster: broadcaster)
        let preview = try fixture.preview()
        store.storageRelocationPreview = preview
        XCTAssertTrue(store.confirmStorageRelocation(preview))
        XCTAssertNotNil(broadcaster.latestEvent)
        XCTAssertEqual(store.applications.first?.baseStoragePath, fixture.destination.path)
    }

    @MainActor
    func testStorePreparesPreviewOffMainThread() async throws {
        let fixture = try RelocationAuditFixture()
        defer { fixture.remove() }
        let coordinator = try StorageRelocationCoordinator(applicationSupportURL: fixture.root,
            fileSystem: LocalFileSystem(), activityProvider: fixture.registry, availableCapacity: { _ in
                XCTAssertFalse(Thread.isMainThread, "Preview enumeration and hashing must not block the UI")
                return UInt64.max
            }, supportsPermissions: { _ in true })
        let store = try makeStore(fixture, coordinator: coordinator)
        store.prepareStorageRelocation(for: fixture.application, to: fixture.destination)
        XCTAssertTrue(store.isStorageRelocationRunning)
        await store.storageRelocationTask?.value
        XCTAssertFalse(store.isStorageRelocationRunning)
        XCTAssertNotNil(store.storageRelocationPreview)
    }
}

private enum RelocationAuditError: Error {
    case interrupted
}
