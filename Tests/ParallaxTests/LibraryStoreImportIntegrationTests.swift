import Foundation
import XCTest
@testable import Parallax

final class LibraryStoreImportIntegrationTests: XCTestCase {
    private var temporaryDirectory =
        FileManager.default.temporaryDirectory
    private var defaults: UserDefaults?
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Store-Import-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let suite = "parallax.store-import.\(UUID().uuidString)"
        defaultsSuiteName = suite
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults?.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        if let defaults, let defaultsSuiteName {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    @MainActor
    func testImportedTrustIsAlwaysResetBeforeMetadataMerge()
        throws
    {
        let persistence = ImportIntegrationPersistence([])
        let store = try makeStore(persistence: persistence)
        let profile = LaunchProfile(
            name: "Imported",
            launchConfigurationTrust: .importedApproved(
                ImportedLaunchApproval(
                    configurationFingerprint:
                        ImportedLaunchConfigurationFingerprint(
                            sha256: String(repeating: "a", count: 64)
                        ),
                    approvedAt: Date()
                )
            ),
            lastLaunchedAt: Date()
        )
        let application = ManagedApplication(
            displayName: "Imported App",
            appPath: "/Applications/Imported App.app",
            baseStoragePath: temporaryDirectory
                .appendingPathComponent("Managed").path,
            profiles: [profile]
        )

        XCTAssertTrue(
            store.prepareImport(
                data: try importData([application])
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryDirectory
                    .appendingPathComponent("Managed/.parallax").path
            )
        )

        store.confirmImport(replacing: false)

        let imported = try XCTUnwrap(
            store.applications.first?.profiles.first
        )
        XCTAssertEqual(
            imported.launchConfigurationTrust,
            .importedPendingReview
        )
        XCTAssertNil(imported.lastLaunchedAt)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryDirectory
                    .appendingPathComponent("Managed/.parallax").path
            )
        )
    }

    @MainActor
    func testOversizedImportIsRejectedBeforeFileRead() throws {
        let url = temporaryDirectory.appendingPathComponent(
            "oversized.json"
        )
        try Data("{}".utf8).write(to: url)
        let fileSystem = OversizedImportFileSystem(target: url)
        let store = LibraryStore(
            persistence: ImportIntegrationPersistence([]),
            launcher: ImportIntegrationPreparedLauncher(),
            fileSystem: fileSystem,
            settings: try makeSettings()
        )

        XCTAssertFalse(store.prepareImport(at: url))
        XCTAssertEqual(fileSystem.readCount, 0)
        XCTAssertTrue(store.applications.isEmpty)
    }

    @MainActor
    func testMergeConflictRequiresExplicitTargetDecision()
        throws
    {
        let applicationID = UUID()
        let storageID = UUID()
        let existing = ManagedApplication(
            id: applicationID,
            storageID: storageID,
            displayName: "Existing",
            appPath: "/Applications/Existing.app"
        )
        let persistence = ImportIntegrationPersistence([existing])
        let store = try makeStore(persistence: persistence)
        let imported = ManagedApplication(
            id: applicationID,
            storageID: storageID,
            displayName: "Imported",
            appPath: "/Applications/Imported.app"
        )

        XCTAssertTrue(
            store.prepareImport(data: try importData([imported]))
        )
        store.confirmImport(replacing: false)

        XCTAssertTrue(store.isShowingImportConflictResolution)
        XCTAssertEqual(store.applications, [existing])
        let target = try XCTUnwrap(
            store.pendingImportConflictTargets.first
        )

        store.resolvePendingImportConflict(
            .useImported,
            target: target
        )

        XCTAssertFalse(store.isShowingImportConflictResolution)
        XCTAssertEqual(store.applications.first?.displayName, "Imported")
        XCTAssertEqual(
            store.applications.first?.appPath,
            "/Applications/Imported.app"
        )
    }

    @MainActor
    func testReplaceAndUndoPreserveProfileDataAndUseNewRevision()
        throws
    {
        let support = temporaryDirectory.appendingPathComponent(
            "Support",
            isDirectory: true
        )
        let recovery = temporaryDirectory.appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        let repository = LibraryRepository(
            applicationSupportURL: support
        )
        let original = ManagedApplication(
            displayName: "Original",
            appPath: "/Applications/Original.app",
            profiles: [LaunchProfile(name: "Original")]
        )
        _ = try repository.save(
            [original],
            expectedVersion: .missing
        )
        let sentinel = temporaryDirectory.appendingPathComponent(
            "Managed/Profile/sentinel.txt"
        )
        try FileManager.default.createDirectory(
            at: sentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("profile-data".utf8).write(to: sentinel)
        let store = try makeStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            repository: repository,
            backupStore: LibraryBackupStore(
                recoveryRoot: recovery
            )
        )
        let imported = ManagedApplication(
            displayName: "Imported",
            appPath: "/Applications/Imported.app",
            profiles: [LaunchProfile(name: "Imported")]
        )

        XCTAssertTrue(
            store.prepareImport(data: try importData([imported]))
        )
        store.confirmImport(replacing: true)
        let replacementRevision = try loadedSnapshot(repository)
            .versionToken.revision

        XCTAssertEqual(store.applications.first?.displayName, "Imported")
        XCTAssertEqual(
            try String(contentsOf: sentinel),
            "profile-data"
        )
        XCTAssertTrue(store.undoLastImportReplacement())
        let undoRevision = try loadedSnapshot(repository)
            .versionToken.revision

        XCTAssertEqual(store.applications, [original])
        XCTAssertGreaterThan(undoRevision, replacementRevision)
        XCTAssertEqual(
            try String(contentsOf: sentinel),
            "profile-data"
        )
    }

    @MainActor
    func testReplaceImportCannotAdoptAndOverwriteExternalWriter()
        throws
    {
        let support = temporaryDirectory.appendingPathComponent(
            "Support",
            isDirectory: true
        )
        let recovery = temporaryDirectory.appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        let repository = LibraryRepository(
            applicationSupportURL: support
        )
        let original = ManagedApplication(
            displayName: "Original",
            appPath: "/Applications/Original.app"
        )
        let originalSnapshot = try repository.save(
            [original],
            expectedVersion: .missing
        )
        let store = try makeStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            repository: repository,
            backupStore: LibraryBackupStore(
                recoveryRoot: recovery
            )
        )
        let imported = ManagedApplication(
            displayName: "Imported",
            appPath: "/Applications/Imported.app"
        )
        XCTAssertTrue(
            store.prepareImport(data: try importData([imported]))
        )

        let external = ManagedApplication(
            displayName: "External writer",
            appPath: "/Applications/External.app"
        )
        _ = try repository.save(
            [external],
            expectedVersion: originalSnapshot.versionToken
        )

        store.confirmImport(replacing: true)

        XCTAssertEqual(
            try loadedSnapshot(repository).applications,
            [external]
        )
        XCTAssertEqual(store.applications, [original])
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testRepeatedApplicationKeepBothNamesRemainUnique()
        throws
    {
        let existing = ManagedApplication(
            displayName: "Browser",
            appPath: "/Applications/Browser.app"
        )
        let store = try makeStore(
            persistence: ImportIntegrationPersistence([existing])
        )
        let imports = [
            ManagedApplication(
                displayName: "browser",
                appPath: "/Applications/Browser One.app"
            ),
            ManagedApplication(
                displayName: "BROWSER",
                appPath: "/Applications/Browser Two.app"
            ),
        ]

        XCTAssertTrue(store.prepareImport(data: try importData(imports)))
        store.confirmImport(replacing: false)
        XCTAssertTrue(store.isShowingImportConflictResolution)
        store.resolvePendingImportConflict(.keepBoth)
        XCTAssertTrue(store.isShowingImportConflictResolution)
        store.resolvePendingImportConflict(.keepBoth)

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(
            Set(store.applications.map(\.displayName)).count,
            store.applications.count
        )
        XCTAssertEqual(
            Set(
                store.applications.map {
                    $0.displayName.lowercased()
                }
            ).count,
            store.applications.count
        )
    }

    @MainActor
    func testRepeatedProfileKeepBothNamesRemainUnique()
        throws
    {
        let applicationID = UUID()
        let applicationStorageID = UUID()
        let existing = ManagedApplication(
            id: applicationID,
            storageID: applicationStorageID,
            displayName: "Browser",
            appPath: "/Applications/Browser.app",
            profiles: [LaunchProfile(name: "Work")]
        )
        let store = try makeStore(
            persistence: ImportIntegrationPersistence([existing])
        )
        let imported = ManagedApplication(
            id: applicationID,
            storageID: applicationStorageID,
            displayName: "Browser",
            appPath: "/Applications/Browser.app",
            profiles: [
                LaunchProfile(name: "work", argumentsText: "--one"),
                LaunchProfile(name: "WORK", argumentsText: "--two"),
            ]
        )

        XCTAssertTrue(
            store.prepareImport(data: try importData([imported]))
        )
        store.confirmImport(replacing: false)
        XCTAssertTrue(store.isShowingImportConflictResolution)
        store.resolvePendingImportConflict(.keepBoth)
        XCTAssertTrue(store.isShowingImportConflictResolution)
        store.resolvePendingImportConflict(.keepBoth)

        let names = try XCTUnwrap(store.applications.first).profiles
            .map(\.name)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(
            Set(names.map { $0.lowercased() }).count,
            names.count
        )
    }

    @MainActor
    func testImportedLaunchCannotOpenBeforeFingerprintReview()
        async throws
    {
        let fixture = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory
        )
        let launcher = ImportIntegrationPreparedLauncher()
        let settings = try makeSettings()
        settings.confirmBeforeLaunch = false
        settings.defaultBaseStoragePath = temporaryDirectory.path
        let profile = LaunchProfile(
            name: "Imported",
            launchConfigurationTrust: .importedPendingReview
        )
        let application = ManagedApplication(
            displayName: "Fixture",
            bundleIdentifier: fixture.bundleIdentifier,
            appPath: fixture.url.path,
            baseStoragePath: temporaryDirectory.path,
            profiles: [profile]
        )
        let store = LibraryStore(
            persistence: ImportIntegrationPersistence([application]),
            launcher: launcher,
            settings: settings
        )

        store.launch(profile)
        await waitUntil { store.isShowingImportedLaunchReview }

        XCTAssertEqual(launcher.preparedLaunchCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryDirectory
                    .appendingPathComponent(".parallax").path
            )
        )
        store.confirmImportedLaunchReview()
        await waitUntil { launcher.preparedLaunchCount == 1 }

        XCTAssertEqual(launcher.legacyLaunchCount, 0)
        guard
            case .importedApproved =
                store.applications.first?.profiles.first?
                    .launchConfigurationTrust
        else {
            return XCTFail("Expected a persisted imported approval")
        }
    }

    @MainActor
    func testImportedApprovalRejectsApplicationRetargetAfterReview()
        async throws
    {
        let original = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory,
            name: "Original.app",
            bundleIdentifier: "com.example.original",
            executableName: "Original"
        )
        let replacement = try ValidApplicationBundleFixture.create(
            in: temporaryDirectory,
            name: "Replacement.app",
            bundleIdentifier: "com.example.replacement",
            executableName: "Replacement"
        )
        let launcher = ImportIntegrationPreparedLauncher()
        let settings = try makeSettings()
        settings.confirmBeforeLaunch = false
        settings.defaultBaseStoragePath = temporaryDirectory.path
        let profile = LaunchProfile(
            name: "Imported",
            launchConfigurationTrust: .importedPendingReview
        )
        let application = ManagedApplication(
            displayName: "Original",
            bundleIdentifier: original.bundleIdentifier,
            appPath: original.url.path,
            baseStoragePath: temporaryDirectory.path,
            profiles: [profile]
        )
        let store = LibraryStore(
            persistence: ImportIntegrationPersistence([application]),
            launcher: launcher,
            settings: settings
        )

        store.launch(profile)
        await waitUntil { store.isShowingImportedLaunchReview }
        var retargeted = try XCTUnwrap(store.applications.first)
        retargeted.displayName = "Replacement"
        retargeted.bundleIdentifier = replacement.bundleIdentifier
        retargeted.appPath = replacement.url.path
        store.updateApplication(retargeted)
        store.confirmImportedLaunchReview()
        await waitUntil { store.errorMessage != nil }

        XCTAssertEqual(launcher.preparedLaunchCount, 0)
        XCTAssertEqual(launcher.legacyLaunchCount, 0)
        XCTAssertFalse(store.isShowingImportedLaunchReview)
        XCTAssertEqual(
            store.applications.first?.profiles.first?
                .launchConfigurationTrust,
            .importedPendingReview
        )
    }

    @MainActor
    func testStoreHonorsIntentionalEmptyTemplates() throws {
        let settings = try makeSettings()
        settings.profileTemplates = []
        let store = LibraryStore(
            persistence: ImportIntegrationPersistence([]),
            settings: settings
        )

        XCTAssertTrue(store.profileTemplates.isEmpty)
        XCTAssertTrue(store.profileTemplateNames.isEmpty)
    }

    @MainActor
    func testStorePortableExportsRoundTripThroughDeclaredContracts()
        throws
    {
        let settings = try makeSettings()
        settings.profileTemplates = []
        let profile = LaunchProfile(
            name: "Sensitive",
            environmentText: "OPENAI_API_KEY=do-not-export"
        )
        let application = ManagedApplication(
            displayName: "Exported",
            appPath: "/Applications/Exported.app",
            profiles: [profile]
        )
        let source = LibraryStore(
            persistence:
                ImportIntegrationPersistence([application]),
            settings: settings
        )
        let metadata = try source.portableExportData(
            kind: .libraryMetadata,
            sensitivePolicy: .omit
        )
        let settingsData = try source.portableExportData(
            kind: .settingsAndTemplates,
            sensitivePolicy: .omit
        )
        let service = PortableConfigurationService()
        let decodedMetadata =
            try service.decodeLibraryMetadataExport(
                from: metadata
            )
        let decodedSettings =
            try service.decodeSettingsAndTemplatesExport(
                from: settingsData
            )

        XCTAssertFalse(
            try XCTUnwrap(
                decodedMetadata.library.applications.first?
                    .profiles.first
            ).environmentText.contains("do-not-export")
        )
        XCTAssertTrue(
            decodedMetadata.header.disclosure.excludes(
                .managedProfileDataPayloads
            )
        )
        XCTAssertTrue(decodedSettings.settings.profileTemplates.isEmpty)

        let destination = try makeStore(
            persistence: ImportIntegrationPersistence([])
        )
        XCTAssertTrue(destination.prepareImport(data: metadata))
        destination.confirmImport(replacing: false)
        XCTAssertEqual(
            destination.applications.first?.displayName,
            "Exported"
        )
        XCTAssertEqual(
            destination.applications.first?.profiles.first?
                .launchConfigurationTrust,
            .importedPendingReview
        )
    }

    @MainActor
    private func makeStore(
        persistence: any LibraryPersisting,
        repository: (any LibraryRepositoryPersisting)? = nil,
        backupStore: LibraryBackupStore? = nil
    ) throws -> LibraryStore {
        LibraryStore(
            persistence: persistence,
            repository: repository,
            backupStore: backupStore,
            launcher: ImportIntegrationPreparedLauncher(),
            settings: try makeSettings()
        )
    }

    @MainActor
    private func makeSettings() throws -> AppSettings {
        AppSettings(userDefaults: try XCTUnwrap(defaults))
    }

    private func importData(
        _ applications: [ManagedApplication]
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            LibraryDocument(applications: applications)
        )
    }

    private func loadedSnapshot(
        _ repository: any LibraryRepositoryPersisting
    ) throws -> LibraryRepositorySnapshot {
        guard case let .loaded(snapshot) = repository.load() else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return snapshot
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<300 where !condition() {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private final class ImportIntegrationPersistence:
    LibraryPersisting
{
    private(set) var applications: [ManagedApplication]

    init(_ applications: [ManagedApplication]) {
        self.applications = applications
    }

    func load() throws -> [ManagedApplication] {
        applications
    }

    func save(_ applications: [ManagedApplication]) throws {
        self.applications = applications
    }
}

private final class ImportIntegrationPreparedLauncher:
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
            @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        lock.withLock { legacyLaunches += 1 }
        completion(.success(()))
    }

    func launch(
        prepared: PreparedLaunch,
        completion:
            @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        lock.withLock { preparedLaunches += 1 }
        completion(.success(()))
    }
}

private final class OversizedImportFileSystem:
    FileSystem,
    @unchecked Sendable
{
    private let underlying = LocalFileSystem()
    private let target: URL
    private let lock = NSLock()
    private var reads = 0

    init(target: URL) {
        self.target = target.standardizedFileURL
    }

    var readCount: Int {
        lock.withLock { reads }
    }

    func fileExists(at url: URL) -> Bool {
        underlying.fileExists(at: url)
    }

    func attributesOfItem(
        at url: URL
    ) throws -> FileSystemItemAttributes {
        if url.standardizedFileURL == target {
            return FileSystemItemAttributes(
                kind: .regularFile,
                size: UInt64(
                    LibraryImportLimits().maximumBytes + 1
                ),
                modificationDate: nil,
                posixPermissions: nil,
                identity: nil
            )
        }
        return try underlying.attributesOfItem(at: url)
    }

    func canonicalURL(for url: URL) throws -> URL {
        try underlying.canonicalURL(for: url)
    }

    func createDirectory(
        at url: URL,
        withIntermediateDirectories: Bool
    ) throws {
        try underlying.createDirectory(
            at: url,
            withIntermediateDirectories:
                withIntermediateDirectories
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try underlying.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try underlying.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try underlying.removeItem(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try underlying.contentsOfDirectory(at: url)
    }

    func readData(at url: URL) throws -> Data {
        lock.withLock { reads += 1 }
        return try underlying.readData(at: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try underlying.writeData(data, to: url)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try underlying.writeDataAtomically(data, to: url)
    }

    func replaceItem(
        at destinationURL: URL,
        withItemAt sourceURL: URL
    ) throws {
        try underlying.replaceItem(
            at: destinationURL,
            withItemAt: sourceURL
        )
    }

    func applicationSupportURL(create: Bool) throws -> URL {
        try underlying.applicationSupportURL(create: create)
    }
}
