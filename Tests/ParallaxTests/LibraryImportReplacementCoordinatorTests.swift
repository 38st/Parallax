import Foundation
import XCTest
@testable import Parallax

final class LibraryImportReplacementCoordinatorTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Import-Replacement-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testPreviewReportsCountsAndValidationWarningsWithoutWriting() throws {
        let fixture = try makeFixture()
        let before = try Data(contentsOf: fixture.primaryURL)
        var warningApplications = fixture.importedApplications
        warningApplications[0].displayName = "Same Name"
        warningApplications[1].displayName = "same name"

        let preview = try fixture.coordinator.preview(
            importData: try importData(warningApplications)
        )

        XCTAssertEqual(preview.applicationCount, 2)
        XCTAssertEqual(preview.profileCount, 3)
        XCTAssertFalse(preview.validationWarnings.isEmpty)
        XCTAssertTrue(
            preview.validationWarnings.allSatisfy {
                $0.code
                    == LibraryImportIssueCode.normalizedNameCollision.rawValue
                    && !$0.path.isEmpty
                    && !$0.message.isEmpty
            }
        )
        XCTAssertEqual(try Data(contentsOf: fixture.primaryURL), before)
        XCTAssertTrue(
            try fixture.backupStore.inspectArtifacts(kind: .backup).isEmpty
        )
    }

    func testValidationErrorsCannotProduceReplacementPreviewOrBackup() throws {
        let fixture = try makeFixture()

        XCTAssertThrowsError(
            try fixture.coordinator.preview(importData: Data("{".utf8))
        ) { error in
            XCTAssertEqual(
                (error as? LibraryImportReplacementError)?.code,
                .validationFailed
            )
        }
        XCTAssertTrue(
            try fixture.backupStore.inspectArtifacts(kind: .backup).isEmpty
        )
        XCTAssertEqual(
            try loadedApplications(fixture.repository),
            fixture.originalApplications
        )
    }

    func testReplaceCreatesVerifiedUndoBackupAndPreservesProfileData() throws {
        let fixture = try makeFixture()
        let priorBytes = try Data(contentsOf: fixture.primaryURL)
        let preview = try fixture.coordinator.preview(
            importData: try importData(fixture.importedApplications)
        )

        let result = try fixture.coordinator.replace(using: preview)

        XCTAssertEqual(
            try loadedApplications(fixture.repository),
            fixture.importedApplications
        )
        XCTAssertEqual(result.snapshot.applications, fixture.importedApplications)
        XCTAssertEqual(result.backup.reason.rawValue, "importReplacement")
        XCTAssertEqual(
            try fixture.backupStore.prepareRestore(from: result.backup).bytes,
            priorBytes
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.profileSentinelURL),
            "profile-data"
        )

        let undo = try fixture.coordinator.prepareUndo(
            for: result,
            replacing: fixture.primaryURL
        )
        XCTAssertEqual(undo.restore.bytes, priorBytes)
        XCTAssertNotNil(undo.preservedPrimary)
        XCTAssertEqual(
            try String(contentsOf: fixture.profileSentinelURL),
            "profile-data"
        )

        let undone = try fixture.coordinator.undo(replacement: result)
        XCTAssertEqual(
            undone.snapshot.applications,
            fixture.originalApplications
        )
        XCTAssertGreaterThan(
            undone.snapshot.versionToken.revision,
            result.snapshot.versionToken.revision
        )
        XCTAssertEqual(
            try loadedApplications(fixture.repository),
            fixture.originalApplications
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.profileSentinelURL),
            "profile-data"
        )
    }

    func testUndoIsVersionBoundAndNeverOverwritesLaterWriter() throws {
        let fixture = try makeFixture()
        let preview = try fixture.coordinator.preview(
            importData: try importData(fixture.importedApplications)
        )
        let replacement = try fixture.coordinator.replace(using: preview)
        var later = fixture.importedApplications
        later[0].displayName = "Later writer"
        _ = try fixture.repository.save(
            later,
            expectedVersion: replacement.snapshot.versionToken
        )

        XCTAssertThrowsError(
            try fixture.coordinator.undo(replacement: replacement)
        ) { error in
            XCTAssertEqual(
                (error as? LibraryImportReplacementError)?.code,
                .undoNoLongerValid
            )
        }
        XCTAssertEqual(
            try loadedApplications(fixture.repository),
            later
        )
    }

    func testBackupFailureLeavesActiveLibraryByteForByteUnchanged() throws {
        let fixture = try makeFixture(invalidRecoveryRoot: true)
        let priorBytes = try Data(contentsOf: fixture.primaryURL)
        let preview = try fixture.coordinator.preview(
            importData: try importData(fixture.importedApplications)
        )

        XCTAssertThrowsError(
            try fixture.coordinator.replace(using: preview)
        )

        XCTAssertEqual(try Data(contentsOf: fixture.primaryURL), priorBytes)
        XCTAssertEqual(
            try loadedApplications(fixture.repository),
            fixture.originalApplications
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.profileSentinelURL),
            "profile-data"
        )
    }

    func testPersistenceFailureBeforeReplaceLeavesActiveLibraryUnchanged() throws {
        let fileSystem = ImportReplacementFailingFileSystem()
        let fixture = try makeFixture(repositoryFileSystem: fileSystem)
        let priorBytes = try Data(contentsOf: fixture.primaryURL)
        let preview = try fixture.coordinator.preview(
            importData: try importData(fixture.importedApplications)
        )
        fileSystem.replaceBehavior = .throwBeforeReplace

        XCTAssertThrowsError(
            try fixture.coordinator.replace(using: preview)
        )

        XCTAssertEqual(try Data(contentsOf: fixture.primaryURL), priorBytes)
        XCTAssertEqual(
            try loadedApplications(fixture.repository),
            fixture.originalApplications
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.profileSentinelURL),
            "profile-data"
        )
    }

    func testPostReplaceFailureRollsBackLogicalLibraryBeforeReportingFailure() throws {
        let fileSystem = ImportReplacementFailingFileSystem()
        let fixture = try makeFixture(repositoryFileSystem: fileSystem)
        let preview = try fixture.coordinator.preview(
            importData: try importData(fixture.importedApplications)
        )
        fileSystem.replaceBehavior = .replaceThenThrow

        XCTAssertThrowsError(
            try fixture.coordinator.replace(using: preview)
        ) { error in
            XCTAssertEqual(
                (error as? LibraryImportReplacementError)?.code,
                .replacementFailedAndRolledBack
            )
        }

        XCTAssertEqual(
            try loadedApplications(fixture.repository),
            fixture.originalApplications
        )
        XCTAssertEqual(
            try String(contentsOf: fixture.profileSentinelURL),
            "profile-data"
        )
    }

    func testStalePreviewNeverOverwritesCompetingWriter() throws {
        let fixture = try makeFixture()
        let preview = try fixture.coordinator.preview(
            importData: try importData(fixture.importedApplications)
        )
        var competing = fixture.originalApplications
        competing[0].displayName = "Competing writer"
        let current = try loadedSnapshot(fixture.repository)
        _ = try fixture.repository.save(
            competing,
            expectedVersion: current.versionToken
        )

        XCTAssertThrowsError(
            try fixture.coordinator.replace(using: preview)
        ) { error in
            guard case LibraryRepositoryError.staleWriter = error else {
                return XCTFail("Expected stale writer, got \(error)")
            }
        }

        XCTAssertEqual(try loadedApplications(fixture.repository), competing)
        XCTAssertEqual(
            try String(contentsOf: fixture.profileSentinelURL),
            "profile-data"
        )
    }

    func testPreviewBoundToImportSessionRejectsNewRepositoryVersion()
        throws
    {
        let fixture = try makeFixture()
        let reviewedVersion = try loadedSnapshot(
            fixture.repository
        ).versionToken
        var competing = fixture.originalApplications
        competing[0].displayName = "Competing writer"
        _ = try fixture.repository.save(
            competing,
            expectedVersion: reviewedVersion
        )

        XCTAssertThrowsError(
            try fixture.coordinator.preview(
                importData: try importData(
                    fixture.importedApplications
                ),
                expectedVersion: reviewedVersion
            )
        )
        XCTAssertEqual(
            try loadedApplications(fixture.repository),
            competing
        )
        XCTAssertTrue(
            try fixture.backupStore.inspectArtifacts(kind: .backup)
                .isEmpty
        )
    }

    private func makeFixture(
        invalidRecoveryRoot: Bool = false,
        repositoryFileSystem: ImportReplacementFailingFileSystem? = nil
    ) throws -> ImportReplacementFixture {
        let applicationSupportURL = temporaryDirectory.appendingPathComponent(
            "ApplicationSupport",
            isDirectory: true
        )
        let primaryURL = applicationSupportURL
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
        let managedRoot = temporaryDirectory.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        let originalProfile = LaunchProfile(name: "Original")
        let originalApplication = ManagedApplication(
            displayName: "Original App",
            appPath: "/Applications/Original.app",
            baseStoragePath: managedRoot.path,
            profiles: [originalProfile]
        )
        let importedApplications = [
            ManagedApplication(
                displayName: "Imported One",
                appPath: "/Applications/Imported One.app",
                profiles: [
                    LaunchProfile(name: "One"),
                    LaunchProfile(name: "Two"),
                ]
            ),
            ManagedApplication(
                displayName: "Imported Two",
                appPath: "/Applications/Imported Two.app",
                profiles: [LaunchProfile(name: "Three")]
            ),
        ]
        let fileSystem = repositoryFileSystem ?? ImportReplacementFailingFileSystem()
        let repository = LibraryRepository(
            fileSystem: fileSystem,
            applicationSupportURL: applicationSupportURL
        )
        _ = try repository.save(
            [originalApplication],
            expectedVersion: .missing
        )

        let profileSentinelURL = managedRoot
            .appendingPathComponent(".parallax/Applications", isDirectory: true)
            .appendingPathComponent(
                originalApplication.storageID.uuidString.lowercased(),
                isDirectory: true
            )
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(
                originalProfile.storageID.uuidString.lowercased(),
                isDirectory: true
            )
            .appendingPathComponent("sentinel.txt", isDirectory: false)
        try FileManager.default.createDirectory(
            at: profileSentinelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("profile-data".utf8).write(to: profileSentinelURL)

        let recoveryRoot = temporaryDirectory.appendingPathComponent(
            "Recovery",
            isDirectory: true
        )
        if invalidRecoveryRoot {
            try Data("not-a-directory".utf8).write(to: recoveryRoot)
        }
        let backupStore = LibraryBackupStore(
            recoveryRoot: recoveryRoot
        )
        return ImportReplacementFixture(
            coordinator: LibraryImportReplacementCoordinator(
                repository: repository,
                backupStore: backupStore
            ),
            repository: repository,
            backupStore: backupStore,
            primaryURL: primaryURL,
            profileSentinelURL: profileSentinelURL,
            originalApplications: [originalApplication],
            importedApplications: importedApplications
        )
    }

    private func loadedApplications(
        _ repository: LibraryRepository
    ) throws -> [ManagedApplication] {
        try loadedSnapshot(repository).applications
    }

    private func loadedSnapshot(
        _ repository: LibraryRepository
    ) throws -> LibraryRepositorySnapshot {
        guard case let .loaded(snapshot) = repository.load() else {
            throw ImportReplacementTestError.unexpectedRepositoryState
        }
        return snapshot
    }

    private func importData(
        _ applications: [ManagedApplication]
    ) throws -> Data {
        try JSONEncoder().encode(
            LibraryDocument(applications: applications)
        )
    }
}

private struct ImportReplacementFixture {
    let coordinator: LibraryImportReplacementCoordinator
    let repository: LibraryRepository
    let backupStore: LibraryBackupStore
    let primaryURL: URL
    let profileSentinelURL: URL
    let originalApplications: [ManagedApplication]
    let importedApplications: [ManagedApplication]
}

private enum ImportReplacementTestError: Error {
    case injected
    case unexpectedRepositoryState
}

private final class ImportReplacementFailingFileSystem:
    FileSystem,
    @unchecked Sendable
{
    enum ReplaceBehavior {
        case normal
        case throwBeforeReplace
        case replaceThenThrow
    }

    private let underlying = LocalFileSystem()
    private let lock = NSLock()
    private var storedReplaceBehavior = ReplaceBehavior.normal

    var replaceBehavior: ReplaceBehavior {
        get { lock.withLock { storedReplaceBehavior } }
        set { lock.withLock { storedReplaceBehavior = newValue } }
    }

    func fileExists(at url: URL) -> Bool {
        underlying.fileExists(at: url)
    }

    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes {
        try underlying.attributesOfItem(at: url)
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
            withIntermediateDirectories: withIntermediateDirectories
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
        try underlying.readData(at: url)
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
        let behavior = lock.withLock { () -> ReplaceBehavior in
            let value = storedReplaceBehavior
            storedReplaceBehavior = .normal
            return value
        }
        switch behavior {
        case .normal:
            try underlying.replaceItem(
                at: destinationURL,
                withItemAt: sourceURL
            )
        case .throwBeforeReplace:
            throw ImportReplacementTestError.injected
        case .replaceThenThrow:
            try underlying.replaceItem(
                at: destinationURL,
                withItemAt: sourceURL
            )
            throw ImportReplacementTestError.injected
        }
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        try underlying.setPOSIXPermissions(permissions, at: url)
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        try underlying.destinationOfSymbolicLink(at: url)
    }

    func synchronize(at url: URL) throws {
        try underlying.synchronize(at: url)
    }

    func applicationSupportURL(create: Bool) throws -> URL {
        try underlying.applicationSupportURL(create: create)
    }
}
