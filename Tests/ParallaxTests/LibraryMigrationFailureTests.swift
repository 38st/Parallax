import Foundation
import XCTest
@testable import Parallax

final class LibraryMigrationFailureTests: XCTestCase {
    private var workspaces: [MigrationFixtureWorkspace] = []

    override func tearDownWithError() throws {
        workspaces.forEach { $0.remove() }
        workspaces.removeAll()
    }

    func testLegacySnapshotsPreserveExactOriginalBytesHashAndFormat() throws {
        for (index, fixture) in ["valid-v1-library.json", "legacy-raw-array.json"].enumerated() {
            let workspace = try makeWorkspace()
            let originalBytes = try workspace.installFixture(named: fixture)
            let persistence = LibraryPersistence(
                applicationSupportURL: workspace.applicationSupportURL
            )

            let loaded = try persistence.loadSnapshot()
            guard case let .legacy(snapshot) = loaded else {
                XCTFail("Expected an exact legacy snapshot for \(fixture)")
                continue
            }

            XCTAssertEqual(snapshot.originalBytes, originalBytes)
            XCTAssertEqual(snapshot.sourceByteCount, originalBytes.count)
            XCTAssertEqual(snapshot.sourceSHA256.count, 64)
            XCTAssertTrue(snapshot.sourceSHA256.allSatisfy(\.isHexDigit))
            if index == 0 {
                XCTAssertEqual(snapshot.library.format, .versioned(1))
            } else {
                XCTAssertEqual(snapshot.library.format, .rawApplicationArray)
            }
        }
    }

    func testMissingLegacyFolderMigratesMetadataWithoutCreatingEmptyData() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        let migrationID = uuid("11000000-0000-4000-8000-000000000001")
        let outcome = try makeCoordinator(
            workspace: workspace,
            uuids: [
                migrationID,
                uuid("21000000-0000-4000-8000-000000000001"),
                uuid("31000000-0000-4000-8000-000000000001")
            ]
        ).migrateIfNeeded()
        let applications = try migratedApplications(from: outcome)
        let application = try XCTUnwrap(applications.first)
        let profile = try XCTUnwrap(application.profiles.first)
        let destination = v2ProfileURL(
            workspace: workspace,
            application: application,
            profile: profile
        )
        let receipt = workspace.assertableStateURLs(migrationID: migrationID).receipt
        let receiptText = try XCTUnwrap(
            String(data: Data(contentsOf: receipt), encoding: .utf8)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(receiptText.contains("missing"))
        XCTAssertTrue(receiptText.contains(destination.path))
    }

    func testBlockingFixtureMatrixPerformsNoWritesAndPreservesAllBytes() throws {
        let cases: [(fixture: String, blocker: LibraryMigrationBlocker.Kind)] = [
            ("reserved-archives-storage-name.json", .reservedArchiveAmbiguity),
            ("case-variant-storage-names.json", .caseInsensitiveSourceCollision),
            ("duplicate-storage-names.json", .canonicalSourceCollision),
            ("empty-storage-name.json", .unsafeLegacyStorageName),
            ("slash-containing-storage-name.json", .unsafeLegacyStorageName),
            ("traversing-storage-name.json", .unsafeLegacyStorageName)
        ]

        for (fixture, expectedBlocker) in cases {
            let workspace = try makeWorkspace()
            let originalBytes = try workspace.installFixture(named: fixture)
            _ = try workspace.materializeLegacySources()
            let beforeManaged = try workspace.allRegularFileBytes(
                under: workspace.managedRootURL
            )
            let fileSystem = MigrationOccurrenceFailingFileSystem()
            let outcome = try makeCoordinator(
                workspace: workspace,
                fileSystem: fileSystem,
                uuids: [UUID()]
            ).migrateIfNeeded()

            guard case let .requiresResolution(plan) = outcome else {
                XCTFail("Expected \(fixture) to require resolution.")
                continue
            }

            XCTAssertTrue(
                plan.blockers.contains { $0.kind == expectedBlocker },
                "Expected \(expectedBlocker) for \(fixture); got \(plan.blockers)"
            )
            XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
            XCTAssertEqual(
                try workspace.allRegularFileBytes(under: workspace.managedRootURL),
                beforeManaged
            )
            assertNoMutationOperations(fileSystem.events, fixture: fixture)
        }
    }

    func testSameNamedApplicationsSharingCanonicalLegacyRootRequireResolution() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(
            named: "valid-v1-library.json"
        ) { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
            var duplicate = applications[0]
            duplicate["id"] = "11111111-1111-4111-8111-111111111112"
            var profiles = try XCTUnwrap(duplicate["profiles"] as? [[String: Any]])
            profiles[0]["id"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"
            duplicate["profiles"] = profiles
            applications.append(duplicate)
            document["applications"] = applications
            object = document
        }
        _ = try workspace.materializeLegacySources()
        let fileSystem = MigrationOccurrenceFailingFileSystem()

        let outcome = try makeCoordinator(
            workspace: workspace,
            fileSystem: fileSystem,
            uuids: [UUID()]
        ).migrateIfNeeded()
        guard case let .requiresResolution(plan) = outcome else {
            return XCTFail("Shared legacy app roots must never be assigned automatically.")
        }

        XCTAssertTrue(plan.blockers.contains { $0.kind == .sharedApplicationRoot })
        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
        assertNoMutationOperations(fileSystem.events, fixture: "same-name-apps")
    }

    func testTraversalFixtureNeverReadsOrWritesEscapedCandidate() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(
            named: "traversing-storage-name.json"
        )
        let escapedCandidate = workspace.managedRootURL.appendingPathComponent(
            "Outside",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: escapedCandidate,
            withIntermediateDirectories: true
        )
        let escapedSentinel = escapedCandidate.appendingPathComponent("outside.sentinel")
        let escapedBytes = Data("must-not-be-inventoried".utf8)
        try escapedBytes.write(to: escapedSentinel)
        let fileSystem = MigrationOccurrenceFailingFileSystem()

        let outcome = try makeCoordinator(
            workspace: workspace,
            fileSystem: fileSystem,
            uuids: [UUID()]
        ).migrateIfNeeded()
        guard case let .requiresResolution(plan) = outcome else {
            return XCTFail("Traversal must be rejected before path resolution.")
        }

        XCTAssertTrue(plan.blockers.contains { $0.kind == .unsafeLegacyStorageName })
        XCTAssertEqual(try Data(contentsOf: escapedSentinel), escapedBytes)
        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
        XCTAssertFalse(
            fileSystem.events.contains {
                $0.firstURL?.standardizedFileURL.path == escapedCandidate.path
                    || $0.secondURL?.standardizedFileURL.path == escapedCandidate.path
            },
            "An unsafe component must be classified without probing its escaped candidate."
        )
    }

    func testUnexpectedV2DestinationIsNeverOverwrittenOrRemoved() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let migrationID = uuid("11000000-0000-4000-8000-000000000002")
        let applicationStorageID = uuid("21000000-0000-4000-8000-000000000002")
        let profileStorageID = uuid("31000000-0000-4000-8000-000000000002")
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
        try FileManager.default.createDirectory(
            at: destination,
            withIntermediateDirectories: true
        )
        let sentinel = destination.appendingPathComponent("unexpected.sentinel")
        let sentinelBytes = Data("preexisting-destination".utf8)
        try sentinelBytes.write(to: sentinel)

        let outcome = try makeCoordinator(
            workspace: workspace,
            uuids: [migrationID, applicationStorageID, profileStorageID]
        ).migrateIfNeeded()
        guard case let .requiresResolution(plan) = outcome else {
            return XCTFail("Unexpected final destinations must pause migration.")
        }

        XCTAssertTrue(plan.blockers.contains { $0.kind == .unexpectedDestination })
        XCTAssertEqual(try Data(contentsOf: sentinel), sentinelBytes)
        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
    }

    func testSourceMutationDuringCopyIsDetectedBeforeLibraryCommit() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(named: "valid-v1-library.json")
        let sentinels = try workspace.materializeLegacySources()
        let sourceSentinel = try XCTUnwrap(sentinels.keys.first)
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        fileSystem.afterOperation = { event in
            guard
                event.operation == .copyItem,
                event.firstURL?.lastPathComponent == "Personal"
            else {
                return
            }
            try Data("changed-during-copy".utf8).write(to: sourceSentinel)
        }

        XCTAssertThrowsError(
            try makeCoordinator(
                workspace: workspace,
                fileSystem: fileSystem,
                uuids: [
                    uuid("11000000-0000-4000-8000-000000000003"),
                    uuid("21000000-0000-4000-8000-000000000003"),
                    uuid("31000000-0000-4000-8000-000000000003")
                ]
            ).migrateIfNeeded()
        ) { error in
            guard case LibraryMigrationError.sourceChanged = error else {
                return XCTFail("Expected sourceChanged, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
        XCTAssertThrowsError(
            try LibraryPersistence.decodeApplications(
                from: Data(contentsOf: workspace.libraryURL)
            )
        )
        assertOwnedResidueIsCleanOrJournaled(workspace)
    }

    func testInterruptedRetryUsesJournaledIDsRatherThanNewGeneratorValues() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let migrationID = uuid("11000000-0000-4000-8000-000000000004")
        let applicationStorageID = uuid("21000000-0000-4000-8000-000000000004")
        let profileStorageID = uuid("31000000-0000-4000-8000-000000000004")
        let failingFileSystem = MigrationOccurrenceFailingFileSystem(
            failureRule: .init(.copyItem, occurrence: 2, timing: .after)
        )

        XCTAssertThrowsError(
            try makeCoordinator(
                workspace: workspace,
                fileSystem: failingFileSystem,
                uuids: [migrationID, applicationStorageID, profileStorageID]
            ).migrateIfNeeded()
        )
        let journal = workspace.assertableStateURLs(migrationID: migrationID).journal
        let journalText = try XCTUnwrap(
            String(data: Data(contentsOf: journal), encoding: .utf8)
        )
        XCTAssertTrue(journalText.contains(applicationStorageID.uuidString.lowercased()))
        XCTAssertTrue(journalText.contains(profileStorageID.uuidString.lowercased()))

        let outcome = try makeCoordinator(
            workspace: workspace,
            uuids: [
                uuid("ffffffff-ffff-4fff-8fff-100000000004"),
                uuid("ffffffff-ffff-4fff-8fff-200000000004"),
                uuid("ffffffff-ffff-4fff-8fff-300000000004")
            ]
        ).migrateIfNeeded()
        let applications = try migratedOrCurrentApplications(from: outcome)
        XCTAssertEqual(applications.first?.storageID, applicationStorageID)
        XCTAssertEqual(applications.first?.profiles.first?.storageID, profileStorageID)
    }

    func testEveryPrecommitMutationFailurePreservesV1AndLegacySentinels() throws {
        let baseline = try makeWorkspace()
        _ = try baseline.installFixture(named: "valid-v1-library.json")
        _ = try baseline.materializeLegacySources()
        let migrationID = uuid("11000000-0000-4000-8000-000000000005")
        let recorder = MigrationOccurrenceFailingFileSystem()
        _ = try makeCoordinator(
            workspace: baseline,
            fileSystem: recorder,
            uuids: [
                migrationID,
                uuid("21000000-0000-4000-8000-000000000005"),
                uuid("31000000-0000-4000-8000-000000000005")
            ]
        ).migrateIfNeeded()
        let replaceEvent = try XCTUnwrap(
            recorder.events.first { $0.operation == .replaceItem }
        )
        let precommitEvents = recorder.events.prefix {
            !($0.operation == replaceEvent.operation
                && $0.occurrence == replaceEvent.occurrence)
        }.filter {
            Self.mutatingOperations.contains($0.operation)
        } + [replaceEvent]

        XCTAssertFalse(precommitEvents.isEmpty)
        for event in precommitEvents {
            let workspace = try makeWorkspace()
            let originalBytes = try workspace.installFixture(
                named: "valid-v1-library.json"
            )
            let sentinels = try workspace.materializeLegacySources()
            let failingFileSystem = MigrationOccurrenceFailingFileSystem(
                failureRule: .init(
                    event.operation,
                    occurrence: event.occurrence,
                    timing: .before
                )
            )

            XCTAssertThrowsError(
                try makeCoordinator(
                    workspace: workspace,
                    fileSystem: failingFileSystem,
                    uuids: [
                        migrationID,
                        uuid("21000000-0000-4000-8000-000000000005"),
                        uuid("31000000-0000-4000-8000-000000000005")
                    ]
                ).migrateIfNeeded(),
                "Expected failure for \(event.operation) #\(event.occurrence)"
            )
            XCTAssertEqual(
                try Data(contentsOf: workspace.libraryURL),
                originalBytes,
                "Precommit \(event.operation) #\(event.occurrence) replaced v1."
            )
            for (source, bytes) in sentinels {
                XCTAssertEqual(try Data(contentsOf: source), bytes)
            }
            assertOwnedResidueIsCleanOrJournaled(workspace)
        }
    }

    func testCorruptInvalidAndFutureLibrariesRemainExactlyUntouched() throws {
        for fixture in [
            "corrupt-truncated.json",
            "negative-version.json",
            "zero-version.json",
            "unsupported-future-version.json"
        ] {
            let workspace = try makeWorkspace()
            let originalFixture = try fixtureBytes(named: fixture)
            try workspace.installBytes(originalFixture)
            let beforeTree = try workspace.allRegularFileBytes(under: workspace.rootURL)
            let fileSystem = MigrationOccurrenceFailingFileSystem()

            XCTAssertThrowsError(
                try makeCoordinator(
                    workspace: workspace,
                    fileSystem: fileSystem,
                    uuids: [UUID()]
                ).migrateIfNeeded()
            )

            XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalFixture)
            XCTAssertEqual(
                try workspace.allRegularFileBytes(under: workspace.rootURL),
                beforeTree
            )
            assertNoMutationOperations(fileSystem.events, fixture: fixture)
        }
    }

    private static let mutatingOperations: Set<
        MigrationOccurrenceFailingFileSystem.Operation
    > = [
        .createDirectory,
        .copyItem,
        .moveItem,
        .removeItem,
        .writeData,
        .writeDataAtomically,
        .replaceItem,
        .setPermissions,
        .synchronize
    ]

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

    private func migratedOrCurrentApplications(
        from outcome: LibraryMigrationOutcome
    ) throws -> [ManagedApplication] {
        switch outcome {
        case let .migrated(applications, _), let .current(applications):
            return applications
        case .requiresResolution:
            throw MigrationTestSupportError.missingLegacyProfile
        }
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

    private func assertNoMutationOperations(
        _ events: [MigrationOccurrenceFailingFileSystem.Event],
        fixture: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            events.contains { Self.mutatingOperations.contains($0.operation) },
            "\(fixture) performed a write during preflight.",
            file: file,
            line: line
        )
    }

    private func assertOwnedResidueIsCleanOrJournaled(
        _ workspace: MigrationFixtureWorkspace,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let migrationRoot = workspace.parallaxURL.appendingPathComponent(
            "Migrations",
            isDirectory: true
        )
        guard FileManager.default.fileExists(atPath: migrationRoot.path) else {
            return
        }
        let journals = (try? FileManager.default.contentsOfDirectory(
            at: migrationRoot,
            includingPropertiesForKeys: nil
        ).map {
            $0.appendingPathComponent("journal.json")
        }.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }) ?? []
        XCTAssertFalse(
            journals.isEmpty,
            "Residual migration-owned state must have a durable journal.",
            file: file,
            line: line
        )
    }

    private func fixtureBytes(named name: String) throws -> Data {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: nil,
            subdirectory: "Fixtures"
        ) else {
            throw MigrationTestSupportError.missingFixture(name)
        }
        return try Data(contentsOf: url)
    }

    private func uuid(_ string: String) -> UUID {
        UUID(uuidString: string) ?? UUID()
    }
}
