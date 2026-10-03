import Foundation
import XCTest
@testable import Parallax

final class LibraryMigrationAuditRegressionTests: XCTestCase {
    private var workspaces: [MigrationFixtureWorkspace] = []

    override func tearDownWithError() throws {
        workspaces.forEach { $0.remove() }
        workspaces.removeAll()
    }

    func testRetryAfterSourceChangedReplansWithJournaledIDs() throws {
        let workspace = try workspace()
        let original = try workspace.installFixture(named: "valid-v1-library.json")
        let sentinel = try XCTUnwrap(workspace.materializeLegacySources().keys.first)
        let changed = Data("updated-legacy-profile".utf8)
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        fileSystem.afterOperation = { event in
            if event.operation == .copyItem, event.firstURL?.lastPathComponent == "Personal" {
                try changed.write(to: sentinel)
            }
        }
        XCTAssertThrowsError(try coordinator(workspace, fileSystem: fileSystem).migrateIfNeeded()) {
            XCTAssertEqual($0 as? LibraryMigrationError, .sourceChanged)
        }
        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), original)
        let journal = try savedJournal(workspace)

        let outcome = try coordinator(workspace).migrateIfNeeded()
        guard case let .migrated(applications, receipt) = outcome else {
            return XCTFail("Expected retry to migrate the fresh source")
        }
        XCTAssertEqual(receipt.migrationID, journal.migrationID)
        XCTAssertEqual(applications.first?.storageID, journal.applicationMappings.first?.applicationStorageID)
        XCTAssertEqual(applications.first?.profiles.first?.storageID, journal.mappings.first?.profileStorageID)
        let mapping = try XCTUnwrap(receipt.mappings.first)
        XCTAssertNotEqual(mapping.sourceManifestSHA256, journal.mappings.first?.sourceManifestSHA256)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: mapping.newCanonicalPath)
            .appendingPathComponent(sentinel.lastPathComponent)), changed)
        XCTAssertEqual(try Data(contentsOf: sentinel), changed)
    }

    func testChangedSourceWithRemainingDestinationStillFailsClosed() throws {
        let workspace = try workspace()
        let original = try workspace.installFixture(named: "valid-v1-library.json")
        let sentinel = try XCTUnwrap(workspace.materializeLegacySources().keys.first)
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        fileSystem.afterOperation = { event in
            if event.operation == .moveItem,
                event.secondURL?.deletingLastPathComponent().lastPathComponent == "Profiles"
            {
                try Data("source changed after publication".utf8).write(to: sentinel)
                throw CocoaError(.fileWriteUnknown)
            }
        }
        fileSystem.beforeOperation = { event in
            if event.operation == .removeItem || event.operation == .moveItem,
                event.firstURL?.deletingLastPathComponent().lastPathComponent == "Profiles"
            {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        XCTAssertThrowsError(try coordinator(workspace, fileSystem: fileSystem).migrateIfNeeded())
        let journal = try savedJournal(workspace)
        let destination = URL(fileURLWithPath: try XCTUnwrap(journal.mappings.first?.newCanonicalPath))
        let before = try workspace.allRegularFileBytes(under: destination)
        XCTAssertFalse(before.isEmpty)
        XCTAssertThrowsError(try coordinator(workspace).migrateIfNeeded()) {
            XCTAssertEqual($0 as? LibraryMigrationError, .invalidJournal)
        }
        XCTAssertEqual(try workspace.allRegularFileBytes(under: destination), before)
        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), original)
    }

    func testReceiptTemporaryFileDoesNotBlockRetryWithAdvancingClock() throws {
        let workspace = try workspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        fileSystem.afterOperation = { event in
            if event.operation == .writeData,
                event.firstURL?.lastPathComponent == ".receipt.pending.json.pending"
            {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        XCTAssertThrowsError(try coordinator(workspace, fileSystem: fileSystem, time: 100).migrateIfNeeded())
        let outcome = try coordinator(workspace, time: 200).migrateIfNeeded()
        guard case let .migrated(_, receipt) = outcome else {
            return XCTFail("A stale receipt temporary must not block a later attempt")
        }
        XCTAssertEqual(receipt.completedAt, Date(timeIntervalSince1970: 200))
        let paths = workspace.assertableStateURLs(migrationID: receipt.migrationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.directory
            .appendingPathComponent(".receipt.pending.json.pending").path))
    }

    func testAbandonedUnjournaledControlDirectoriesAndFinderMetadataDoNotBlockMigration() throws {
        let workspace = try workspace()
        let original = try workspace.installFixture(named: "valid-v1-library.json")
        for contents in [[], ["library-v1.backup.json", ".journal.json.pending"], [".library-v1.backup.json.pending"]] {
            let directory = workspace.migrationDirectory(migrationID: UUID())
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in contents {
                try original.write(to: directory.appendingPathComponent(name))
            }
        }
        let finder = workspace.parallaxURL.appendingPathComponent("Migrations/.DS_Store")
        try Data("Finder metadata".utf8).write(to: finder)
        guard case .migrated = try coordinator(workspace).migrateIfNeeded() else {
            return XCTFail("Unjournaled control files are abandoned before any profile publication")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: finder.path))
    }

    func testUnjournaledDirectoryWithUnknownPayloadIsPreserved() throws {
        let workspace = try workspace()
        let original = try workspace.installFixture(named: "valid-v1-library.json")
        let directory = workspace.migrationDirectory(migrationID: UUID())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let payload = directory.appendingPathComponent("unknown-data")
        try original.write(to: payload)
        XCTAssertThrowsError(try coordinator(workspace).migrateIfNeeded())
        XCTAssertEqual(try Data(contentsOf: payload), original)
        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), original)
    }

    func testEmptyApplicationWithMissingConfiguredRootMigratesWithoutCreatingRoot() throws {
        let workspace = try workspace()
        let missing = workspace.rootURL.appendingPathComponent("MissingVolume")
        _ = try workspace.installFixture(named: "valid-v1-library.json") { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
            applications[0]["baseStoragePath"] = missing.path
            applications[0]["profiles"] = []
            document["applications"] = applications
            object = document
        }
        guard case let .migrated(applications, _) = try coordinator(workspace).migrateIfNeeded() else {
            return XCTFail("An application without profiles has no missing data to protect")
        }
        XCTAssertEqual(applications.first?.baseStoragePath, missing.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testLazilyCreatedHistoricalDefaultRootMigratesWithoutCreatingProfileData() throws {
        let workspace = try workspace()
        let historicalDefault = workspace.parallaxURL.appendingPathComponent("Profiles")
        _ = try workspace.installFixture(named: "valid-v1-library.json") { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
            applications[0]["baseStoragePath"] = historicalDefault.path
            document["applications"] = applications
            object = document
        }
        guard case let .migrated(applications, receipt) = try coordinator(workspace).migrateIfNeeded() else {
            return XCTFail("The legacy default Profiles directory was created lazily")
        }
        XCTAssertEqual(applications.first?.baseStoragePath, historicalDefault.path)
        XCTAssertEqual(receipt.mappings.first?.disposition, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: historicalDefault.path))
    }

    func testEscapedApostropheInGeneratedArgumentIsRewrittenAsOneToken() throws {
        let workspace = try workspace()
        let base = workspace.rootURL.appendingPathComponent("Owner's Profiles")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let oldPath = base.appendingPathComponent("Fixture-Browser/Personal/UserData").path
        let escaped = oldPath.replacingOccurrences(of: "'", with: "'\\''")
        _ = try workspace.installFixture(named: "valid-v1-library.json") { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
            applications[0]["baseStoragePath"] = base.path
            var profiles = try XCTUnwrap(applications[0]["profiles"] as? [[String: Any]])
            profiles[0]["argumentsText"] = "--before  --user-data-dir='\(escaped)'\n--after='keep me'"
            applications[0]["profiles"] = profiles
            document["applications"] = applications
            object = document
        }
        guard case let .migrated(applications, receipt) = try coordinator(workspace).migrateIfNeeded() else {
            return XCTFail("Expected migration")
        }
        let profile = try XCTUnwrap(applications.first?.profiles.first)
        let mapping = try XCTUnwrap(receipt.mappings.first)
        XCTAssertEqual(mapping.isolationConfiguration, .generated)
        XCTAssertEqual(ShellWordsParser.parse(profile.argumentsText), [
            "--before", "--user-data-dir=\(mapping.newCanonicalPath)/UserData", "--after=keep me"
        ])
        XCTAssertTrue(profile.argumentsText.hasPrefix("--before  "))
        XCTAssertTrue(profile.argumentsText.hasSuffix("\n--after='keep me'"))
    }

    func testCommittedFinalizationIgnoresNonmatchingJournalAndStrayFile() throws {
        let workspace = try workspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let fileSystem = MigrationOccurrenceFailingFileSystem(
            failureRule: .init(.replaceItem, occurrence: 1, timing: .after)
        )
        XCTAssertThrowsError(try coordinator(workspace, fileSystem: fileSystem).migrateIfNeeded())
        let journal = try savedJournal(workspace)
        let paths = workspace.assertableStateURLs(migrationID: journal.migrationID)
        var unrelated = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: paths.journal)) as? [String: Any])
        let unrelatedID = UUID()
        unrelated["migrationID"] = unrelatedID.uuidString.lowercased()
        unrelated["targetSHA256"] = String(repeating: "0", count: 64)
        let directory = workspace.migrationDirectory(migrationID: unrelatedID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: unrelated).write(to: directory.appendingPathComponent("journal.json"))
        try Data().write(to: directory.deletingLastPathComponent().appendingPathComponent(".DS_Store"))

        XCTAssertNoThrow(try coordinator(workspace).migrateIfNeeded())
        let applications = try LibraryPersistence(applicationSupportURL: workspace.applicationSupportURL).load()
        XCTAssertEqual(applications.first?.storageID, journal.applicationMappings.first?.applicationStorageID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.receipt.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingReceipt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("journal.json").path))
    }

    func testPeerMigrationLoadIsBusyAndDoesNotCreateCopiesWhileLockIsHeld() throws {
        let workspace = try workspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let peerFileSystem = MigrationOccurrenceFailingFileSystem()
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        fileSystem.afterOperation = { event in
            guard event.operation == .copyItem, event.occurrence == 1 else { return }
            XCTAssertThrowsError(try LibraryPersistence(fileSystem: peerFileSystem,
                applicationSupportURL: workspace.applicationSupportURL).load()) {
                XCTAssertTrue($0 is LibraryOperationInProgressError)
            }
        }
        _ = try LibraryPersistence(fileSystem: fileSystem, applicationSupportURL: workspace.applicationSupportURL).load()
        XCTAssertEqual(peerFileSystem.occurrenceCount(of: .copyItem), 0)
        XCTAssertEqual(try coordinator(workspace).allIncompleteJournals().count, 0)
    }

    private func workspace() throws -> MigrationFixtureWorkspace {
        let result = try MigrationFixtureWorkspace()
        workspaces.append(result)
        return result
    }

    private func coordinator(_ workspace: MigrationFixtureWorkspace,
        fileSystem: any FileSystem = LocalFileSystem(), time: TimeInterval = 100
    ) -> LibraryMigrationCoordinator {
        LibraryMigrationCoordinator(fileSystem: fileSystem,
            applicationSupportURL: workspace.applicationSupportURL,
            now: { Date(timeIntervalSince1970: time) })
    }

    private func savedJournal(_ workspace: MigrationFixtureWorkspace) throws -> LibraryMigrationCoordinator.MigrationJournal {
        try XCTUnwrap(coordinator(workspace).allIncompleteJournals().first)
    }
}

extension LibraryMigrationAuditRegressionTests {
    func testAuditMigratedProfilesKeepLegacyUnknownOwnership() throws {
        let workspace = try workspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        guard case .migrated(let applications, _) = try coordinator(workspace).migrateIfNeeded() else { return XCTFail("Expected migration") }
        let profiles = applications.flatMap(\.profiles)
        XCTAssertFalse(profiles.isEmpty)
        XCTAssertTrue(profiles.allSatisfy { $0.isolationOwnership == .legacyUnknown })
    }
}
