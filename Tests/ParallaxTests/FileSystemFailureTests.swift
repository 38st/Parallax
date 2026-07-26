import Foundation
import XCTest
@testable import Parallax

final class FileSystemFailureTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Parallax-BASE-001-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    @MainActor
    func testArchiveMoveFailureKeepsProfileMetadataAndSelection() throws {
        let fixture = makeFixture()
        try FileManager.default.createDirectory(
            at: fixture.profileURL,
            withIntermediateDirectories: true
        )
        let fileSystem = FailureInjectingFileSystem(
            failing: .moveItem,
            failure: .permissionDenied
        )
        let persistence = StubLibraryPersistence(applications: [fixture.application])
        let store = LibraryStore(
            persistence: persistence,
            launcher: NoopLauncher(),
            fileSystem: fileSystem
        )

        XCTAssertFalse(store.remove(profile: fixture.profile, dataRemoval: .archive))

        XCTAssertEqual(store.applications.first?.profiles, [fixture.profile])
        XCTAssertEqual(store.selectedProfileID, fixture.profile.id)
        XCTAssertEqual(persistence.saveCallCount, 0)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.launchStatusMessage)
    }

    @MainActor
    func testPostCommitDeleteFailureRequiresRecoveryWithoutRestoringStaleMetadata() throws {
        let fixture = makeFixture()
        try FileManager.default.createDirectory(
            at: fixture.profileURL,
            withIntermediateDirectories: true
        )
        let fileSystem = FailureInjectingFileSystem(
            failing: .removeItem,
            failure: .permissionDenied
        )
        let persistence = StubLibraryPersistence(applications: [fixture.application])
        let store = LibraryStore(
            persistence: persistence,
            launcher: NoopLauncher(),
            fileSystem: fileSystem
        )

        XCTAssertFalse(store.remove(profile: fixture.profile, dataRemoval: .delete))

        XCTAssertEqual(store.applications.first?.profiles, [])
        XCTAssertNil(store.selectedProfileID)
        XCTAssertEqual(persistence.saveCallCount, 1)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.launchStatusMessage)
        guard case .recoveryRequired = store.loadState else {
            return XCTFail("Expected recovery after committed metadata could not finish purging data")
        }
    }

    @MainActor
    func testClearOfMissingDataDoesNotCreateDirectories() {
        let fixture = makeFixture()
        let fileSystem = FailureInjectingFileSystem(
            failing: .createDirectory,
            failure: .diskFull
        )
        let store = LibraryStore(
            persistence: StubLibraryPersistence(applications: [fixture.application]),
            launcher: NoopLauncher(),
            fileSystem: fileSystem
        )

        XCTAssertTrue(
            store.clearProfileData(
                for: fixture.application,
                profile: fixture.profile
            )
        )

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.launchStatusMessage, "No data exists to clear for Work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.profileURL.path))
    }

    @MainActor
    func testCopyFailureAfterPartialDestinationCreationIsReported() throws {
        let fixture = makeFixture()
        try FileManager.default.createDirectory(
            at: fixture.profileURL,
            withIntermediateDirectories: true
        )
        let fileSystem = FailureInjectingFileSystem(
            failing: .copyItem,
            failure: .copyInterrupted,
            createsPartialCopyBeforeFailure: true
        )
        let persistence = StubLibraryPersistence(applications: [fixture.application])
        let store = LibraryStore(
            persistence: persistence,
            launcher: NoopLauncher(),
            fileSystem: fileSystem
        )

        XCTAssertFalse(store.duplicateSelectedProfile())

        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.launchStatusMessage)
        XCTAssertTrue(fileSystem.didCreatePartialCopy)
        let profileDirectories = try FileManager.default.contentsOfDirectory(
            at: fixture.profileURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent)
        XCTAssertEqual(profileDirectories.count, 2)
        XCTAssertTrue(
            profileDirectories.contains(
                fixture.profile.storageID.uuidString.lowercased()
            )
        )
        XCTAssertEqual(store.applications.first?.profiles, [fixture.profile])
        XCTAssertEqual(store.selectedProfileID, fixture.profile.id)
        XCTAssertEqual(persistence.saveCallCount, 0)
        guard case .recoveryRequired = store.loadState else {
            return XCTFail("Expected recovery when a partial copy cannot be ownership-verified")
        }
    }

    func testPersistenceSaveFailureBeforeTemporaryWritePropagates() throws {
        let fileSystem = FailureInjectingFileSystem(
            failing: .createDirectory,
            failure: .diskFull
        )
        let persistence = LibraryPersistence(
            fileSystem: fileSystem,
            applicationSupportURL: temporaryDirectory
        )

        XCTAssertThrowsError(try persistence.save([]))
        XCTAssertEqual(fileSystem.operations, [.createDirectory])
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: temporaryDirectory
                    .appendingPathComponent("Parallax/library.json", isDirectory: false)
                    .path
            )
        )
    }

    func testPersistenceSaveFailureAfterTemporaryWritePreservesOriginal() throws {
        let original = makeFixture().application
        let productionPersistence = LibraryPersistence(applicationSupportURL: temporaryDirectory)
        try productionPersistence.save([original])
        let primaryURL = temporaryDirectory
            .appendingPathComponent("Parallax/library.json", isDirectory: false)
        let originalData = try Data(contentsOf: primaryURL)
        let fileSystem = FailureInjectingFileSystem(
            failing: .replaceItem,
            failure: .permissionDenied
        )
        let failingPersistence = LibraryPersistence(
            fileSystem: fileSystem,
            applicationSupportURL: temporaryDirectory
        )
        let replacement = ManagedApplication(
            displayName: "Replacement",
            appPath: "/Applications/Replacement.app"
        )

        XCTAssertThrowsError(try failingPersistence.save([replacement]))

        XCTAssertEqual(try Data(contentsOf: primaryURL), originalData)
        XCTAssertTrue(fileSystem.operations.contains(.writeData))
        XCTAssertTrue(fileSystem.operations.contains(.replaceItem))
        XCTAssertLessThan(
            try XCTUnwrap(fileSystem.operations.firstIndex(of: .writeData)),
            try XCTUnwrap(fileSystem.operations.firstIndex(of: .replaceItem))
        )
        let temporaryFiles = try FileManager.default.contentsOfDirectory(
            at: primaryURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".library.json.")
                && $0.pathExtension == "tmp"
        }
        XCTAssertTrue(temporaryFiles.isEmpty)
    }

    @MainActor
    func testDuplicateSaveFailurePreservesUnverifiedDataForRecovery() {
        let fixture = makeFixture()
        let persistence = StubLibraryPersistence(
            applications: [fixture.application],
            saveError: InjectedFailure.save
        )
        let fileSystem = FailureInjectingFileSystem()
        let store = LibraryStore(
            persistence: persistence,
            launcher: NoopLauncher(),
            fileSystem: fileSystem
        )

        XCTAssertFalse(store.duplicateSelectedProfile())

        XCTAssertEqual(persistence.saveCallCount, 1)
        XCTAssertTrue(fileSystem.operations.contains(.createDirectory))
        XCTAssertEqual(store.applications.first?.profiles, [fixture.profile])
        XCTAssertEqual(store.selectedProfileID, fixture.profile.id)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.launchStatusMessage)
        guard case .recoveryRequired = store.loadState else {
            return XCTFail("Expected recovery when copied data cannot be ownership-verified")
        }
    }

    @MainActor
    func testStoreReportsSaveFailureAfterArchiveMutation() throws {
        let fixture = makeFixture()
        try FileManager.default.createDirectory(
            at: fixture.profileURL,
            withIntermediateDirectories: true
        )
        let trace = TestEventTrace()
        let fileSystem = FailureInjectingFileSystem(trace: trace)
        let persistence = StubLibraryPersistence(
            applications: [fixture.application],
            saveError: InjectedFailure.save,
            trace: trace
        )
        let store = LibraryStore(
            persistence: persistence,
            launcher: NoopLauncher(),
            fileSystem: fileSystem
        )

        XCTAssertFalse(store.remove(profile: fixture.profile, dataRemoval: .archive))

        XCTAssertEqual(
            trace.events.filter { $0 == "fs.moveItem" || $0 == "persistence.save" },
            ["fs.moveItem", "persistence.save", "fs.moveItem"]
        )
        XCTAssertEqual(store.applications.first?.profiles, [fixture.profile])
        XCTAssertEqual(store.selectedProfileID, fixture.profile.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.profileURL.path))
        let archiveURL = try store.managedPaths(
            for: fixture.application,
            profile: fixture.profile
        ).archiveRoot.url
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: archiveURL,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
        XCTAssertNotNil(store.errorMessage)
        XCTAssertNil(store.launchStatusMessage)
    }

    @MainActor
    func testCapturedManagedPathRejectsBaseRootReplacementBeforeMutation() throws {
        let fixture = makeFixture()
        try FileManager.default.createDirectory(
            at: fixture.profileURL,
            withIntermediateDirectories: true
        )
        let fileSystem = FailureInjectingFileSystem()
        let store = LibraryStore(
            persistence: StubLibraryPersistence(applications: [fixture.application]),
            launcher: NoopLauncher(),
            fileSystem: fileSystem
        )
        let capturedPaths = try store.managedPaths(
            for: fixture.application,
            profile: fixture.profile
        )
        try FileManager.default.removeItem(at: temporaryDirectory)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try ManagedPathResolver(fileSystem: fileSystem)
                .revalidateForMutation(capturedPaths.profileRoot)
        )
        XCTAssertFalse(fileSystem.operations.contains(.createDirectory))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.profileURL.path))
    }

    @MainActor
    func testClearRejectsSymlinkEscapeIntroducedAfterResolution() throws {
        let fixture = makeFixture()
        try FileManager.default.createDirectory(
            at: fixture.profileURL,
            withIntermediateDirectories: true
        )
        let outside = temporaryDirectory.deletingLastPathComponent()
            .appendingPathComponent(
                "Parallax-BASE-001-outside-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let fileSystem = FailureInjectingFileSystem()
        let store = LibraryStore(
            persistence: StubLibraryPersistence(applications: [fixture.application]),
            launcher: NoopLauncher(),
            fileSystem: fileSystem
        )
        var insertedSymlink = false
        fileSystem.beforeOperation = { operation in
            guard operation == .canonicalize, !insertedSymlink else { return }
            insertedSymlink = true
            try? FileManager.default.removeItem(
                at: self.temporaryDirectory.appendingPathComponent(".parallax")
            )
            try? FileManager.default.createSymbolicLink(
                at: self.temporaryDirectory.appendingPathComponent(".parallax"),
                withDestinationURL: outside
            )
        }

        XCTAssertFalse(
            store.clearProfileData(
                for: fixture.application,
                profile: fixture.profile
            )
        )

        XCTAssertTrue(insertedSymlink)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(fileSystem.operations.contains(.createDirectory))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: outside,
                includingPropertiesForKeys: nil
            ).isEmpty
        )
    }

    @MainActor
    func testClearRejectsRegularFileAtManagedProfileTarget() throws {
        let fixture = makeFixture()
        try FileManager.default.createDirectory(
            at: fixture.profileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sentinel = Data("managed-file-sentinel".utf8)
        try sentinel.write(to: fixture.profileURL)
        let fileSystem = FailureInjectingFileSystem()
        let store = LibraryStore(
            persistence: StubLibraryPersistence(applications: [fixture.application]),
            launcher: NoopLauncher(),
            fileSystem: fileSystem
        )

        XCTAssertFalse(
            store.clearProfileData(
                for: fixture.application,
                profile: fixture.profile
            )
        )

        XCTAssertEqual(try Data(contentsOf: fixture.profileURL), sentinel)
        XCTAssertFalse(fileSystem.operations.contains(.removeItem))
        XCTAssertFalse(fileSystem.operations.contains(.moveItem))
    }

    @MainActor
    func testClearNeverMutatesExplicitExternalIsolationDirectories() throws {
        let externalCodexHome = temporaryDirectory
            .appendingPathComponent("External Codex Home", isDirectory: true)
        let externalUserData = temporaryDirectory
            .appendingPathComponent("External User Data", isDirectory: true)
        try FileManager.default.createDirectory(
            at: externalCodexHome,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: externalUserData,
            withIntermediateDirectories: true
        )
        let codexSentinel = externalCodexHome.appendingPathComponent("account-state")
        let browserSentinel = externalUserData.appendingPathComponent("browser-state")
        try Data("codex".utf8).write(to: codexSentinel)
        try Data("browser".utf8).write(to: browserSentinel)
        let profile = LaunchProfile(
            name: "External",
            argumentsText: "--user-data-dir=\(ShellWordsParser.quote(externalUserData.path))",
            environmentText: "CODEX_HOME=\(externalCodexHome.path)"
        )
        let application = ManagedApplication(
            displayName: "Codex",
            appPath: "/Applications/Codex.app",
            preset: .codex,
            baseStoragePath: temporaryDirectory.path,
            profiles: [profile]
        )
        let store = LibraryStore(
            persistence: StubLibraryPersistence(applications: [application]),
            launcher: NoopLauncher(),
            fileSystem: FailureInjectingFileSystem()
        )

        XCTAssertTrue(store.clearProfileData(for: application, profile: profile))

        XCTAssertEqual(try Data(contentsOf: codexSentinel), Data("codex".utf8))
        XCTAssertEqual(try Data(contentsOf: browserSentinel), Data("browser".utf8))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: try store.managedPaths(
                    for: application,
                    profile: profile
                ).profileRoot.url.path
            )
        )
        XCTAssertEqual(store.launchStatusMessage, "No data exists to clear for External")
    }

    func testFilesystemCanFailASpecificOperationOccurrence() throws {
        let fileSystem = FailureInjectingFileSystem(
            failing: .createDirectory,
            failure: .diskFull,
            failureOccurrence: 2
        )
        let first = temporaryDirectory.appendingPathComponent("first", isDirectory: true)
        let second = temporaryDirectory.appendingPathComponent("second", isDirectory: true)

        XCTAssertNoThrow(
            try fileSystem.createDirectory(
                at: first,
                withIntermediateDirectories: true
            )
        )
        XCTAssertThrowsError(
            try fileSystem.createDirectory(
                at: second,
                withIntermediateDirectories: true
            )
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
        XCTAssertEqual(
            fileSystem.operations.filter { $0 == .createDirectory }.count,
            2
        )
    }

    func testFilesystemDelayGateCanPauseAnOperationDeterministically() throws {
        let fileSystem = FailureInjectingFileSystem()
        let destination = temporaryDirectory.appendingPathComponent(
            "delayed",
            isDirectory: true
        )
        let operationBegan = DispatchSemaphore(value: 0)
        let allowOperation = DispatchSemaphore(value: 0)
        let operationFinished = DispatchSemaphore(value: 0)
        fileSystem.delayGate = { operation in
            guard operation == .createDirectory else { return }
            operationBegan.signal()
            _ = allowOperation.wait(timeout: .now() + 2)
        }

        DispatchQueue.global().async {
            try? fileSystem.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
            operationFinished.signal()
        }

        XCTAssertEqual(operationBegan.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        allowOperation.signal()
        XCTAssertEqual(operationFinished.wait(timeout: .now() + 1), .success)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    private func makeFixture() -> (
        application: ManagedApplication,
        profile: LaunchProfile,
        profileURL: URL
    ) {
        let profile = LaunchProfile(name: "Work")
        let application = ManagedApplication(
            displayName: "Fixture",
            appPath: "/Applications/Fixture.app",
            preset: .custom,
            baseStoragePath: temporaryDirectory.path,
            profiles: [profile]
        )
        let profileURL = temporaryDirectory
            .appendingPathComponent(".parallax", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(application.storageID.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(profile.storageID.uuidString.lowercased(), isDirectory: true)
        return (application, profile, profileURL)
    }
}

private enum InjectedFailure: LocalizedError, Sendable {
    case permissionDenied
    case diskFull
    case copyInterrupted
    case save

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Injected permission failure"
        case .diskFull:
            "Injected disk-full failure"
        case .copyInterrupted:
            "Injected copy interruption"
        case .save:
            "Injected persistence save failure"
        }
    }
}

private struct NoopLauncher: ApplicationLaunching {
    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        completion(.success(()))
    }
}

private final class StubLibraryPersistence: LibraryPersisting {
    var applications: [ManagedApplication]
    var saveError: Error?
    var beforeSave: (() -> Void)?
    private let trace: TestEventTrace?
    private(set) var saveCallCount = 0

    init(
        applications: [ManagedApplication],
        saveError: Error? = nil,
        trace: TestEventTrace? = nil
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
        trace?.append("persistence.save")
        beforeSave?()
        if let saveError {
            throw saveError
        }
        self.applications = applications
    }
}

private final class FailureInjectingFileSystem: FileSystem, @unchecked Sendable {
    enum Operation: String, Equatable, Sendable {
        case fileExists
        case attributes
        case canonicalize
        case createDirectory
        case copyItem
        case moveItem
        case removeItem
        case contents
        case readData
        case writeData
        case writeDataAtomically
        case replaceItem
        case setPermissions
        case symlinkDestination
        case synchronize
        case applicationSupportURL
    }

    private let underlying = LocalFileSystem()
    private let failingOperation: Operation?
    private let injectedFailure: InjectedFailure
    private let failureOccurrence: Int
    private let createsPartialCopyBeforeFailure: Bool
    private let trace: TestEventTrace?
    var beforeOperation: ((Operation) -> Void)?
    var delayGate: ((Operation) -> Void)?
    private(set) var operations: [Operation] = []
    private(set) var didCreatePartialCopy = false

    init(
        failing: Operation? = nil,
        failure: InjectedFailure = .permissionDenied,
        failureOccurrence: Int = 1,
        createsPartialCopyBeforeFailure: Bool = false,
        trace: TestEventTrace? = nil
    ) {
        self.failingOperation = failing
        self.injectedFailure = failure
        self.failureOccurrence = failureOccurrence
        self.createsPartialCopyBeforeFailure = createsPartialCopyBeforeFailure
        self.trace = trace
    }

    func fileExists(at url: URL) -> Bool {
        record(.fileExists)
        return underlying.fileExists(at: url)
    }

    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes {
        try recordThrowing(.attributes)
        return try underlying.attributesOfItem(at: url)
    }

    func canonicalURL(for url: URL) throws -> URL {
        try recordThrowing(.canonicalize)
        return try underlying.canonicalURL(for: url)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try recordThrowing(.createDirectory)
        try underlying.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        record(.copyItem)
        if shouldFail(.copyItem) {
            if createsPartialCopyBeforeFailure {
                didCreatePartialCopy = true
                try underlying.createDirectory(
                    at: destinationURL,
                    withIntermediateDirectories: true
                )
                try Data("partial".utf8).write(
                    to: destinationURL.appendingPathComponent("partial-copy")
                )
            }
            throw injectedFailure
        }
        try underlying.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        try recordThrowing(.moveItem)
        try underlying.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try recordThrowing(.removeItem)
        try underlying.removeItem(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try recordThrowing(.contents)
        return try underlying.contentsOfDirectory(at: url)
    }

    func readData(at url: URL) throws -> Data {
        try recordThrowing(.readData)
        return try underlying.readData(at: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        try recordThrowing(.writeData)
        try underlying.writeData(data, to: url)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try recordThrowing(.writeDataAtomically)
        try underlying.writeDataAtomically(data, to: url)
    }

    func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
        try recordThrowing(.replaceItem)
        try underlying.replaceItem(at: destinationURL, withItemAt: sourceURL)
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        try recordThrowing(.setPermissions)
        try underlying.setPOSIXPermissions(permissions, at: url)
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        try recordThrowing(.symlinkDestination)
        return try underlying.destinationOfSymbolicLink(at: url)
    }

    func synchronize(at url: URL) throws {
        try recordThrowing(.synchronize)
        try underlying.synchronize(at: url)
    }

    func applicationSupportURL(create: Bool) throws -> URL {
        try recordThrowing(.applicationSupportURL)
        return try underlying.applicationSupportURL(create: create)
    }

    private func record(_ operation: Operation) {
        operations.append(operation)
        trace?.append("fs.\(operation.rawValue)")
        beforeOperation?(operation)
        delayGate?(operation)
    }

    private func recordThrowing(_ operation: Operation) throws {
        record(operation)
        if shouldFail(operation) {
            throw injectedFailure
        }
    }

    private func shouldFail(_ operation: Operation) -> Bool {
        guard failingOperation == operation else { return false }
        return operations.filter { $0 == operation }.count == failureOccurrence
    }
}

private final class TestEventTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []

    var events: [String] {
        lock.withLock { storedEvents }
    }

    func append(_ event: String) {
        lock.withLock {
            storedEvents.append(event)
        }
    }
}
