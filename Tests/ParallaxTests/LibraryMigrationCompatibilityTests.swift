import Foundation
import XCTest
@testable import Parallax

final class LibraryMigrationCompatibilityTests: XCTestCase {
    private var workspaces: [MigrationFixtureWorkspace] = []

    override func tearDownWithError() throws {
        workspaces.forEach { $0.remove() }
        workspaces.removeAll()
    }

    func testOrdinaryPersistenceLoadRunsSafeMigrationBeforeReturningWritableData() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let persistence = LibraryPersistence(
            fileSystem: LocalFileSystem(),
            applicationSupportURL: workspace.applicationSupportURL
        )

        guard case let .current(applications) = try persistence.loadResult() else {
            return XCTFail("A blocker-free v1 library should migrate during ordinary load.")
        }

        XCTAssertEqual(applications.count, 1)
        XCTAssertNotEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
        XCTAssertEqual(
            try LibraryPersistence.decodeApplications(
                from: Data(contentsOf: workspace.libraryURL)
            ),
            applications
        )
    }

    func testReceiptProvenanceAndControlPermissionsAreCompleteAndRestrictive() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let migrationID = try XCTUnwrap(
            UUID(uuidString: "15000000-0000-4000-8000-000000000007")
        )
        let outcome = try coordinator(
            workspace: workspace,
            uuids: [
                migrationID,
                UUID(uuidString: "25000000-0000-4000-8000-000000000007"),
                UUID(uuidString: "35000000-0000-4000-8000-000000000007"),
            ].compactMap { $0 }
        ).migrateIfNeeded()
        guard case let .migrated(_, receipt) = outcome else {
            return XCTFail("Expected completed migration.")
        }
        let paths = workspace.assertableStateURLs(migrationID: migrationID)

        XCTAssertEqual(receipt.sourceFormat, "versioned-v1")
        XCTAssertEqual(receipt.sourceByteCount, originalBytes.count)
        XCTAssertEqual(receipt.backupRelativePath, "library-v1.backup.json")
        XCTAssertEqual(receipt.legacyDataRetention, "retainedInPlace")
        XCTAssertEqual(receipt.applicationMappings.count, 1)
        XCTAssertEqual(receipt.mappings.count, 1)
        XCTAssertEqual(try Data(contentsOf: paths.backup), originalBytes)

        for directory in [
            workspace.parallaxURL.appendingPathComponent(
                "Migrations",
                isDirectory: true
            ),
            paths.directory,
        ] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.path
            )
            XCTAssertEqual(
                (attributes[.posixPermissions] as? NSNumber)?.intValue,
                0o700
            )
        }
        for file in [paths.backup, paths.journal, paths.receipt] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: file.path
            )
            XCTAssertEqual(
                (attributes[.posixPermissions] as? NSNumber)?.intValue,
                0o600
            )
        }
    }

    func testExplicitExternalIsolationConfigurationIsPreservedByteForByte() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "external-isolation-paths.json")
        let legacy = try legacyLibrary(in: workspace)
        let legacyProfile = try XCTUnwrap(legacy.applications.first?.profiles.first)
        _ = try workspace.materializeLegacySources()
        let externalSentinels = try workspace.materializeExternalIsolationSentinels()

        let outcome = try coordinator(
            workspace: workspace,
            uuids: deterministicIDs(suffix: 1)
        ).migrateIfNeeded()
        let applications = try applications(from: outcome)
        let profile = try XCTUnwrap(applications.first?.profiles.first)

        XCTAssertEqual(profile.argumentsText, legacyProfile.argumentsText)
        XCTAssertEqual(profile.environmentText, legacyProfile.environmentText)
        for (url, bytes) in externalSentinels {
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }

        let receipt = try completedReceiptData(in: workspace)
        let receiptText = try XCTUnwrap(String(data: receipt, encoding: .utf8))
        XCTAssertFalse(receiptText.contains(workspace.externalRootURL.path))
        XCTAssertTrue(receiptText.contains("external"))
    }

    func testExactGeneratedCodexHomeAndUserDataPathsRewriteToV2ManagedPaths() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json") { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
            applications[0]["preset"] = "codex"
            var profiles = try XCTUnwrap(applications[0]["profiles"] as? [[String: Any]])
            let legacyProfileRoot = workspace.managedRootURL
                .appendingPathComponent("Fixture-Browser", isDirectory: true)
                .appendingPathComponent("Personal", isDirectory: true)
            profiles[0]["argumentsText"] =
                "--user-data-dir=\(legacyProfileRoot.appendingPathComponent("UserData").path)"
            profiles[0]["environmentText"] =
                "CODEX_HOME=\(legacyProfileRoot.appendingPathComponent("CodexHome").path)"
            applications[0]["profiles"] = profiles
            document["applications"] = applications
            object = document
        }
        _ = try workspace.materializeLegacySources()

        let applications = try applications(
            from: coordinator(
                workspace: workspace,
                uuids: deterministicIDs(suffix: 2)
            ).migrateIfNeeded()
        )
        let application = try XCTUnwrap(applications.first)
        let profile = try XCTUnwrap(application.profiles.first)
        let profileRoot = v2ProfileURL(
            workspace: workspace,
            application: application,
            profile: profile
        )

        XCTAssertEqual(
            profile.argumentsText,
            "--user-data-dir=\(profileRoot.appendingPathComponent("UserData").path)"
        )
        XCTAssertEqual(
            profile.environmentText,
            "CODEX_HOME=\(profileRoot.appendingPathComponent("CodexHome").path)"
        )
    }

    func testDuplicateLegacyLogicalIDsAreRepairedForEveryOccurrence() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "duplicate-profile-ids.json")
        _ = try workspace.materializeLegacySources()
        let duplicatedID = try XCTUnwrap(
            UUID(uuidString: "acacacac-acac-4cac-8cac-acacacacaca1")
        )

        let applications = try applications(
            from: coordinator(
                workspace: workspace,
                uuids: [
                    UUID(uuidString: "13000000-0000-4000-8000-000000000003"),
                    UUID(uuidString: "23000000-0000-4000-8000-000000000003"),
                    UUID(uuidString: "33000000-0000-4000-8000-000000000003"),
                    UUID(uuidString: "33000000-0000-4000-8000-000000000004"),
                    UUID(uuidString: "43000000-0000-4000-8000-000000000003"),
                    UUID(uuidString: "43000000-0000-4000-8000-000000000004"),
                ].compactMap { $0 }
            ).migrateIfNeeded()
        )
        let profiles = try XCTUnwrap(applications.first?.profiles)

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(Set(profiles.map(\.id)).count, 2)
        XCTAssertEqual(Set(profiles.map(\.storageID)).count, 2)
        XCTAssertFalse(profiles.contains { $0.id == duplicatedID })
    }

    func testMigrationPreservesSymlinkObjectsWithoutFollowingTheirTargets() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        let sources = try workspace.materializeLegacySources()
        let sourceFile = try XCTUnwrap(sources.keys.first)
        let sourceRoot = sourceFile.deletingLastPathComponent()
        let externalTarget = workspace.externalRootURL.appendingPathComponent("target")
        let externalBytes = Data("external-target-must-not-be-copied".utf8)
        try externalBytes.write(to: externalTarget)
        let sourceLink = sourceRoot.appendingPathComponent("external-link")
        try FileManager.default.createSymbolicLink(
            at: sourceLink,
            withDestinationURL: externalTarget
        )

        let applications = try applications(
            from: coordinator(
                workspace: workspace,
                uuids: deterministicIDs(suffix: 4)
            ).migrateIfNeeded()
        )
        let application = try XCTUnwrap(applications.first)
        let profile = try XCTUnwrap(application.profiles.first)
        let destinationLink = v2ProfileURL(
            workspace: workspace,
            application: application,
            profile: profile
        ).appendingPathComponent("external-link")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: destinationLink.path
        )

        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: destinationLink.path
            ),
            externalTarget.path
        )
        XCTAssertEqual(try Data(contentsOf: externalTarget), externalBytes)
    }

    private func makeWorkspace() throws -> MigrationFixtureWorkspace {
        let workspace = try MigrationFixtureWorkspace()
        workspaces.append(workspace)
        return workspace
    }

    private func coordinator(
        workspace: MigrationFixtureWorkspace,
        uuids: [UUID]
    ) -> LibraryMigrationCoordinator {
        let sequence = DeterministicUUIDSequence(uuids)
        return LibraryMigrationCoordinator(
            fileSystem: LocalFileSystem(),
            applicationSupportURL: workspace.applicationSupportURL,
            uuidGenerator: sequence.next,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    private func applications(
        from outcome: LibraryMigrationOutcome
    ) throws -> [ManagedApplication] {
        switch outcome {
        case let .migrated(applications, _), let .current(applications):
            return applications
        case .requiresResolution:
            throw MigrationTestSupportError.missingLegacyProfile
        }
    }

    private func legacyLibrary(
        in workspace: MigrationFixtureWorkspace
    ) throws -> LegacyLibrary {
        guard case let .legacy(snapshot) = try LibraryPersistence(
            applicationSupportURL: workspace.applicationSupportURL
        ).loadSnapshot() else {
            throw MigrationTestSupportError.missingLegacyProfile
        }
        return snapshot.library
    }

    private func completedReceiptData(
        in workspace: MigrationFixtureWorkspace
    ) throws -> Data {
        let migrationRoot = workspace.parallaxURL.appendingPathComponent(
            "Migrations",
            isDirectory: true
        )
        let migrationDirectories = try FileManager.default.contentsOfDirectory(
            at: migrationRoot,
            includingPropertiesForKeys: nil
        )
        let receiptURL = try XCTUnwrap(migrationDirectories.first)
            .appendingPathComponent("receipt.json")
        return try Data(contentsOf: receiptURL)
    }

    private func v2ProfileURL(
        workspace: MigrationFixtureWorkspace,
        application: ManagedApplication,
        profile: LaunchProfile
    ) -> URL {
        workspace.managedRootURL
            .appendingPathComponent(".parallax/Applications", isDirectory: true)
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

    private func deterministicIDs(suffix: Int) -> [UUID] {
        [
            UUID(
                uuidString: String(
                    format: "14000000-0000-4000-8000-%012x",
                    suffix
                )
            ),
            UUID(
                uuidString: String(
                    format: "24000000-0000-4000-8000-%012x",
                    suffix
                )
            ),
            UUID(
                uuidString: String(
                    format: "34000000-0000-4000-8000-%012x",
                    suffix
                )
            ),
        ].compactMap { $0 }
    }
}
