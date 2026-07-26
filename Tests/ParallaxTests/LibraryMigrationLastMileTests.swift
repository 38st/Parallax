import Foundation
import XCTest
@testable import Parallax

final class LibraryMigrationLastMileTests: XCTestCase {
    private var workspaces: [MigrationFixtureWorkspace] = []

    override func tearDownWithError() throws {
        workspaces.forEach { $0.remove() }
        workspaces.removeAll()
    }

    func testSameProcessPostCommitSourceMutationOrDeletionStillFinalizes() throws {
        for mutation in LastMileSourceMutation.allCases {
            let workspace = try makeWorkspace()
            _ = try workspace.installFixture(named: "valid-v1-library.json")
            let sentinels = try workspace.materializeLegacySources()
            let sourceSentinel = try XCTUnwrap(sentinels.keys.first)
            let sourceRoot = sourceSentinel.deletingLastPathComponent()
            let deterministic = ids(suffix: 501 + mutation.rawValue)
            let migrationID = deterministic[0]
            let paths = workspace.assertableStateURLs(migrationID: migrationID)
            let libraryParent = workspace.libraryURL.deletingLastPathComponent()
            let mutationGate = LastMileAtomicFlag()
            let fileSystem = MigrationOccurrenceFailingFileSystem()
            fileSystem.afterOperation = { event in
                guard
                    event.operation == .synchronize,
                    event.firstURL?.standardizedFileURL
                        == libraryParent.standardizedFileURL
                else {
                    return
                }
                try mutationGate.runOnce {
                    switch mutation {
                    case .changed:
                        try Data("changed-after-durable-v2-commit".utf8).write(
                            to: sourceSentinel,
                            options: .atomic
                        )
                    case .deleted:
                        try FileManager.default.removeItem(at: sourceRoot)
                    }
                }
            }

            let outcome = try coordinator(
                workspace: workspace,
                fileSystem: fileSystem,
                uuids: deterministic
            ).migrateIfNeeded()
            let applications = try migratedApplications(from: outcome)

            XCTAssertTrue(mutationGate.didRun)
            XCTAssertEqual(applications.first?.storageID, deterministic[1])
            XCTAssertEqual(
                applications.first?.profiles.first?.storageID,
                deterministic[2]
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.receipt.path))
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: paths.pendingReceipt.path)
            )
            XCTAssertEqual(
                try LibraryPersistence.decodeApplications(
                    from: Data(contentsOf: workspace.libraryURL)
                ),
                applications
            )
        }
    }

    func testStableConfiguredBaseSymlinkMigratesThroughCanonicalPinnedRoot() throws {
        let workspace = try makeWorkspace()
        let configuredBase = workspace.rootURL.appendingPathComponent(
            "ConfiguredManagedRoot",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: configuredBase,
            withDestinationURL: workspace.managedRootURL
        )
        _ = try workspace.installFixture(
            named: "valid-v1-library.json"
        ) { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(
                document["applications"] as? [[String: Any]]
            )
            applications[0]["baseStoragePath"] = configuredBase.path
            var profiles = try XCTUnwrap(
                applications[0]["profiles"] as? [[String: Any]]
            )
            profiles[0]["argumentsText"] =
                "--user-data-dir=\(configuredBase.path)"
                + "/Fixture-Browser/Personal/UserData"
            applications[0]["profiles"] = profiles
            document["applications"] = applications
            object = document
        }
        let sentinels = try workspace.materializeLegacySources()
        let deterministic = ids(suffix: 510)
        let externalSentinel = workspace.externalRootURL.appendingPathComponent(
            "must-remain-untouched.sentinel"
        )
        let externalBytes = Data("outside-canonical-managed-root".utf8)
        try externalBytes.write(to: externalSentinel)

        let outcome = try coordinator(
            workspace: workspace,
            uuids: deterministic
        ).migrateIfNeeded()
        guard case let .migrated(applications, receipt) = outcome else {
            return XCTFail("A stable configured base symlink should migrate.")
        }
        let application = try XCTUnwrap(applications.first)
        let profile = try XCTUnwrap(application.profiles.first)
        let canonicalDestination = canonicalV2ProfileURL(
            workspace: workspace,
            applicationStorageID: application.storageID,
            profileStorageID: profile.storageID
        )
        let copiedSentinel = canonicalDestination.appendingPathComponent(
            "fixture-\(profile.id.uuidString.lowercased()).sentinel"
        )
        let mapping = try XCTUnwrap(receipt.mappings.first)

        XCTAssertEqual(
            application.baseStoragePath,
            workspace.managedRootURL.standardizedFileURL.path,
            "Persisted v2 metadata should use the pinned canonical base."
        )
        XCTAssertEqual(
            mapping.newCanonicalPath,
            canonicalDestination.standardizedFileURL.path
        )
        XCTAssertEqual(
            try Data(contentsOf: copiedSentinel),
            sentinels.values.first
        )
        XCTAssertEqual(try Data(contentsOf: externalSentinel), externalBytes)
        XCTAssertEqual(
            configuredBase.resolvingSymlinksInPath().standardizedFileURL,
            workspace.managedRootURL.resolvingSymlinksInPath().standardizedFileURL
        )
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
        switch outcome {
        case let .migrated(applications, _), let .current(applications):
            return applications
        case .requiresResolution:
            throw MigrationTestSupportError.missingLegacyProfile
        }
    }

    private func ids(suffix: Int) -> [UUID] {
        [0, 1, 2].compactMap { index in
            UUID(
                uuidString: String(
                    format: "%08x-0000-4000-8000-%012x",
                    0x7300_0000 + index,
                    suffix
                )
            )
        }
    }

    private func canonicalV2ProfileURL(
        workspace: MigrationFixtureWorkspace,
        applicationStorageID: UUID,
        profileStorageID: UUID
    ) -> URL {
        workspace.managedRootURL
            .resolvingSymlinksInPath()
            .appendingPathComponent(".parallax", isDirectory: true)
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(
                applicationStorageID.uuidString.lowercased(),
                isDirectory: true
            )
            .appendingPathComponent("Profiles", isDirectory: true)
            .appendingPathComponent(
                profileStorageID.uuidString.lowercased(),
                isDirectory: true
            )
    }
}

private enum LastMileSourceMutation: Int, CaseIterable {
    case changed
    case deleted
}

private final class LastMileAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var ran = false

    var didRun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ran
    }

    func runOnce(_ body: () throws -> Void) throws {
        lock.lock()
        if ran {
            lock.unlock()
            return
        }
        ran = true
        lock.unlock()
        try body()
    }
}
