import Foundation
import XCTest
@testable import Parallax

final class LibraryMigrationHardeningTests: XCTestCase {
    private var workspaces: [MigrationFixtureWorkspace] = []

    override func tearDownWithError() throws {
        workspaces.forEach { $0.remove() }
        workspaces.removeAll()
    }

    func testMigrationCleanupNeverRemovesAnotherTransactionNamespace() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let foreignRoot = workspace.managedRootURL
            .appendingPathComponent(".parallax/Transactions", isDirectory: true)
            .appendingPathComponent("foreign-transaction", isDirectory: true)
        try FileManager.default.createDirectory(
            at: foreignRoot,
            withIntermediateDirectories: true
        )
        let foreignSentinel = foreignRoot.appendingPathComponent("foreign.sentinel")
        let foreignBytes = Data("belongs-to-another-transaction".utf8)
        try foreignBytes.write(to: foreignSentinel)

        _ = try coordinator(
            workspace: workspace,
            uuids: ids(suffix: 1)
        ).migrateIfNeeded()

        XCTAssertEqual(try Data(contentsOf: foreignSentinel), foreignBytes)
    }

    func testRecoveryRejectsPrimaryThatMatchesNeitherJournalHash() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let failingFileSystem = MigrationOccurrenceFailingFileSystem(
            failureRule: .init(.copyItem, occurrence: 2, timing: .after)
        )

        XCTAssertThrowsError(
            try coordinator(
                workspace: workspace,
                fileSystem: failingFileSystem,
                uuids: ids(suffix: 2)
            ).migrateIfNeeded()
        )
        let unrelatedApplications = [
            ManagedApplication(
                displayName: "Unrelated Writer",
                appPath: "/Applications/Unrelated.app"
            )
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(
            LibraryDocument(applications: unrelatedApplications)
        ).write(to: workspace.libraryURL, options: .atomic)

        XCTAssertThrowsError(
            try coordinator(
                workspace: workspace,
                uuids: ids(suffix: 22)
            ).migrateIfNeeded()
        ) { error in
            XCTAssertEqual(error as? LibraryMigrationError, .recoveryConflict)
        }
        XCTAssertEqual(
            try LibraryPersistence.decodeApplications(
                from: Data(contentsOf: workspace.libraryURL)
            ),
            unrelatedApplications
        )
    }

    func testRollbackNeverDeletesPublishedDestinationChangedAfterPublication() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let deterministic = ids(suffix: 3)
        let applicationStorageID = deterministic[1]
        let profileStorageID = deterministic[2]
        let destination = workspace.managedRootURL
            .appendingPathComponent(".parallax/Applications", isDirectory: true)
            .appendingPathComponent(
                applicationStorageID.uuidString.lowercased(),
                isDirectory: true
            )
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(
                profileStorageID.uuidString.lowercased(),
                isDirectory: true
            )
        let changedSentinel = destination.appendingPathComponent("changed-after-publish")
        let changedBytes = Data("must-not-be-rolled-back".utf8)
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        fileSystem.afterOperation = { event in
            guard
                event.operation == .moveItem,
                event.secondURL?.standardizedFileURL == destination.standardizedFileURL
            else {
                return
            }
            try changedBytes.write(to: changedSentinel)
            throw MigrationHardeningInjectedError.stopAfterPublication
        }

        XCTAssertThrowsError(
            try coordinator(
                workspace: workspace,
                fileSystem: fileSystem,
                uuids: deterministic
            ).migrateIfNeeded()
        )

        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: changedSentinel), changedBytes)
    }

    func testMissingSameNameApplicationRootsDoNotCreateFalseAmbiguity() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json") { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
            var duplicate = applications[0]
            duplicate["id"] = "11111111-1111-4111-8111-111111111112"
            var profiles = try XCTUnwrap(duplicate["profiles"] as? [[String: Any]])
            profiles[0]["id"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"
            profiles[0]["storageName"] = "Other"
            duplicate["profiles"] = profiles
            applications.append(duplicate)
            document["applications"] = applications
            object = document
        }

        let outcome = try coordinator(
            workspace: workspace,
            uuids: extendedIDs(suffix: 4)
        ).migrateIfNeeded()
        let applications = try migratedApplications(from: outcome)

        XCTAssertEqual(applications.count, 2)
        XCTAssertTrue(applications.allSatisfy { $0.profiles.count == 1 })
    }

    func testMissingCaseVariantProfilePathsDoNotCreateFalseAmbiguity() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "case-variant-storage-names.json")

        let outcome = try coordinator(
            workspace: workspace,
            uuids: extendedIDs(suffix: 5)
        ).migrateIfNeeded()
        let applications = try migratedApplications(from: outcome)

        XCTAssertEqual(applications.first?.profiles.count, 2)
    }

    func testMissingConfiguredBaseRootPausesInsteadOfTreatingDisconnectedDataAsMissing() throws {
        let workspace = try makeWorkspace()
        let unavailableRoot = workspace.rootURL.appendingPathComponent(
            "UnavailableManagedVolume",
            isDirectory: true
        )
        let originalBytes = try workspace.installFixture(
            named: "valid-v1-library.json"
        ) { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
            applications[0]["baseStoragePath"] = unavailableRoot.path
            document["applications"] = applications
            object = document
        }
        let fileSystem = MigrationOccurrenceFailingFileSystem()

        let outcome = try coordinator(
            workspace: workspace,
            fileSystem: fileSystem,
            uuids: ids(suffix: 55)
        ).migrateIfNeeded()
        guard case let .requiresResolution(plan) = outcome else {
            return XCTFail("A missing configured base may be a disconnected volume.")
        }

        XCTAssertTrue(plan.blockers.contains { $0.kind == .invalidBaseStorageRoot })
        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
        XCTAssertFalse(
            fileSystem.events.contains {
                [
                    .createDirectory,
                    .copyItem,
                    .moveItem,
                    .removeItem,
                    .writeData,
                    .writeDataAtomically,
                    .replaceItem,
                    .setPermissions,
                    .synchronize,
                ].contains($0.operation)
            }
        )
    }

    func testAmbiguousDuplicateIsolationOptionsRemainByteForByte() throws {
        let workspace = try makeWorkspace()
        let legacyRoot = workspace.managedRootURL
            .appendingPathComponent("Fixture-Browser/Personal", isDirectory: true)
        let userData = legacyRoot.appendingPathComponent("UserData").path
        let codexHome = legacyRoot.appendingPathComponent("CodexHome").path
        let arguments =
            "--user-data-dir=\(userData) --opaque=\(userData) "
            + "--user-data-dir=\(userData)"
        let environment =
            "CODEX_HOME=\(codexHome)\nUNCHANGED=\(codexHome)\n"
            + "CODEX_HOME=\(codexHome)"
        _ = try workspace.installFixture(named: "valid-v1-library.json") { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
            var profiles = try XCTUnwrap(applications[0]["profiles"] as? [[String: Any]])
            profiles[0]["argumentsText"] = arguments
            profiles[0]["environmentText"] = environment
            applications[0]["profiles"] = profiles
            document["applications"] = applications
            object = document
        }
        _ = try workspace.materializeLegacySources()

        let applications = try migratedApplications(
            from: coordinator(
                workspace: workspace,
                uuids: ids(suffix: 6)
            ).migrateIfNeeded()
        )
        let profile = try XCTUnwrap(applications.first?.profiles.first)

        XCTAssertEqual(profile.argumentsText, arguments)
        XCTAssertEqual(profile.environmentText, environment)
    }

    private func makeWorkspace() throws -> MigrationFixtureWorkspace {
        let workspace = try MigrationFixtureWorkspace()
        workspaces.append(workspace)
        return workspace
    }

    private func coordinator(
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

    private func ids(suffix: Int) -> [UUID] {
        [1, 2, 3].compactMap { prefix in
            UUID(
                uuidString: String(
                    format: "%d5000000-0000-4000-8000-%012x",
                    prefix,
                    suffix
                )
            )
        }
    }

    private func extendedIDs(suffix: Int) -> [UUID] {
        [1, 2, 3, 4, 5, 6, 7, 8].compactMap { prefix in
            UUID(
                uuidString: String(
                    format: "%d6000000-0000-4000-8000-%012x",
                    prefix,
                    suffix
                )
            )
        }
    }
}

private enum MigrationHardeningInjectedError: Error {
    case stopAfterPublication
}
