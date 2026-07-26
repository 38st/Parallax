import AppKit
import Darwin
import Foundation
import XCTest
@testable import Parallax

final class LibraryStoreRelocationTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory
    private var defaultsSuiteName = ""

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Store-Relocation-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defaultsSuiteName = "parallax.store.relocation.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: defaultsSuiteName)?
            .removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    @MainActor
    func testOrdinaryApplicationEditCannotRelocateStorage() throws {
        let fixture = try makeFixture()
        var edited = fixture.application
        edited.displayName = "Renamed"
        edited.baseStoragePath = fixture.destinationRoot.path

        fixture.store.updateApplication(edited)

        XCTAssertEqual(
            fixture.store.applications.first?.displayName,
            "Renamed"
        )
        XCTAssertEqual(
            fixture.store.applications.first?.baseStoragePath,
            fixture.sourceRoot.path
        )
    }

    @MainActor
    func testExplicitRelocationCommitsDataMetadataAndBackup() throws {
        let fixture = try makeFixture(createSourceData: true)
        let sourcePaths = try fixture.resolver.resolveApplication(
            configuredBaseRoot: fixture.sourceRoot.path,
            applicationStorageID: fixture.application.storageID
        )
        let destinationPaths = try fixture.resolver.resolveApplication(
            configuredBaseRoot: fixture.destinationRoot.path,
            applicationStorageID: fixture.application.storageID
        )

        fixture.store.prepareStorageRelocation(
            for: fixture.application,
            to: fixture.destinationRoot
        )
        let preview = try XCTUnwrap(
            fixture.store.storageRelocationPreview
        )
        XCTAssertTrue(preview.blockers.isEmpty)

        XCTAssertTrue(fixture.store.confirmStorageRelocation(preview))

        XCTAssertEqual(
            fixture.store.applications.first?.baseStoragePath,
            fixture.destinationRoot.path
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: sourcePaths.applicationRoot.url.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destinationPaths.applicationRoot.url
                    .appendingPathComponent("sentinel.txt")
                    .path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: sourcePaths.applicationArchiveRoot.url.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: destinationPaths.applicationArchiveRoot.url
                    .appendingPathComponent("archive.txt")
                    .path
            )
        )
        XCTAssertFalse(
            try fixture.backupStore
                .inspectArtifacts(kind: .backup)
                .isEmpty,
            "Relocation must preserve the exact prior library before its destructive rewrite"
        )
        guard case let .loaded(snapshot) = fixture.repository.load() else {
            return XCTFail("Expected relocated library")
        }
        XCTAssertEqual(
            snapshot.applications.first?.baseStoragePath,
            fixture.destinationRoot.path
        )
    }

    @MainActor
    func testActiveProfileBlocksRelocationBeforeMutation() throws {
        let fixture = try makeFixture(createSourceData: true)
        let identity = ProfileActivityIdentity(
            applicationID: fixture.application.id,
            applicationStorageID: fixture.application.storageID,
            profileID: fixture.application.profiles[0].id,
            profileStorageID: fixture.application.profiles[0].storageID
        )
        let lease = try fixture.activityRegistry.acquire(
            identity: identity,
            requestID: UUID()
        )
        defer { lease.release() }

        fixture.store.prepareStorageRelocation(
            for: fixture.application,
            to: fixture.destinationRoot
        )
        let preview = try XCTUnwrap(
            fixture.store.storageRelocationPreview
        )
        XCTAssertTrue(
            preview.blockers.contains {
                if case .activeProfiles = $0 { true } else { false }
            }
        )

        XCTAssertFalse(fixture.store.confirmStorageRelocation(preview))
        XCTAssertEqual(
            fixture.store.applications.first?.baseStoragePath,
            fixture.sourceRoot.path
        )
    }

    @MainActor
    func testRestartedStoreBlocksRelocationForDurablyRunningProfile() throws {
        let fixture = try makeFixture(createSourceData: true)
        let inspector = StoreRelocationProcessIdentityInspector()
        inspector.setLive(
            ProcessStartIdentity(
                processIdentifier: Darwin.getpid(),
                startTimeSeconds: 1_000,
                startTimeMicroseconds: 10
            )
        )
        let child = ProcessStartIdentity(
            processIdentifier: 8_001,
            startTimeSeconds: 2_000,
            startTimeMicroseconds: 20
        )
        inspector.setLive(child)
        let identity = ProfileActivityIdentity(
            applicationID: fixture.application.id,
            applicationStorageID: fixture.application.storageID,
            profileID: fixture.application.profiles[0].id,
            profileStorageID: fixture.application.profiles[0].storageID
        )
        let requestID = UUID()
        let originalRegistry = try ProfileActivityRegistry(
            applicationSupportURL: fixture.workspace,
            processInspector: inspector
        )
        let lease = try originalRegistry.acquireLaunchLease(
            identity: identity,
            requestID: requestID
        )
        defer {
            try? originalRegistry.completeDurableLaunch(
                requestID: requestID,
                completion: .terminated
            )
            lease.release()
        }
        try originalRegistry.markLaunchOpening(requestID: requestID)
        try originalRegistry.recordRunningProcess(
            requestID: requestID,
            processIdentifier: child.processIdentifier
        )

        let restartedRegistry = try ProfileActivityRegistry(
            applicationSupportURL: fixture.workspace,
            processInspector: inspector
        )
        let relocation = try StorageRelocationCoordinator(
            applicationSupportURL: fixture.workspace,
            fileSystem: LocalFileSystem(),
            pathResolver: fixture.resolver,
            activityProvider: restartedRegistry,
            availableCapacity: { _ in UInt64.max }
        )
        let restartedStore = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: fixture.workspace
            ),
            repository: fixture.repository,
            backupStore: fixture.backupStore,
            profileDataTransactions: fixture.transactions,
            storageRelocationCoordinator: relocation,
            profileActivityRegistry: restartedRegistry,
            settings: try makeSettings()
        )

        restartedStore.prepareStorageRelocation(
            for: fixture.application,
            to: fixture.destinationRoot
        )
        let preview = try XCTUnwrap(
            restartedStore.storageRelocationPreview
        )
        XCTAssertTrue(
            preview.blockers.contains {
                if case .activeProfiles = $0 { true } else { false }
            }
        )
        XCTAssertFalse(restartedStore.confirmStorageRelocation(preview))
        XCTAssertEqual(
            restartedStore.applications.first?.baseStoragePath,
            fixture.sourceRoot.path
        )
    }

    func testActivityRegistryUsesReferenceCounts() {
        let registry = ProfileActivityRegistry()
        let applicationID = UUID()
        let profileID = UUID()
        let identity = ProfileActivityIdentity(
            applicationID: applicationID,
            applicationStorageID: UUID(),
            profileID: profileID,
            profileStorageID: UUID()
        )
        let requestID = UUID()
        let first = try? registry.acquire(
            identity: identity,
            requestID: requestID
        )
        let second = try? registry.acquire(
            identity: identity,
            requestID: requestID
        )
        first?.release()
        XCTAssertEqual(
            registry.activeProfileStorageIDs(
                applicationStorageID: identity.applicationStorageID,
                profileStorageIDs: [identity.profileStorageID]
            ),
            [identity.profileStorageID]
        )

        second?.release()
        XCTAssertTrue(
            registry.activeProfileStorageIDs(
                applicationStorageID: identity.applicationStorageID,
                profileStorageIDs: [identity.profileStorageID]
            ).isEmpty
        )
    }

    @MainActor
    func testStoreDuplicateUsesDurableProfileTransactionCoordinator() throws {
        let fixture = try makeFixture(createSourceData: true)

        XCTAssertTrue(fixture.store.duplicateSelectedProfile())

        let profiles = try XCTUnwrap(
            fixture.store.applications.first?.profiles
        )
        XCTAssertEqual(profiles.count, 2)
        let duplicatePaths = try fixture.resolver.resolve(
            configuredBaseRoot: fixture.sourceRoot.path,
            applicationStorageID: fixture.application.storageID,
            profileStorageID: profiles[1].storageID
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: duplicatePaths.profileRoot.url
                    .appendingPathComponent("sentinel.txt")
                    .path
            )
        )
        XCTAssertTrue(
            try fixture.transactions.pendingTransactions().isEmpty
        )
    }

    @MainActor
    func testDuplicateWithoutManagedDataUsesConfigurationOnlyWording() throws {
        let fixture = try makeFixture()

        XCTAssertTrue(fixture.store.duplicateSelectedProfile())

        XCTAssertEqual(
            fixture.store.launchStatusMessage,
            "Duplicated the configuration as Personal Copy. No managed data existed to copy."
        )
    }

    @MainActor
    func testFailedArchiveOffersBoundRemoveEntryAnywayRecovery() throws {
        let fixture = try makeFixture(
            createSourceData: true,
            profileBoundary: { boundary in
                if boundary == .beforeEffect(.moveToStaging) {
                    throw StoreRelocationInjectedError.profileTransaction
                }
            }
        )
        let profile = fixture.application.profiles[0]
        let profilePath = try fixture.resolver.resolve(
            configuredBaseRoot: fixture.sourceRoot.path,
            applicationStorageID: fixture.application.storageID,
            profileStorageID: profile.storageID
        ).profileRoot.url

        XCTAssertFalse(
            fixture.store.remove(
                profile: profile,
                dataRemoval: .archive
            )
        )
        let recovery = try XCTUnwrap(
            fixture.store.pendingProfileRemovalRecovery
        )
        XCTAssertEqual(
            recovery.canonicalRemainingDataPath,
            profilePath.path
        )
        XCTAssertEqual(
            fixture.store.applications.first?.profiles.map(\.id),
            [profile.id]
        )

        XCTAssertTrue(fixture.store.removeEntryAnyway(recovery))
        XCTAssertTrue(
            fixture.store.applications.first?.profiles.isEmpty == true
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: profilePath.path)
        )
        XCTAssertTrue(
            fixture.store.launchStatusMessage?
                .contains(profilePath.path) == true
        )
    }

    @MainActor
    func testStoreCancellationAfterStagingRollsBackWithoutBlockingUI()
        async throws
    {
        let gate = StoreRelocationBoundaryGate()
        let fixture = try makeFixture(
            createSourceData: true,
            relocationBoundary: { boundary in
                if case .afterStaging = boundary {
                    gate.markReachedAndWait()
                }
            }
        )
        fixture.store.prepareStorageRelocation(
            for: fixture.application,
            to: fixture.destinationRoot
        )
        let preview = try XCTUnwrap(
            fixture.store.storageRelocationPreview
        )
        let sourcePaths = try fixture.resolver.resolveApplication(
            configuredBaseRoot: fixture.sourceRoot.path,
            applicationStorageID: fixture.application.storageID
        )
        let destinationPaths = try fixture.resolver.resolveApplication(
            configuredBaseRoot: fixture.destinationRoot.path,
            applicationStorageID: fixture.application.storageID
        )

        fixture.store.beginStorageRelocation(preview)
        XCTAssertTrue(fixture.store.isStorageRelocationRunning)
        let stagingDeadline = ContinuousClock.now + .seconds(3)
        while !gate.hasReached,
              ContinuousClock.now < stagingDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(gate.hasReached)
        fixture.store.cancelStorageRelocation(preview)
        gate.resume()

        let deadline = ContinuousClock.now + .seconds(3)
        while fixture.store.isStorageRelocationRunning,
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(fixture.store.isStorageRelocationRunning)
        XCTAssertEqual(
            fixture.store.applications.first?.baseStoragePath,
            fixture.sourceRoot.path
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: sourcePaths.applicationRoot.url.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationPaths.applicationRoot.url.path
            )
        )
        XCTAssertEqual(
            fixture.store.launchStatusMessage,
            "Storage relocation was cancelled. Managed data remains at its original location."
        )
    }

    @MainActor
    func testClearMissingDataIgnoresOlderArchivesAndReportsNoData() throws {
        let fixture = try makeFixture()
        let paths = try fixture.resolver.resolve(
            configuredBaseRoot: fixture.sourceRoot.path,
            applicationStorageID: fixture.application.storageID,
            profileStorageID: fixture.application.profiles[0].storageID
        )
        try FileManager.default.createDirectory(
            at: paths.archiveRoot.url
                .appendingPathComponent("older-archive"),
            withIntermediateDirectories: true
        )

        XCTAssertTrue(
            fixture.store.clearProfileData(
                for: fixture.application,
                profile: fixture.application.profiles[0]
            )
        )

        XCTAssertEqual(
            fixture.store.launchStatusMessage,
            "No data exists to clear for Personal"
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: paths.archiveRoot.url
                    .appendingPathComponent("older-archive")
                    .path
            )
        )
    }

    @MainActor
    func testMetadataOnlyDeletesCreateExactPriorLibraryBackups() throws {
        let applicationFixture = try makeFixture()
        let applicationPriorBytes = try Data(
            contentsOf: applicationFixture.primaryLibraryURL
        )

        applicationFixture.store.removeSelectedApplication()

        let applicationBackup = try XCTUnwrap(
            applicationFixture.backupStore
                .inspectArtifacts(kind: .backup)
                .first?.artifact
        )
        XCTAssertEqual(
            try Data(contentsOf: applicationBackup.libraryURL),
            applicationPriorBytes
        )

        let profileFixture = try makeFixture(
            workspaceName: "ProfileDelete"
        )
        let profilePriorBytes = try Data(
            contentsOf: profileFixture.primaryLibraryURL
        )
        XCTAssertTrue(
            profileFixture.store.remove(
                profile: profileFixture.application.profiles[0],
                dataRemoval: .keep
            )
        )
        let profileBackup = try XCTUnwrap(
            profileFixture.backupStore
                .inspectArtifacts(kind: .backup)
                .first?.artifact
        )
        XCTAssertEqual(
            try Data(contentsOf: profileBackup.libraryURL),
            profilePriorBytes
        )
    }

    @MainActor
    func testRequiredBackupFailurePreventsMetadataDeletion() throws {
        let fixture = try makeFixture(failRequiredBackup: true)
        let priorBytes = try Data(contentsOf: fixture.primaryLibraryURL)

        fixture.store.removeSelectedApplication()

        XCTAssertEqual(fixture.store.applications, [fixture.application])
        XCTAssertEqual(
            try Data(contentsOf: fixture.primaryLibraryURL),
            priorBytes
        )
        XCTAssertNotNil(fixture.store.errorMessage)
    }

    @MainActor
    func testRunningLaunchedProfileBlocksStoreRelocationUntilTermination()
        async throws
    {
        let opener = StoreRelocationFakeOpener()
        let terminationObserver = StoreRelocationFakeTerminationObserver()
        let launcher = WorkspaceApplicationLauncher(
            opener: opener,
            terminationObserver: terminationObserver
        )
        let fixture = try makeFixture(
            workspaceName: "TrackedLaunch",
            launcher: launcher,
            createLaunchTarget: true
        )

        fixture.store.launchSelectedProfile()
        for _ in 0..<200 where !opener.hasPendingCompletion {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(opener.hasPendingCompletion)
        let running = StoreRelocationFakeRunningApplication(
            processIdentifier: 4242
        )
        opener.complete(.success(running))

        fixture.store.prepareStorageRelocation(
            for: fixture.application,
            to: fixture.destinationRoot
        )
        let activePreview = try XCTUnwrap(
            fixture.store.storageRelocationPreview
        )
        XCTAssertTrue(
            activePreview.blockers.contains {
                if case .activeProfiles = $0 { true } else { false }
            }
        )

        terminationObserver.terminate(running)
        fixture.store.cancelStorageRelocation(activePreview)
        fixture.store.prepareStorageRelocation(
            for: fixture.application,
            to: fixture.destinationRoot
        )
        let terminatedPreview = try XCTUnwrap(
            fixture.store.storageRelocationPreview
        )
        XCTAssertFalse(
            terminatedPreview.blockers.contains {
                if case .activeProfiles = $0 { true } else { false }
            }
        )
    }

    @MainActor
    func testStoreStartupDiscoversAndRecoversInterruptedRelocation() throws {
        let fixture = try makeFixture(
            createSourceData: true,
            workspaceName: "RestartRecovery",
            relocationBoundary: { event in
                if case .beforeSourceCleanup = event {
                    throw StoreRelocationInjectedError.crash
                }
            }
        )
        fixture.store.prepareStorageRelocation(
            for: fixture.application,
            to: fixture.destinationRoot
        )
        let preview = try XCTUnwrap(
            fixture.store.storageRelocationPreview
        )

        XCTAssertFalse(fixture.store.confirmStorageRelocation(preview))
        XCTAssertEqual(
            try fixture.relocation.pendingRelocations().count,
            1
        )

        let recoveryRelocation = try StorageRelocationCoordinator(
            applicationSupportURL: fixture.workspace,
            fileSystem: LocalFileSystem(),
            pathResolver: fixture.resolver,
            activityProvider: fixture.activityRegistry,
            availableCapacity: { _ in UInt64.max }
        )
        let recoveredStore = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: fixture.workspace
            ),
            repository: fixture.repository,
            backupStore: fixture.backupStore,
            profileDataTransactions: fixture.transactions,
            storageRelocationCoordinator: recoveryRelocation,
            profileActivityRegistry: fixture.activityRegistry,
            launcher: StoreRelocationNoopLauncher(),
            settings: try makeSettings()
        )

        guard case .loaded = recoveredStore.loadState else {
            return XCTFail("Restart recovery must finish before the Store becomes writable")
        }
        XCTAssertEqual(
            recoveredStore.applications.first?.baseStoragePath,
            fixture.destinationRoot.path
        )
        XCTAssertTrue(
            try recoveryRelocation.pendingRelocations().isEmpty
        )
    }

    @MainActor
    func testPostPlanFailureRecoversBeforeStoreReturnsToLoadedState() throws {
        let fixture = try makeFixture(
            createSourceData: true,
            workspaceName: "PostPlanRecovery",
            relocationBoundary: { event in
                if case .afterPlanDurable = event {
                    throw StoreRelocationInjectedError.crash
                }
            }
        )
        fixture.store.prepareStorageRelocation(
            for: fixture.application,
            to: fixture.destinationRoot
        )
        let preview = try XCTUnwrap(
            fixture.store.storageRelocationPreview
        )

        XCTAssertFalse(fixture.store.confirmStorageRelocation(preview))

        guard case .loaded = fixture.store.loadState else {
            return XCTFail("A rolled-back relocation may return to loaded only after recovery")
        }
        XCTAssertTrue(
            try fixture.relocation.pendingRelocations().isEmpty
        )
        XCTAssertEqual(
            fixture.store.applications.first?.baseStoragePath,
            fixture.sourceRoot.path
        )
        let sourcePaths = try fixture.resolver.resolveApplication(
            configuredBaseRoot: fixture.sourceRoot.path,
            applicationStorageID: fixture.application.storageID
        )
        let destinationPaths = try fixture.resolver.resolveApplication(
            configuredBaseRoot: fixture.destinationRoot.path,
            applicationStorageID: fixture.application.storageID
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: sourcePaths.applicationRoot.url.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationPaths.applicationRoot.url.path
            )
        )
    }

    @MainActor
    private func makeFixture(
        createSourceData: Bool = false,
        workspaceName: String = "Default",
        failRequiredBackup: Bool = false,
        launcher: any ApplicationLaunching = StoreRelocationNoopLauncher(),
        createLaunchTarget: Bool = false,
        relocationBoundary:
            (@Sendable (StorageRelocationBoundary) throws -> Void)? = nil,
        profileBoundary:
            (@Sendable (ProfileDataTransactionBoundary) throws -> Void)? = nil
    ) throws -> Fixture {
        let workspace = temporaryDirectory
            .appendingPathComponent(workspaceName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        let sourceRoot = workspace
            .appendingPathComponent("Source", isDirectory: true)
        let destinationRoot = workspace
            .appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )

        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem())
        var profile = LaunchProfile(
            name: "Personal",
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            )
        )
        let applicationPath: String
        if createLaunchTarget {
            applicationPath = try ValidApplicationBundleFixture.create(
                in: workspace,
                name: "Tracked Fixture.app"
            ).url.path
        } else {
            applicationPath = "/Applications/Relocation Fixture.app"
        }
        var application = ManagedApplication(
            displayName: "Relocation Fixture",
            appPath: applicationPath,
            preset: .codex,
            baseStoragePath: sourceRoot.path,
            profiles: [profile]
        )
        let profilePaths = try resolver.resolve(
            configuredBaseRoot: sourceRoot.path,
            applicationStorageID: application.storageID,
            profileStorageID: profile.storageID
        )
        profile.argumentsText = ShellWordsParser.quote(
            "--user-data-dir=\(profilePaths.userData.url.path)"
        )
        profile.environmentText = "CODEX_HOME=\(profilePaths.codexHome.url.path)"
        application.profiles = [profile]

        let persistence = LibraryPersistence(
            applicationSupportURL: workspace
        )
        try persistence.save([application])
        let primaryLibraryURL = workspace
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
        let recoveryRoot = workspace
            .appendingPathComponent("Recovery", isDirectory: true)
        let backupStore = LibraryBackupStore(
            recoveryRoot: recoveryRoot
        )
        let repository = LibraryRepository(
            applicationSupportURL: workspace,
            backupHook: { bytes, reason in
                if failRequiredBackup {
                    throw StoreRelocationInjectedError.backup
                }
                _ = try backupStore.createBackup(
                    of: bytes,
                    reason: reason
                )
            }
        )
        let activityRegistry = ProfileActivityRegistry()
        let relocation = try StorageRelocationCoordinator(
            applicationSupportURL: workspace,
            fileSystem: LocalFileSystem(),
            pathResolver: resolver,
            activityProvider: activityRegistry,
            availableCapacity: { _ in UInt64.max },
            transactionBoundary: relocationBoundary
        )
        let transactions = try ProfileDataTransactionCoordinator(
            applicationSupportURL: workspace,
            transactionBoundary: profileBoundary
        )
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: defaultsSuiteName)
        )
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        let store = LibraryStore(
            persistence: persistence,
            repository: repository,
            backupStore: backupStore,
            profileDataTransactions: transactions,
            storageRelocationCoordinator: relocation,
            profileActivityRegistry: activityRegistry,
            launcher: launcher,
            settings: AppSettings(userDefaults: defaults)
        )

        if createSourceData {
            let appPaths = try resolver.resolveApplication(
                configuredBaseRoot: sourceRoot.path,
                applicationStorageID: application.storageID
            )
            try FileManager.default.createDirectory(
                at: appPaths.applicationRoot.url,
                withIntermediateDirectories: true
            )
            try Data("profile-data".utf8).write(
                to: appPaths.applicationRoot.url
                    .appendingPathComponent("sentinel.txt")
            )
            let managedProfilePaths = try resolver.resolve(
                configuredBaseRoot: sourceRoot.path,
                applicationStorageID: application.storageID,
                profileStorageID: profile.storageID
            )
            try FileManager.default.createDirectory(
                at: managedProfilePaths.profileRoot.url,
                withIntermediateDirectories: true
            )
            try Data("profile-data".utf8).write(
                to: managedProfilePaths.profileRoot.url
                    .appendingPathComponent("sentinel.txt")
            )
            try FileManager.default.createDirectory(
                at: appPaths.applicationArchiveRoot.url,
                withIntermediateDirectories: true
            )
            try Data("archive-data".utf8).write(
                to: appPaths.applicationArchiveRoot.url
                    .appendingPathComponent("archive.txt")
            )
        }

        return Fixture(
            workspace: workspace,
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            primaryLibraryURL: primaryLibraryURL,
            application: application,
            resolver: resolver,
            activityRegistry: activityRegistry,
            backupStore: backupStore,
            repository: repository,
            transactions: transactions,
            relocation: relocation,
            store: store
        )
    }

    @MainActor
    private func makeSettings() throws -> AppSettings {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: defaultsSuiteName)
        )
        return AppSettings(userDefaults: defaults)
    }
}

private struct Fixture {
    let workspace: URL
    let sourceRoot: URL
    let destinationRoot: URL
    let primaryLibraryURL: URL
    let application: ManagedApplication
    let resolver: ManagedPathResolver
    let activityRegistry: ProfileActivityRegistry
    let backupStore: LibraryBackupStore
    let repository: LibraryRepository
    let transactions: ProfileDataTransactionCoordinator
    let relocation: StorageRelocationCoordinator
    let store: LibraryStore
}

private enum StoreRelocationInjectedError: Error {
    case backup
    case crash
    case profileTransaction
}

private final class StoreRelocationBoundaryGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var reached = false

    var hasReached: Bool {
        lock.withLock { reached }
    }

    func markReachedAndWait() {
        lock.withLock {
            reached = true
        }
        release.wait()
    }

    func resume() {
        release.signal()
    }
}

private final class StoreRelocationProcessIdentityInspector:
    ProcessIdentityInspecting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var identities: [pid_t: ProcessStartIdentity] = [:]

    func setLive(_ identity: ProcessStartIdentity) {
        lock.withLock {
            identities[identity.processIdentifier] = identity
        }
    }

    func inspect(processIdentifier: pid_t) -> ProcessIdentityInspection {
        lock.withLock {
            if let identity = identities[processIdentifier] {
                return .live(identity)
            }
            return .dead
        }
    }
}

private final class StoreRelocationFakeOpener:
    WorkspaceApplicationOpening,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var completion:
        (@Sendable (Result<any RunningApplicationInstance, Error>) -> Void)?

    var hasPendingCompletion: Bool {
        lock.withLock { completion != nil }
    }

    func openApplication(
        at _: URL,
        configuration _: NSWorkspace.OpenConfiguration,
        completion:
            @escaping @Sendable (
                Result<any RunningApplicationInstance, Error>
            ) -> Void
    ) {
        lock.withLock {
            self.completion = completion
        }
    }

    func complete(
        _ result: Result<any RunningApplicationInstance, Error>
    ) {
        let callback = lock.withLock {
            let callback = completion
            completion = nil
            return callback
        }
        callback?(result)
    }
}

private final class StoreRelocationFakeRunningApplication:
    RunningApplicationInstance,
    @unchecked Sendable
{
    let processIdentifier: pid_t
    private let lock = NSLock()
    private var terminated = false

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    var isTerminated: Bool {
        lock.withLock { terminated }
    }

    func markTerminated() {
        lock.withLock {
            terminated = true
        }
    }
}

private final class StoreRelocationFakeTerminationObserver:
    RunningApplicationTerminationObserving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var handlers: [
        ObjectIdentifier: @Sendable () -> Void
    ] = [:]

    func observeTermination(
        of application: any RunningApplicationInstance,
        handler: @escaping @Sendable () -> Void
    ) -> any RunningApplicationTerminationObservation {
        lock.withLock {
            handlers[ObjectIdentifier(application)] = handler
        }
        return StoreRelocationFakeTerminationObservation()
    }

    func terminate(
        _ application: StoreRelocationFakeRunningApplication
    ) {
        application.markTerminated()
        let handler = lock.withLock {
            handlers[ObjectIdentifier(application)]
        }
        handler?()
    }
}

private final class StoreRelocationFakeTerminationObservation:
    RunningApplicationTerminationObservation,
    @unchecked Sendable
{
    func cancel() {}
}

private struct StoreRelocationNoopLauncher: ApplicationLaunching {
    func launch(
        application _: ManagedApplication,
        profile _: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) throws {
        completion(.success(()))
    }
}
