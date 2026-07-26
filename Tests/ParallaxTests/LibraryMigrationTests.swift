import Foundation
import XCTest
@testable import Parallax

final class LibraryMigrationTests: XCTestCase {
    private var workspaces: [MigrationFixtureWorkspace] = []

    override func tearDownWithError() throws {
        workspaces.forEach { $0.remove() }
        workspaces.removeAll()
    }

    func testCleanV1MigrationCopiesDataRewritesOnlyGeneratedPathsAndRetainsSource() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(named: "valid-v1-library.json")
        let legacySentinels = try workspace.materializeLegacySources()
        let migrationID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-4000-8000-000000000001")
        )
        let coordinator = makeCoordinator(
            workspace: workspace,
            uuids: [
                migrationID,
                UUID(uuidString: "20000000-0000-4000-8000-000000000001"),
                UUID(uuidString: "30000000-0000-4000-8000-000000000001")
            ].compactMap { $0 }
        )

        let outcome = try coordinator.migrateIfNeeded()
        let applications = try migratedApplications(from: outcome)
        let application = try XCTUnwrap(applications.first)
        let profile = try XCTUnwrap(application.profiles.first)
        let destination = v2ProfileURL(
            workspace: workspace,
            application: application,
            profile: profile
        )
        let copiedSentinel = destination.appendingPathComponent(
            "fixture-\(profile.id.uuidString.lowercased()).sentinel"
        )

        XCTAssertEqual(LibraryDocument.currentVersion, 2)
        XCTAssertEqual(try Data(contentsOf: copiedSentinel), legacySentinels.values.first)
        XCTAssertEqual(application.baseStoragePath, workspace.managedRootURL.path)
        XCTAssertEqual(
            profile.argumentsText,
            "--user-data-dir=\(destination.appendingPathComponent("UserData").path)"
        )
        XCTAssertEqual(profile.environmentText, "")
        XCTAssertEqual(profile.notes, "Stable v1 fixture")
        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL).first, Character("{").asciiValue)
        XCTAssertNotEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)

        for (source, bytes) in legacySentinels {
            XCTAssertEqual(
                try Data(contentsOf: source),
                bytes,
                "Successful migration must retain every legacy source byte-for-byte."
            )
        }
    }

    func testRawArrayMigrationProducesV2WithoutAlteringOriginalBackupBytes() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(named: "legacy-raw-array.json")
        _ = try workspace.materializeLegacySources()
        let migrationID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-4000-8000-000000000002")
        )
        let coordinator = makeCoordinator(
            workspace: workspace,
            uuids: [
                migrationID,
                UUID(uuidString: "20000000-0000-4000-8000-000000000002"),
                UUID(uuidString: "30000000-0000-4000-8000-000000000002")
            ].compactMap { $0 }
        )

        let applications = try migratedApplications(
            from: coordinator.migrateIfNeeded()
        )
        XCTAssertEqual(applications.count, 1)
        XCTAssertEqual(applications.first?.profiles.count, 1)

        let paths = workspace.assertableStateURLs(migrationID: migrationID)
        XCTAssertEqual(try Data(contentsOf: paths.backup), originalBytes)
        let decoded = try LibraryPersistence.decodeApplications(
            from: Data(contentsOf: workspace.libraryURL)
        )
        XCTAssertEqual(decoded, applications)
    }

    func testMigrationWritesExactBackupAndSecretFreeJournalAndReceiptWithCanonicalMappings() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(
            named: "valid-v1-library.json"
        ) { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
            var profiles = try XCTUnwrap(applications[0]["profiles"] as? [[String: Any]])
            profiles[0]["notes"] = "NOTE_SECRET_7f6d"
            profiles[0]["environmentText"] = "API_TOKEN=ENV_SECRET_93aa"
            profiles[0]["argumentsText"] =
                "--opaque=ARG_SECRET_251c --user-data-dir="
                + workspace.managedRootURL
                    .appendingPathComponent("Fixture-Browser/Personal/UserData")
                    .path
            applications[0]["profiles"] = profiles
            document["applications"] = applications
            object = document
        }
        _ = try workspace.materializeLegacySources()
        let migrationID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-4000-8000-000000000003")
        )
        let coordinator = makeCoordinator(
            workspace: workspace,
            uuids: [
                migrationID,
                UUID(uuidString: "20000000-0000-4000-8000-000000000003"),
                UUID(uuidString: "30000000-0000-4000-8000-000000000003")
            ].compactMap { $0 }
        )

        let applications = try migratedApplications(
            from: coordinator.migrateIfNeeded()
        )
        let application = try XCTUnwrap(applications.first)
        let profile = try XCTUnwrap(application.profiles.first)
        let legacySource = workspace.managedRootURL
            .appendingPathComponent("Fixture-Browser", isDirectory: true)
            .appendingPathComponent("Personal", isDirectory: true)
        let destination = v2ProfileURL(
            workspace: workspace,
            application: application,
            profile: profile
        )
        let paths = workspace.assertableStateURLs(migrationID: migrationID)

        XCTAssertEqual(try Data(contentsOf: paths.backup), originalBytes)
        for controlURL in [paths.journal, paths.receipt] {
            let data = try Data(contentsOf: controlURL)
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(text.contains("NOTE_SECRET_7f6d"))
            XCTAssertFalse(text.contains("ENV_SECRET_93aa"))
            XCTAssertFalse(text.contains("ARG_SECRET_251c"))
            XCTAssertFalse(text.contains("\"notes\""))
            XCTAssertFalse(text.contains("\"argumentsText\""))
            XCTAssertFalse(text.contains("\"environmentText\""))
            XCTAssertTrue(text.contains(legacySource.resolvingSymlinksInPath().path))
            XCTAssertTrue(text.contains(destination.resolvingSymlinksInPath().path))
            XCTAssertTrue(text.contains(application.id.uuidString.lowercased()))
            XCTAssertTrue(text.contains(profile.id.uuidString.lowercased()))
            XCTAssertTrue(text.contains(application.storageID.uuidString.lowercased()))
            XCTAssertTrue(text.contains(profile.storageID.uuidString.lowercased()))
            XCTAssertTrue(text.contains("retainedInPlace"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingReceipt.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.staging.path))
    }

    func testReservedArchivesAmbiguityRequiresResolutionWithZeroWrites() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(
            named: "reserved-archives-storage-name.json"
        )
        let sentinels = try workspace.materializeLegacySources()
        let originalManagedBytes = try workspace.allRegularFileBytes(
            under: workspace.managedRootURL
        )
        let coordinator = makeCoordinator(
            workspace: workspace,
            uuids: [
                UUID(uuidString: "10000000-0000-4000-8000-000000000004")
            ].compactMap { $0 }
        )

        let outcome = try coordinator.migrateIfNeeded()
        guard case let .requiresResolution(plan) = outcome else {
            return XCTFail("An existing legacy Archives source must pause migration.")
        }

        XCTAssertTrue(
            plan.blockers.contains { $0.kind == .reservedArchiveAmbiguity }
        )
        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
        XCTAssertEqual(
            try workspace.allRegularFileBytes(under: workspace.managedRootURL),
            originalManagedBytes
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.parallaxURL
                    .appendingPathComponent("Migrations", isDirectory: true)
                    .path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: workspace.managedRootURL
                    .appendingPathComponent(".parallax", isDirectory: true)
                    .path
            )
        )
        XCTAssertFalse(sentinels.isEmpty)
    }

    func testSuccessfulMigrationIsIdempotentAndSecondRunWritesNothing() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let firstCoordinator = makeCoordinator(
            workspace: workspace,
            uuids: [
                UUID(uuidString: "10000000-0000-4000-8000-000000000005"),
                UUID(uuidString: "20000000-0000-4000-8000-000000000005"),
                UUID(uuidString: "30000000-0000-4000-8000-000000000005")
            ].compactMap { $0 }
        )
        let firstApplications = try migratedApplications(
            from: firstCoordinator.migrateIfNeeded()
        )
        let beforeSecondRun = try workspace.allRegularFileBytes(
            under: workspace.rootURL
        )
        let recordingFileSystem = MigrationOccurrenceFailingFileSystem()
        let secondCoordinator = makeCoordinator(
            workspace: workspace,
            fileSystem: recordingFileSystem,
            uuids: [
                UUID(uuidString: "ffffffff-ffff-4fff-8fff-ffffffffffff")
            ].compactMap { $0 }
        )

        let secondOutcome = try secondCoordinator.migrateIfNeeded()
        guard case let .current(secondApplications) = secondOutcome else {
            return XCTFail("A completed v2 library must be an idempotent current result.")
        }

        XCTAssertEqual(secondApplications, firstApplications)
        XCTAssertEqual(
            try workspace.allRegularFileBytes(under: workspace.rootURL),
            beforeSecondRun
        )
        XCTAssertFalse(
            recordingFileSystem.events.contains {
                [.createDirectory, .copyItem, .moveItem, .removeItem, .writeData,
                 .writeDataAtomically, .replaceItem].contains($0.operation)
            }
        )
    }

    func testReplacementSucceededThenThrewResumesAndFinalizesWithoutRevertingV2() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        let sourceSentinels = try workspace.materializeLegacySources()
        let migrationID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-4000-8000-000000000006")
        )
        let failingFileSystem = MigrationOccurrenceFailingFileSystem(
            failureRule: .init(.replaceItem, occurrence: 1, timing: .after)
        )
        let failingCoordinator = makeCoordinator(
            workspace: workspace,
            fileSystem: failingFileSystem,
            uuids: [
                migrationID,
                UUID(uuidString: "20000000-0000-4000-8000-000000000006"),
                UUID(uuidString: "30000000-0000-4000-8000-000000000006")
            ].compactMap { $0 }
        )

        XCTAssertThrowsError(try failingCoordinator.migrateIfNeeded())
        let committedApplications = try LibraryPersistence.decodeApplications(
            from: Data(contentsOf: workspace.libraryURL)
        )
        XCTAssertEqual(committedApplications.count, 1)

        let recoveryCoordinator = makeCoordinator(
            workspace: workspace,
            uuids: [
                UUID(uuidString: "ffffffff-ffff-4fff-8fff-000000000006")
            ].compactMap { $0 }
        )
        let recoveryOutcome = try recoveryCoordinator.migrateIfNeeded()
        let recoveredApplications: [ManagedApplication]
        switch recoveryOutcome {
        case let .current(applications):
            recoveredApplications = applications
        case let .migrated(applications, _):
            recoveredApplications = applications
        case .requiresResolution:
            return XCTFail("A journaled committed v2 library must finalize automatically.")
        }

        XCTAssertEqual(recoveredApplications, committedApplications)
        let paths = workspace.assertableStateURLs(migrationID: migrationID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.receipt.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.journal.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.pendingReceipt.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.staging.path))
        for (source, bytes) in sourceSentinels {
            XCTAssertEqual(try Data(contentsOf: source), bytes)
        }
    }

    private func makeWorkspace() throws -> MigrationFixtureWorkspace {
        let workspace = try MigrationFixtureWorkspace()
        workspaces.append(workspace)
        return workspace
    }

    private func makeCoordinator(
        workspace: MigrationFixtureWorkspace,
        fileSystem: any FileSystem = LocalFileSystem(),
        uuids: [UUID]
    ) -> LibraryMigrationCoordinator {
        let sequence = DeterministicUUIDSequence(uuids)
        return LibraryMigrationCoordinator(
            fileSystem: fileSystem,
            applicationSupportURL: workspace.applicationSupportURL,
            uuidGenerator: sequence.next,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func migratedApplications(
        from outcome: LibraryMigrationOutcome
    ) throws -> [ManagedApplication] {
        guard case let .migrated(applications, _) = outcome else {
            throw MigrationTestSupportError.missingLegacyProfile
        }
        return applications
    }

    private func v2ProfileURL(
        workspace: MigrationFixtureWorkspace,
        application: ManagedApplication,
        profile: LaunchProfile
    ) -> URL {
        workspace.managedRootURL
            .appendingPathComponent(".parallax", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(
                application.storageID.uuidString.lowercased(),
                isDirectory: true
            )
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(
                profile.storageID.uuidString.lowercased(),
                isDirectory: true
            )
    }
}
