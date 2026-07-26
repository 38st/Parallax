import Foundation
import XCTest
@testable import Parallax

final class LibraryStoreWave3Tests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory
    private var userDefaults: UserDefaults?
    private var userDefaultsSuiteName: String?

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Wave3-Store-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        let suiteName = "parallax.wave3.store.tests.\(UUID().uuidString)"
        userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaultsSuiteName = suiteName
        userDefaults?.removePersistentDomain(forName: suiteName)
    }

    override func tearDownWithError() throws {
        if let userDefaults, let userDefaultsSuiteName {
            userDefaults.removePersistentDomain(forName: userDefaultsSuiteName)
        }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testRepositoryClassifiesCorruptLibraryAsRecoveryRequiredAndPreservesBytes() throws {
        let bytes = Data(#"{"version":2,"applications":["#.utf8)
        let libraryURL = try writePrimaryLibrary(bytes)
        let repository = LibraryRepository(applicationSupportURL: temporaryDirectory)

        guard case let .recoveryRequired(failure) = repository.load() else {
            return XCTFail("A corrupt primary must require recovery.")
        }

        XCTAssertEqual(failure.originalBytes, bytes)
        XCTAssertEqual(try Data(contentsOf: libraryURL), bytes)
    }

    func testRepositoryClassifiesUnsupportedLibraryAsReadOnlyAndPreservesBytes() throws {
        let bytes = Data(
            """
            {
              "version": \(LibraryDocument.currentVersion + 1),
              "applications": []
            }
            """.utf8
        )
        let libraryURL = try writePrimaryLibrary(bytes)
        let repository = LibraryRepository(applicationSupportURL: temporaryDirectory)

        guard case let .readOnly(failure) = repository.load() else {
            return XCTFail("A newer primary must remain read-only.")
        }

        XCTAssertEqual(failure.originalBytes, bytes)
        XCTAssertEqual(try Data(contentsOf: libraryURL), bytes)
    }

    @MainActor
    func testCorruptLibraryCannotBeOverwrittenByLaterStoreMutation() throws {
        let bytes = Data(#"{"version":2,"applications":["#.utf8)
        let libraryURL = try writePrimaryLibrary(bytes)
        let applicationURL = try makeApplicationBundle(named: "Corrupt Guard")
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: Wave3NoopLauncher(),
            settings: try makeSettings()
        )

        store.addApplication(at: applicationURL)

        XCTAssertTrue(store.applications.isEmpty)
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertNil(store.selectedProfileID)
        XCTAssertEqual(try Data(contentsOf: libraryURL), bytes)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testUnsupportedLibraryCannotBeOverwrittenByLaterStoreMutation() throws {
        let bytes = Data(
            """
            {
              "version": \(LibraryDocument.currentVersion + 1),
              "applications": []
            }
            """.utf8
        )
        let libraryURL = try writePrimaryLibrary(bytes)
        let applicationURL = try makeApplicationBundle(named: "Read Only Guard")
        let store = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: temporaryDirectory),
            launcher: Wave3NoopLauncher(),
            settings: try makeSettings()
        )

        store.addApplication(at: applicationURL)

        XCTAssertTrue(store.applications.isEmpty)
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertNil(store.selectedProfileID)
        XCTAssertEqual(try Data(contentsOf: libraryURL), bytes)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testCorruptLibraryBlocksRetainedProfileFilesystemMutations() throws {
        try assertRetainedProfileFilesystemMutationsAreBlocked(
            libraryBytes: Data(#"{"version":2,"applications":["#.utf8)
        )
    }

    @MainActor
    func testNewerLibraryBlocksRetainedProfileFilesystemMutations() throws {
        try assertRetainedProfileFilesystemMutationsAreBlocked(
            libraryBytes: Data(
                """
                {
                  "version": \(LibraryDocument.currentVersion + 1),
                  "applications": []
                }
                """.utf8
            )
        )
    }

    @MainActor
    func testRecoveryArtifactIsBoundToCurrentFailedPrimaryBytes() throws {
        let failedBytes = Data(#"{"version":2,"applications":["#.utf8)
        _ = try writePrimaryLibrary(failedBytes)
        let backupStore = LibraryBackupStore(
            recoveryRoot: temporaryDirectory
                .appendingPathComponent("Recovery", isDirectory: true)
        )
        let unrelatedBytes = Data("unrelated-newer-artifact".utf8)
        let unrelated = try backupStore.quarantine(unrelatedBytes)
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: temporaryDirectory
            ),
            repository: LibraryRepository(
                applicationSupportURL: temporaryDirectory
            ),
            backupStore: backupStore,
            launcher: Wave3NoopLauncher(),
            settings: try makeSettings()
        )

        let artifact = try store.recoveryArtifactForCurrentFailure()

        XCTAssertNotEqual(artifact.id, unrelated.id)
        XCTAssertEqual(
            artifact.sha256,
            LibraryPersistence.sha256(failedBytes)
        )
        XCTAssertEqual(
            try Data(contentsOf: artifact.libraryURL),
            failedBytes
        )
        XCTAssertEqual(
            try store.recoveryArtifactForCurrentFailure().id,
            artifact.id,
            "Repeated inspect/export actions must reuse the exact matching quarantine"
        )
    }

    @MainActor
    func testAddApplicationSaveFailureRestoresApplicationsAndSelection() throws {
        let persistence = Wave3StubPersistence(
            applications: [],
            saveError: Wave3InjectedError.save
        )
        let store = LibraryStore(
            persistence: persistence,
            launcher: Wave3NoopLauncher(),
            settings: try makeSettings()
        )

        store.addApplication(at: try makeApplicationBundle(named: "Unsaved App"))

        XCTAssertTrue(store.applications.isEmpty)
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertNil(store.selectedProfileID)
        XCTAssertEqual(persistence.saveCallCount, 1)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testAddProfileSaveFailureRestoresApplicationsAndSelection() throws {
        let fixture = makeApplicationFixture()
        let persistence = Wave3StubPersistence(
            applications: [fixture.application],
            saveError: Wave3InjectedError.save
        )
        let store = LibraryStore(
            persistence: persistence,
            launcher: Wave3NoopLauncher(),
            settings: try makeSettings()
        )

        store.addProfile(named: "Work")

        XCTAssertEqual(store.applications, [fixture.application])
        XCTAssertEqual(store.selectedApplicationID, fixture.application.id)
        XCTAssertEqual(store.selectedProfileID, fixture.profile.id)
        XCTAssertEqual(persistence.saveCallCount, 1)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testUpdateApplicationSaveFailureRestoresPriorValue() throws {
        let fixture = makeApplicationFixture()
        let persistence = Wave3StubPersistence(
            applications: [fixture.application],
            saveError: Wave3InjectedError.save
        )
        let store = LibraryStore(
            persistence: persistence,
            launcher: Wave3NoopLauncher(),
            settings: try makeSettings()
        )
        var edited = fixture.application
        edited.displayName = "Unsaved Rename"

        store.updateApplication(edited)

        XCTAssertEqual(store.applications, [fixture.application])
        XCTAssertEqual(store.selectedApplicationID, fixture.application.id)
        XCTAssertEqual(store.selectedProfileID, fixture.profile.id)
        XCTAssertEqual(persistence.saveCallCount, 1)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testUpdateProfileSaveFailureRestoresPriorValue() throws {
        let fixture = makeApplicationFixture()
        let persistence = Wave3StubPersistence(
            applications: [fixture.application],
            saveError: Wave3InjectedError.save
        )
        let store = LibraryStore(
            persistence: persistence,
            launcher: Wave3NoopLauncher(),
            settings: try makeSettings()
        )
        var edited = fixture.profile
        edited.name = "Unsaved Profile Rename"

        store.updateProfile(edited)

        XCTAssertEqual(store.applications, [fixture.application])
        XCTAssertEqual(store.selectedProfileID, fixture.profile.id)
        XCTAssertEqual(persistence.saveCallCount, 1)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testRemoveApplicationWithoutTransactionServicesPreservesState()
        throws
    {
        let fixture = makeApplicationFixture()
        let persistence = Wave3StubPersistence(
            applications: [fixture.application],
            saveError: Wave3InjectedError.save
        )
        let store = LibraryStore(
            persistence: persistence,
            launcher: Wave3NoopLauncher(),
            settings: try makeSettings()
        )

        store.removeSelectedApplication()

        XCTAssertEqual(store.applications, [fixture.application])
        XCTAssertEqual(store.selectedApplicationID, fixture.application.id)
        XCTAssertEqual(store.selectedProfileID, fixture.profile.id)
        XCTAssertEqual(persistence.saveCallCount, 0)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testRemoveProfileOnlySaveFailureRestoresMetadataAndSelection() throws {
        let fixture = makeApplicationFixture()
        let persistence = Wave3StubPersistence(
            applications: [fixture.application],
            saveError: Wave3InjectedError.save
        )
        let store = LibraryStore(
            persistence: persistence,
            launcher: Wave3NoopLauncher(),
            settings: try makeSettings()
        )

        XCTAssertFalse(store.remove(profile: fixture.profile, dataRemoval: .keep))

        XCTAssertEqual(store.applications, [fixture.application])
        XCTAssertEqual(store.selectedProfileID, fixture.profile.id)
        XCTAssertEqual(persistence.saveCallCount, 1)
        XCTAssertNotNil(store.errorMessage)
    }

    func testRepositoryRejectsStaleWriterWithoutLosingFirstWriterUpdate() throws {
        let firstRepository = LibraryRepository(
            applicationSupportURL: temporaryDirectory
        )
        let secondRepository = LibraryRepository(
            applicationSupportURL: temporaryDirectory
        )
        guard case .missing = firstRepository.load(),
              case .missing = secondRepository.load()
        else {
            return XCTFail("Both repositories must begin from the same missing token.")
        }
        let firstApplication = makeApplicationFixture(
            displayName: "First Writer"
        ).application
        let staleApplication = makeApplicationFixture(
            displayName: "Stale Writer"
        ).application

        _ = try firstRepository.save(
            [firstApplication],
            expectedVersion: .missing
        )

        XCTAssertThrowsError(
            try secondRepository.save(
                [staleApplication],
                expectedVersion: .missing
            )
        ) { error in
            guard case LibraryRepositoryError.staleWriter = error else {
                return XCTFail("Expected stale-writer conflict, got \(error).")
            }
        }

        guard case let .loaded(snapshot) = firstRepository.load() else {
            return XCTFail("The committed library must remain readable.")
        }
        XCTAssertEqual(snapshot.applications, [firstApplication])
    }

    @MainActor
    func testDuplicatePublishesDataBeforeMetadata() throws {
        let fixture = makeApplicationFixture()
        let trace = Wave3EventTrace()
        let fileSystem = Wave3TrackingFileSystem(trace: trace)
        let persistence = Wave3StubPersistence(
            applications: [fixture.application],
            trace: trace
        )
        let store = LibraryStore(
            persistence: persistence,
            launcher: Wave3NoopLauncher(),
            fileSystem: fileSystem,
            settings: try makeSettings()
        )
        let sourceURL = try store.managedPaths(
            for: fixture.application,
            profile: fixture.profile
        ).profileRoot.url
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )
        try Data("source".utf8).write(
            to: sourceURL.appendingPathComponent("sentinel")
        )

        XCTAssertTrue(store.duplicateSelectedProfile())

        let events = trace.events
        let copyIndex = try XCTUnwrap(events.firstIndex(of: "fs.copy"))
        let saveIndex = try XCTUnwrap(events.firstIndex(of: "persistence.save"))
        XCTAssertLessThan(copyIndex, saveIndex)
    }

    @MainActor
    func testDuplicateNeverDeletesDestinationThatAppearsBeforePublication() throws {
        let fixture = makeApplicationFixture()
        let fileSystem = Wave3TrackingFileSystem()
        let persistence = Wave3StubPersistence(
            applications: [fixture.application]
        )
        let store = LibraryStore(
            persistence: persistence,
            launcher: Wave3NoopLauncher(),
            fileSystem: fileSystem,
            settings: try makeSettings()
        )
        let sourceURL = try store.managedPaths(
            for: fixture.application,
            profile: fixture.profile
        ).profileRoot.url
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )
        try Data("source".utf8).write(
            to: sourceURL.appendingPathComponent("sentinel")
        )
        let destinationBox = Wave3URLBox()
        let unexpectedBytes = Data("unexpected-owner".utf8)
        fileSystem.beforeCopy = { _, destination in
            destinationBox.value = destination
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
            try unexpectedBytes.write(
                to: destination.appendingPathComponent("unexpected")
            )
        }

        XCTAssertFalse(store.duplicateSelectedProfile())

        let destination = try XCTUnwrap(destinationBox.value)
        let unexpectedURL = destination.appendingPathComponent("unexpected")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unexpectedURL.path),
            "A destination that appeared during publication belongs to another writer and must never be removed."
        )
        if FileManager.default.fileExists(atPath: unexpectedURL.path) {
            XCTAssertEqual(try Data(contentsOf: unexpectedURL), unexpectedBytes)
        }
        XCTAssertEqual(store.applications, [fixture.application])
        XCTAssertEqual(store.selectedProfileID, fixture.profile.id)
    }

    @MainActor
    func testArchiveMoveFailureKeepsMetadataAndDoesNotSave() throws {
        let fixture = makeApplicationFixture()
        let fileSystem = Wave3TrackingFileSystem()
        fileSystem.failure = .move
        let persistence = Wave3StubPersistence(
            applications: [fixture.application]
        )
        let store = LibraryStore(
            persistence: persistence,
            launcher: Wave3NoopLauncher(),
            fileSystem: fileSystem,
            settings: try makeSettings()
        )
        let sourceURL = try store.managedPaths(
            for: fixture.application,
            profile: fixture.profile
        ).profileRoot.url
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )

        XCTAssertFalse(store.remove(profile: fixture.profile, dataRemoval: .archive))

        XCTAssertEqual(store.applications, [fixture.application])
        XCTAssertEqual(store.selectedProfileID, fixture.profile.id)
        XCTAssertEqual(persistence.saveCallCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))
    }

    @MainActor
    func testPostCommitDeleteFailureRequiresRecovery() throws {
        let fixture = makeApplicationFixture()
        let fileSystem = Wave3TrackingFileSystem()
        fileSystem.failure = .remove
        let persistence = Wave3StubPersistence(
            applications: [fixture.application]
        )
        let store = LibraryStore(
            persistence: persistence,
            launcher: Wave3NoopLauncher(),
            fileSystem: fileSystem,
            settings: try makeSettings()
        )
        let sourceURL = try store.managedPaths(
            for: fixture.application,
            profile: fixture.profile
        ).profileRoot.url
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )

        XCTAssertFalse(store.remove(profile: fixture.profile, dataRemoval: .delete))

        XCTAssertEqual(store.applications.first?.profiles, [])
        XCTAssertNil(store.selectedProfileID)
        XCTAssertEqual(persistence.saveCallCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        guard case .recoveryRequired = store.loadState else {
            return XCTFail("Expected recovery after a post-commit purge failure")
        }
    }

    @MainActor
    func testDeleteFollowedBySaveFailureRestoresDataAndMetadata() throws {
        let fixture = makeApplicationFixture()
        let persistence = Wave3StubPersistence(
            applications: [fixture.application],
            saveError: Wave3InjectedError.save
        )
        let store = LibraryStore(
            persistence: persistence,
            launcher: Wave3NoopLauncher(),
            settings: try makeSettings()
        )
        let sourceURL = try store.managedPaths(
            for: fixture.application,
            profile: fixture.profile
        ).profileRoot.url
        try FileManager.default.createDirectory(
            at: sourceURL,
            withIntermediateDirectories: true
        )
        let sentinelURL = sourceURL.appendingPathComponent("sentinel")
        let sentinelBytes = Data("must-survive".utf8)
        try sentinelBytes.write(to: sentinelURL)

        XCTAssertFalse(store.remove(profile: fixture.profile, dataRemoval: .delete))

        XCTAssertEqual(store.applications, [fixture.application])
        XCTAssertEqual(store.selectedProfileID, fixture.profile.id)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: sentinelURL.path),
            "Delete must remain reversible until metadata commits."
        )
        if FileManager.default.fileExists(atPath: sentinelURL.path) {
            XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinelBytes)
        }
    }

    @MainActor
    func testRevealMissingManagedFolderPerformsNoWrites() throws {
        let fixture = makeApplicationFixture()
        let fileSystem = Wave3TrackingFileSystem()
        fileSystem.failure = .create
        let store = LibraryStore(
            persistence: Wave3StubPersistence(
                applications: [fixture.application]
            ),
            launcher: Wave3NoopLauncher(),
            fileSystem: fileSystem,
            settings: try makeSettings()
        )

        _ = store.revealProfileFolder(
            for: fixture.application,
            profile: fixture.profile
        )

        XCTAssertFalse(fileSystem.events.contains("create"))
        XCTAssertFalse(fileSystem.events.contains("move"))
        XCTAssertFalse(fileSystem.events.contains("copy"))
        XCTAssertFalse(fileSystem.events.contains("remove"))
    }

    @MainActor
    func testClearMissingManagedDataCreatesNothingAndReportsNoData() throws {
        let fixture = makeApplicationFixture()
        let fileSystem = Wave3TrackingFileSystem()
        let store = LibraryStore(
            persistence: Wave3StubPersistence(
                applications: [fixture.application]
            ),
            launcher: Wave3NoopLauncher(),
            fileSystem: fileSystem,
            settings: try makeSettings()
        )
        let profileURL = try store.managedPaths(
            for: fixture.application,
            profile: fixture.profile
        ).profileRoot.url

        XCTAssertTrue(
            store.clearProfileData(
                for: fixture.application,
                profile: fixture.profile
            )
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: profileURL.path))
        XCTAssertFalse(fileSystem.events.contains("create"))
        XCTAssertTrue(store.launchStatusMessage?.localizedCaseInsensitiveContains("no data") == true)
        XCTAssertNil(store.errorMessage)
    }

    private func makeApplicationFixture(
        displayName: String = "Wave 3 Fixture"
    ) -> (application: ManagedApplication, profile: LaunchProfile) {
        let profile = LaunchProfile(name: "Personal")
        let application = ManagedApplication(
            displayName: displayName,
            appPath: "/Applications/\(displayName).app",
            preset: .custom,
            baseStoragePath: temporaryDirectory.path,
            profiles: [profile]
        )
        return (application, profile)
    }

    private func makeApplicationBundle(named name: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(
            "\(name).app",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    @MainActor
    private func makeSettings() throws -> AppSettings {
        let userDefaults = try XCTUnwrap(userDefaults)
        let settings = AppSettings(userDefaults: userDefaults)
        settings.defaultBaseStoragePath = temporaryDirectory.path
        return settings
    }

    @MainActor
    private func assertRetainedProfileFilesystemMutationsAreBlocked(
        libraryBytes: Data
    ) throws {
        _ = try writePrimaryLibrary(libraryBytes)
        let fixture = makeApplicationFixture()
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: temporaryDirectory
            ),
            launcher: Wave3NoopLauncher(),
            settings: try makeSettings()
        )
        let source = try store.managedPaths(
            for: fixture.application,
            profile: fixture.profile
        ).profileRoot.url
        try FileManager.default.createDirectory(
            at: source,
            withIntermediateDirectories: true
        )
        let sentinel = source.appendingPathComponent("sentinel")
        try Data("preserve".utf8).write(to: sentinel)
        let destination = fixture.profile.duplicatedWithFreshIdentity(
            name: "Retained Copy"
        )
        let destinationURL = try store.managedPaths(
            for: fixture.application,
            profile: destination
        ).profileRoot.url

        XCTAssertFalse(
            store.clearProfileData(
                for: fixture.application,
                profile: fixture.profile
            )
        )
        XCTAssertFalse(
            store.duplicateProfileData(
                from: fixture.profile,
                to: destination,
                application: fixture.application
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("preserve".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: destinationURL.path)
        )
        XCTAssertEqual(
            try Data(
                contentsOf: temporaryDirectory
                    .appendingPathComponent("Parallax")
                    .appendingPathComponent("library.json")
            ),
            libraryBytes
        )
    }

    private func writePrimaryLibrary(_ bytes: Data) throws -> URL {
        let directory = temporaryDirectory
            .appendingPathComponent("Parallax", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent(
            "library.json",
            isDirectory: false
        )
        try bytes.write(to: url)
        return url
    }
}

private enum Wave3InjectedError: LocalizedError {
    case save
    case filesystem

    var errorDescription: String? {
        switch self {
        case .save:
            "Injected Wave 3 save failure"
        case .filesystem:
            "Injected Wave 3 filesystem failure"
        }
    }
}

private final class Wave3StubPersistence: LibraryPersisting {
    private(set) var saveCallCount = 0
    private(set) var savedApplications: [[ManagedApplication]] = []

    private let applications: [ManagedApplication]
    private let saveError: (any Error)?
    private let trace: Wave3EventTrace?

    init(
        applications: [ManagedApplication],
        saveError: (any Error)? = nil,
        trace: Wave3EventTrace? = nil
    ) {
        self.applications = applications
        self.saveError = saveError
        self.trace = trace
    }

    func load() throws -> [ManagedApplication] {
        applications
    }

    func save(_ applications: [ManagedApplication]) throws {
        saveCallCount += 1
        savedApplications.append(applications)
        trace?.append("persistence.save")
        if let saveError {
            throw saveError
        }
    }
}

private struct Wave3NoopLauncher: ApplicationLaunching {
    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, any Error>) -> Void
    ) throws {}
}

private final class Wave3EventTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var events: [String] {
        lock.withLock { storage }
    }

    func append(_ event: String) {
        lock.withLock {
            storage.append(event)
        }
    }
}

private final class Wave3URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: URL?

    var value: URL? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

private final class Wave3TrackingFileSystem: FileSystem, @unchecked Sendable {
    enum Failure {
        case create
        case move
        case remove
    }

    private let local = LocalFileSystem()
    private let lock = NSLock()
    private var eventStorage: [String] = []
    private let trace: Wave3EventTrace?

    var failure: Failure?
    var beforeCopy: (@Sendable (URL, URL) throws -> Void)?

    init(trace: Wave3EventTrace? = nil) {
        self.trace = trace
    }

    var events: [String] {
        lock.withLock { eventStorage }
    }

    func fileExists(at url: URL) -> Bool {
        local.fileExists(at: url)
    }

    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes {
        try local.attributesOfItem(at: url)
    }

    func canonicalURL(for url: URL) throws -> URL {
        try local.canonicalURL(for: url)
    }

    func createDirectory(
        at url: URL,
        withIntermediateDirectories: Bool
    ) throws {
        record("create")
        if failure == .create {
            throw Wave3InjectedError.filesystem
        }
        try local.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        record("copy")
        trace?.append("fs.copy")
        try beforeCopy?(sourceURL, destinationURL)
        try local.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        record("move")
        if failure == .move {
            throw Wave3InjectedError.filesystem
        }
        try local.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        record("remove")
        if failure == .remove {
            throw Wave3InjectedError.filesystem
        }
        try local.removeItem(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try local.contentsOfDirectory(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try local.readData(at: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try local.writeData(data, to: url)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try local.writeDataAtomically(data, to: url)
    }

    func replaceItem(
        at destinationURL: URL,
        withItemAt sourceURL: URL
    ) throws {
        try local.replaceItem(
            at: destinationURL,
            withItemAt: sourceURL
        )
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        try local.setPOSIXPermissions(permissions, at: url)
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        try local.destinationOfSymbolicLink(at: url)
    }

    func synchronize(at url: URL) throws {
        try local.synchronize(at: url)
    }

    func applicationSupportURL(create: Bool) throws -> URL {
        try local.applicationSupportURL(create: create)
    }

    private func record(_ event: String) {
        lock.withLock {
            eventStorage.append(event)
        }
    }
}
