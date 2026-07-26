import Foundation
import XCTest
@testable import Parallax

final class CompletionGateLaunchMutationTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory
    private var defaultsSuiteName = ""

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Completion-Gate-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defaultsSuiteName =
            "parallax.completion-gate.\(UUID().uuidString)"
    }

    override func tearDownWithError() throws {
        UserDefaults(suiteName: defaultsSuiteName)?
            .removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    @MainActor
    func testActiveProfileBlocksClearBeforeDataOrMetadataMutation() throws {
        let fixture = try makeMutationFixture()
        let lease = try acquireActiveLease(for: fixture)
        defer { lease.release() }

        XCTAssertFalse(
            fixture.store.clearProfileData(
                for: fixture.application,
                profile: fixture.profile
            )
        )

        try assertFixtureWasNotMutated(fixture)
        assertActiveProfileMessage(fixture.store.errorMessage)
    }

    @MainActor
    func testActiveProfileBlocksArchiveBeforeDataOrMetadataMutation() throws {
        let fixture = try makeMutationFixture()
        let lease = try acquireActiveLease(for: fixture)
        defer { lease.release() }

        XCTAssertFalse(
            fixture.store.remove(
                profile: fixture.profile,
                dataRemoval: .archive
            )
        )

        try assertFixtureWasNotMutated(fixture)
        assertActiveProfileMessage(fixture.store.errorMessage)
    }

    @MainActor
    func testActiveProfileBlocksDeleteBeforeDataOrMetadataMutation() throws {
        let fixture = try makeMutationFixture()
        let lease = try acquireActiveLease(for: fixture)
        defer { lease.release() }

        XCTAssertFalse(
            fixture.store.remove(
                profile: fixture.profile,
                dataRemoval: .delete
            )
        )

        try assertFixtureWasNotMutated(fixture)
        assertActiveProfileMessage(fixture.store.errorMessage)
    }

    @MainActor
    func testActiveProfileBlocksMetadataOnlyRemoval() throws {
        let fixture = try makeMutationFixture()
        let lease = try acquireActiveLease(for: fixture)
        defer { lease.release() }

        XCTAssertFalse(
            fixture.store.remove(
                profile: fixture.profile,
                dataRemoval: .keep
            )
        )

        try assertFixtureWasNotMutated(fixture)
        assertActiveProfileMessage(fixture.store.errorMessage)
    }

    @MainActor
    func testActiveProfileBlocksApplicationRemovalBeforeDataOrMetadataMutation()
        throws
    {
        let fixture = try makeMutationFixture()
        let lease = try acquireActiveLease(for: fixture)
        defer { lease.release() }

        fixture.store.beginApplicationRemoval(
            fixture.application,
            dataChoice: .delete
        )
        XCTAssertTrue(
            fixture.store.isShowingApplicationRemovalConfirmation
        )
        fixture.store.confirmApplicationRemoval()

        try assertFixtureWasNotMutated(fixture)
        XCTAssertFalse(
            fixture.store.isShowingApplicationRemovalConfirmation
        )
        let errorMessage = try XCTUnwrap(fixture.store.errorMessage)
        XCTAssertTrue(
            errorMessage.localizedCaseInsensitiveContains("active"),
            errorMessage
        )
    }

    @MainActor
    func testActiveProfileBlocksDuplicateBeforeDataOrMetadataMutation() throws {
        let fixture = try makeMutationFixture()
        let lease = try acquireActiveLease(for: fixture)
        defer { lease.release() }

        XCTAssertFalse(fixture.store.duplicateSelectedProfile())

        try assertFixtureWasNotMutated(fixture)
        XCTAssertEqual(fixture.store.applications[0].profiles.count, 1)
        assertActiveProfileMessage(fixture.store.errorMessage)
    }

    @MainActor
    func testActiveProfileBlocksRelocationBeforeDataOrMetadataMutation()
        throws
    {
        let fixture = try makeMutationFixture()
        let lease = try acquireActiveLease(for: fixture)
        defer { lease.release() }

        fixture.store.prepareStorageRelocation(
            for: fixture.application,
            to: fixture.destinationRoot
        )
        let preview = try XCTUnwrap(fixture.store.storageRelocationPreview)
        XCTAssertTrue(
            preview.blockers.contains {
                if case .activeProfiles = $0 {
                    return true
                }
                return false
            }
        )
        XCTAssertFalse(fixture.store.confirmStorageRelocation(preview))

        try assertFixtureWasNotMutated(fixture)
        let destinationApplicationRoot = try fixture.resolver
            .resolveApplication(
                configuredBaseRoot: fixture.destinationRoot.path,
                applicationStorageID: fixture.application.storageID
            )
            .applicationRoot.url
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: destinationApplicationRoot.path
            )
        )
    }

    @MainActor
    func testMissingApplicationBundleIsUnhealthyAndLaunchIsBlocked()
        async throws
    {
        let workspace = fixtureWorkspace(named: "Missing-Bundle")
        try FileManager.default.createDirectory(
            at: workspace,
            withIntermediateDirectories: true
        )
        let storageRoot = workspace.appendingPathComponent(
            "Storage",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: storageRoot,
            withIntermediateDirectories: true
        )
        let missingBundle = workspace.appendingPathComponent(
            "Removed.app",
            isDirectory: true
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: missingBundle.path)
        )

        let profile = LaunchProfile(name: "Missing Application")
        let application = ManagedApplication(
            displayName: "Missing Application",
            appPath: missingBundle.path,
            preset: .custom,
            baseStoragePath: storageRoot.path,
            profiles: [profile]
        )
        let persistence = LibraryPersistence(
            applicationSupportURL: workspace
        )
        try persistence.save([application])
        let launcher = CompletionGateRecordingPreparedLauncher()
        let settings = try makeSettings()
        settings.confirmBeforeLaunch = false
        let store = LibraryStore(
            persistence: persistence,
            launcher: launcher,
            launchConfigurationCompiler: LaunchConfigurationCompiler(
                fileSystem: LocalFileSystem(),
                identity: ChildEnvironmentIdentity(
                    homeDirectory: workspace.path,
                    userName: "completion-gate",
                    temporaryDirectory: workspace.path
                ),
                processEnvironment: [:],
                secretResolver: CompletionGateMissingSecretResolver()
            ),
            settings: settings
        )
        store.selectedApplicationID = application.id
        store.selectedProfileID = profile.id

        let health = Dictionary(
            uniqueKeysWithValues:
                await store.refreshHealthItems(
                    for: application,
                    profile: profile
                )
        )
        XCTAssertEqual(health["Application bundle"], false)

        store.launchSelectedProfile()
        await waitUntil {
            store.launchStatusMessage(
                for: application,
                profile: profile
            )?.contains("Launch failed") == true
        }

        XCTAssertEqual(launcher.preparedLaunchCount, 0)
        XCTAssertEqual(launcher.legacyLaunchCount, 0)
        XCTAssertTrue(
            store.launchStatusMessage(
                for: application,
                profile: profile
            )?.localizedCaseInsensitiveContains(
                "not healthy enough to launch"
            ) == true
        )
    }

    @MainActor
    private func makeMutationFixture() throws -> MutationFixture {
        let workspace = fixtureWorkspace(named: UUID().uuidString)
        let sourceRoot = workspace.appendingPathComponent(
            "Source",
            isDirectory: true
        )
        let destinationRoot = workspace.appendingPathComponent(
            "Destination",
            isDirectory: true
        )
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
            name: "Active",
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .explicit
            )
        )
        var application = ManagedApplication(
            displayName: "Completion Gate",
            appPath: workspace
                .appendingPathComponent("Fixture.app", isDirectory: true)
                .path,
            preset: .chromium,
            baseStoragePath: sourceRoot.path,
            profiles: [profile]
        )
        let paths = try resolver.resolve(
            configuredBaseRoot: sourceRoot.path,
            applicationStorageID: application.storageID,
            profileStorageID: profile.storageID
        )
        profile.argumentsText = ShellWordsParser.quote(
            "--user-data-dir=\(paths.userData.url.path)"
        )
        application.profiles = [profile]

        let persistence = LibraryPersistence(
            applicationSupportURL: workspace
        )
        try persistence.save([application])
        let primaryLibraryURL = workspace
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
        let originalLibraryBytes = try Data(contentsOf: primaryLibraryURL)
        let backupStore = LibraryBackupStore(
            recoveryRoot: workspace.appendingPathComponent(
                "Recovery",
                isDirectory: true
            )
        )
        let repository = LibraryRepository(
            applicationSupportURL: workspace,
            backupHook: { bytes, reason in
                _ = try backupStore.createBackup(
                    of: bytes,
                    reason: reason
                )
            }
        )
        let activityRegistry = ProfileActivityRegistry()
        let profileDataTransactions =
            try ProfileDataTransactionCoordinator(
                applicationSupportURL: workspace
            )
        let applicationRemovalTransactions =
            try ApplicationRemovalTransactionCoordinator(
                applicationSupportURL: workspace
            )
        let relocation = try StorageRelocationCoordinator(
            applicationSupportURL: workspace,
            fileSystem: LocalFileSystem(),
            pathResolver: resolver,
            activityProvider: activityRegistry,
            availableCapacity: { _ in UInt64.max }
        )
        let store = LibraryStore(
            persistence: persistence,
            repository: repository,
            backupStore: backupStore,
            profileDataTransactions: profileDataTransactions,
            applicationRemovalTransactions:
                applicationRemovalTransactions,
            storageRelocationCoordinator: relocation,
            profileActivityRegistry: activityRegistry,
            launcher: CompletionGateRecordingPreparedLauncher(),
            settings: try makeSettings()
        )
        store.selectedApplicationID = application.id
        store.selectedProfileID = profile.id

        try FileManager.default.createDirectory(
            at: paths.profileRoot.url,
            withIntermediateDirectories: true
        )
        let sentinelURL = paths.profileRoot.url.appendingPathComponent(
            "sentinel.txt",
            isDirectory: false
        )
        let sentinelBytes = Data("active-profile-data".utf8)
        try sentinelBytes.write(to: sentinelURL)

        return MutationFixture(
            application: application,
            profile: profile,
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            primaryLibraryURL: primaryLibraryURL,
            originalLibraryBytes: originalLibraryBytes,
            sentinelURL: sentinelURL,
            sentinelBytes: sentinelBytes,
            resolver: resolver,
            activityRegistry: activityRegistry,
            store: store
        )
    }

    private func acquireActiveLease(
        for fixture: MutationFixture
    ) throws -> ProfileActivityLease {
        try fixture.activityRegistry.acquire(
            identity: ProfileActivityIdentity(
                applicationID: fixture.application.id,
                applicationStorageID: fixture.application.storageID,
                profileID: fixture.profile.id,
                profileStorageID: fixture.profile.storageID
            ),
            requestID: UUID()
        )
    }

    @MainActor
    private func assertFixtureWasNotMutated(
        _ fixture: MutationFixture
    ) throws {
        XCTAssertEqual(fixture.store.applications, [fixture.application])
        XCTAssertEqual(
            fixture.store.applications[0].baseStoragePath,
            fixture.sourceRoot.path
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.primaryLibraryURL),
            fixture.originalLibraryBytes
        )
        XCTAssertEqual(
            try Data(contentsOf: fixture.sentinelURL),
            fixture.sentinelBytes
        )
    }

    private func assertActiveProfileMessage(
        _ message: String?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            message?.localizedCaseInsensitiveContains(
                "launching or running"
            ) == true,
            file: file,
            line: line
        )
    }

    @MainActor
    private func makeSettings() throws -> AppSettings {
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: defaultsSuiteName)
        )
        let settings = AppSettings(userDefaults: defaults)
        settings.defaultBaseStoragePath = temporaryDirectory.path
        return settings
    }

    private func fixtureWorkspace(named name: String) -> URL {
        temporaryDirectory.appendingPathComponent(
            name,
            isDirectory: true
        )
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<200 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct MutationFixture {
    let application: ManagedApplication
    let profile: LaunchProfile
    let sourceRoot: URL
    let destinationRoot: URL
    let primaryLibraryURL: URL
    let originalLibraryBytes: Data
    let sentinelURL: URL
    let sentinelBytes: Data
    let resolver: ManagedPathResolver
    let activityRegistry: ProfileActivityRegistry
    let store: LibraryStore
}

private final class CompletionGateRecordingPreparedLauncher:
    PreparedApplicationLaunching,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var preparedLaunches = 0
    private var legacyLaunches = 0

    var preparedLaunchCount: Int {
        lock.withLock { preparedLaunches }
    }

    var legacyLaunchCount: Int {
        lock.withLock { legacyLaunches }
    }

    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion:
            @escaping @Sendable (Result<Void, any Error>) -> Void
    ) throws {
        lock.withLock {
            legacyLaunches += 1
        }
        completion(.success(()))
    }

    func launch(
        prepared: PreparedLaunch,
        completion:
            @escaping @Sendable (Result<Void, any Error>) -> Void
    ) throws {
        lock.withLock {
            preparedLaunches += 1
        }
        completion(.success(()))
    }
}

private actor CompletionGateMissingSecretResolver: SecretResolving {
    func resolve(
        _ reference: EnvironmentSecretReference
    ) async throws -> SecretValue {
        throw SecretStoreError.missing(reference)
    }
}
