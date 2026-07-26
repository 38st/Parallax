import Foundation
import XCTest
@testable import Parallax

final class LibraryMigrationFinalBlockerTests: XCTestCase {
    private var workspaces: [MigrationFixtureWorkspace] = []

    override func tearDownWithError() throws {
        workspaces.forEach { $0.remove() }
        workspaces.removeAll()
    }

    func testCommittedRecoveryUsesBackupWhenRetainedLegacySourceChangedOrDisappeared() throws {
        for mutation in RetainedSourceMutation.allCases {
            let workspace = try makeWorkspace()
            _ = try workspace.installFixture(named: "valid-v1-library.json")
            let sentinels = try workspace.materializeLegacySources()
            let sourceSentinel = try XCTUnwrap(sentinels.keys.first)
            let sourceRoot = sourceSentinel.deletingLastPathComponent()
            let deterministic = ids(suffix: 401)
            let migrationID = deterministic[0]
            let destination = v2ProfileURL(
                workspace: workspace,
                applicationStorageID: deterministic[1],
                profileStorageID: deterministic[2]
            )
            let paths = workspace.assertableStateURLs(migrationID: migrationID)
            let failingFileSystem = MigrationOccurrenceFailingFileSystem(
                failureRule: .init(.replaceItem, occurrence: 1, timing: .after)
            )

            XCTAssertThrowsError(
                try coordinator(
                    workspace: workspace,
                    fileSystem: failingFileSystem,
                    uuids: deterministic
                ).migrateIfNeeded()
            )
            XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.backup.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: paths.journal.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: paths.receipt.path))

            switch mutation {
            case .changed:
                try Data("legacy-source-changed-after-v2-commit".utf8).write(
                    to: sourceSentinel,
                    options: .atomic
                )
            case .deleted:
                try FileManager.default.removeItem(at: sourceRoot)
            }

            let outcome = try coordinator(
                workspace: workspace,
                uuids: ids(suffix: 499)
            ).migrateIfNeeded()
            let applications = try migratedApplications(from: outcome)

            XCTAssertEqual(applications.first?.storageID, deterministic[1])
            XCTAssertEqual(
                applications.first?.profiles.first?.storageID,
                deterministic[2]
            )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: paths.receipt.path),
                "Committed recovery should finalize from backup, v2, and destination after \(mutation)."
            )
        }
    }

    func testHistoricalQuotedTildeGeneratedPathsRewriteToV2() throws {
        let workspace = try makeWorkspace()
        let tildeBase = tildePath(to: workspace.managedRootURL)
        let tildeProfileRoot =
            "\(tildeBase)/Fixture-Browser/Personal"
        let originalArguments =
            "--user-data-dir=\"\(tildeProfileRoot)/UserData\""
        let originalEnvironment =
            "CODEX_HOME=\(tildeProfileRoot)/CodexHome"
        _ = try workspace.installFixture(
            named: "valid-v1-library.json"
        ) { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(
                document["applications"] as? [[String: Any]]
            )
            applications[0]["preset"] = "codex"
            applications[0]["baseStoragePath"] = tildeBase
            var profiles = try XCTUnwrap(
                applications[0]["profiles"] as? [[String: Any]]
            )
            profiles[0]["argumentsText"] = originalArguments
            profiles[0]["environmentText"] = originalEnvironment
            applications[0]["profiles"] = profiles
            document["applications"] = applications
            object = document
        }
        _ = try workspace.materializeLegacySources()
        let deterministic = ids(suffix: 402)

        let applications = try migratedApplications(
            from: coordinator(
                workspace: workspace,
                uuids: deterministic
            ).migrateIfNeeded()
        )
        let application = try XCTUnwrap(applications.first)
        let profile = try XCTUnwrap(application.profiles.first)
        let destination = v2ProfileURL(
            workspace: workspace,
            applicationStorageID: application.storageID,
            profileStorageID: profile.storageID
        )

        XCTAssertEqual(
            profile.argumentsText,
            "--user-data-dir=\"\(destination.appendingPathComponent("UserData").path)\""
        )
        XCTAssertEqual(
            profile.environmentText,
            "CODEX_HOME=\(destination.appendingPathComponent("CodexHome").path)"
        )
        XCTAssertEqual(application.baseStoragePath, workspace.managedRootURL.path)
    }

    func testMalformedLegacyArgumentsRemainByteForByte() throws {
        let malformedSuffixes = [
            "\"",
            " \\"
        ]

        for suffix in malformedSuffixes {
            let workspace = try makeWorkspace()
            let oldUserData = workspace.managedRootURL
                .appendingPathComponent(
                    "Fixture-Browser/Personal/UserData",
                    isDirectory: true
                )
                .path
            let arguments: String
            if suffix == "\"" {
                arguments = "--user-data-dir=\"\(oldUserData)"
            } else {
                arguments = "--user-data-dir=\(oldUserData)\(suffix)"
            }
            _ = try workspace.installFixture(
                named: "valid-v1-library.json"
            ) { object in
                var document = try XCTUnwrap(object as? [String: Any])
                var applications = try XCTUnwrap(
                    document["applications"] as? [[String: Any]]
                )
                var profiles = try XCTUnwrap(
                    applications[0]["profiles"] as? [[String: Any]]
                )
                profiles[0]["argumentsText"] = arguments
                applications[0]["profiles"] = profiles
                document["applications"] = applications
                object = document
            }
            _ = try workspace.materializeLegacySources()

            let applications = try migratedApplications(
                from: coordinator(
                    workspace: workspace,
                    uuids: ids(suffix: 410 + workspaces.count)
                ).migrateIfNeeded()
            )

            XCTAssertEqual(
                applications.first?.profiles.first?.argumentsText,
                arguments,
                "Malformed legacy text must not be partly normalized or rewritten."
            )
        }
    }

    func testHigherAncestorSymlinkSwapDuringCopyOrPublicationWritesNothingExternal() throws {
        for scenario in HigherAncestorSwapScenario.allCases {
            let workspace = try makeWorkspace()
            let originalBytes = try workspace.installFixture(
                named: "valid-v1-library.json"
            )
            _ = try workspace.materializeLegacySources()
            let deterministic = ids(suffix: 430 + scenario.rawValue)
            let transactionRoot = workspace.managedRootURL
                .appendingPathComponent(".parallax", isDirectory: true)
                .appendingPathComponent("Transactions", isDirectory: true)
            let transactionIDRoot = transactionRoot.appendingPathComponent(
                deterministic[0].uuidString.lowercased(),
                isDirectory: true
            )
            let swapURL: URL
            switch scenario.ancestor {
            case .transactions:
                swapURL = transactionRoot
            case .transactionID:
                swapURL = transactionIDRoot
            }
            let externalParent = workspace.externalRootURL.appendingPathComponent(
                "higher-\(scenario.rawValue)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: externalParent,
                withIntermediateDirectories: true
            )
            let externalTarget = externalParent.appendingPathComponent(
                "redirected",
                isDirectory: true
            )
            let probe = FinalBlockerSwapProbe()
            let fileSystem = MigrationOccurrenceFailingFileSystem()
            fileSystem.beforeOperation = { event in
                guard scenario.matches(event) else { return }
                try probe.runOnce {
                    try FileManager.default.moveItem(
                        at: swapURL,
                        to: externalTarget
                    )
                    try FileManager.default.createSymbolicLink(
                        at: swapURL,
                        withDestinationURL: externalTarget
                    )
                    probe.captureBaseline(
                        try regularFileBytes(under: externalTarget)
                    )
                }
            }

            XCTAssertThrowsError(
                try coordinator(
                    workspace: workspace,
                    fileSystem: fileSystem,
                    uuids: deterministic
                ).migrateIfNeeded(),
                "The \(scenario) ancestor swap must abort."
            )

            XCTAssertTrue(probe.didRun)
            XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
            XCTAssertEqual(
                try regularFileBytes(under: externalTarget),
                probe.baseline,
                "The \(scenario) swap redirected a copy or cleanup outside the managed root."
            )
        }
    }

    func testWhitespacePaddedValidLegacyBaseUsesHistoricalTrimmedPath() throws {
        let workspace = try makeWorkspace()
        let paddedBase =
            " \t\(workspace.managedRootURL.path)\n "
        _ = try workspace.installFixture(
            named: "valid-v1-library.json"
        ) { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(
                document["applications"] as? [[String: Any]]
            )
            applications[0]["baseStoragePath"] = paddedBase
            document["applications"] = applications
            object = document
        }
        let sources = try workspace.materializeLegacySources()
        let deterministic = ids(suffix: 450)

        let applications = try migratedApplications(
            from: coordinator(
                workspace: workspace,
                uuids: deterministic
            ).migrateIfNeeded()
        )
        let application = try XCTUnwrap(applications.first)
        let profile = try XCTUnwrap(application.profiles.first)
        let destination = v2ProfileURL(
            workspace: workspace,
            applicationStorageID: application.storageID,
            profileStorageID: profile.storageID
        )
        let copiedSentinel = destination.appendingPathComponent(
            "fixture-\(profile.id.uuidString.lowercased()).sentinel"
        )

        XCTAssertEqual(application.baseStoragePath, workspace.managedRootURL.path)
        XCTAssertEqual(
            try Data(contentsOf: copiedSentinel),
            sources.values.first
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
                    0x7200_0000 + index,
                    suffix
                )
            )
        }
    }

    private func v2ProfileURL(
        workspace: MigrationFixtureWorkspace,
        applicationStorageID: UUID,
        profileStorageID: UUID
    ) -> URL {
        workspace.managedRootURL
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

    private func tildePath(to target: URL) -> String {
        let homeComponents = FileManager.default.homeDirectoryForCurrentUser
            .standardizedFileURL.pathComponents
        let targetComponents = target.standardizedFileURL.pathComponents
        var common = 0
        while
            common < homeComponents.count,
            common < targetComponents.count,
            homeComponents[common] == targetComponents[common] {
            common += 1
        }
        let upward = Array(
            repeating: "..",
            count: homeComponents.count - common
        )
        let downward = Array(targetComponents.dropFirst(common))
        return "~/" + (upward + downward).joined(separator: "/")
    }
}

private enum RetainedSourceMutation: String, CaseIterable {
    case changed
    case deleted
}

private enum HigherAncestor: String {
    case transactions
    case transactionID
}

private enum HigherAncestorSwapScenario: Int, CaseIterable, CustomStringConvertible {
    case transactionsDuringSourceCopy
    case transactionIDDuringSourceCopy
    case transactionsDuringPublishCopy
    case transactionIDDuringPublishCopy

    var ancestor: HigherAncestor {
        switch self {
        case .transactionsDuringSourceCopy, .transactionsDuringPublishCopy:
            .transactions
        case .transactionIDDuringSourceCopy, .transactionIDDuringPublishCopy:
            .transactionID
        }
    }

    var copyParent: String {
        switch self {
        case .transactionsDuringSourceCopy, .transactionIDDuringSourceCopy:
            "SourceCopies"
        case .transactionsDuringPublishCopy, .transactionIDDuringPublishCopy:
            "PublishCopies"
        }
    }

    var description: String {
        "\(ancestor.rawValue)-during-\(copyParent)"
    }

    func matches(
        _ event: MigrationOccurrenceFailingFileSystem.Event
    ) -> Bool {
        event.operation == .copyItem
            && event.secondURL?
                .deletingLastPathComponent()
                .lastPathComponent == copyParent
    }
}

private final class FinalBlockerSwapProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var ran = false
    private var captured: [String: Data] = [:]

    var didRun: Bool {
        lock.lock()
        defer { lock.unlock() }
        return ran
    }

    var baseline: [String: Data] {
        lock.lock()
        defer { lock.unlock() }
        return captured
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

    func captureBaseline(_ bytes: [String: Data]) {
        lock.lock()
        captured = bytes
        lock.unlock()
    }
}

private func regularFileBytes(under root: URL) throws -> [String: Data] {
    guard FileManager.default.fileExists(atPath: root.path) else { return [:] }
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: []
    ) else {
        return [:]
    }
    var result: [String: Data] = [:]
    while let item = enumerator.nextObject() as? URL {
        let values = try item.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        if values.isRegularFile == true, values.isSymbolicLink != true {
            result[item.path.replacingOccurrences(of: root.path, with: "")] =
                try Data(contentsOf: item)
        }
    }
    return result
}
