import Foundation
import XCTest
@testable import Parallax

final class LibraryMigrationRecoveryAuditRegressionTests: XCTestCase {
    private var workspaces: [MigrationFixtureWorkspace] = []

    override func tearDownWithError() throws {
        workspaces.forEach { $0.remove() }
        workspaces.removeAll()
    }

    func testChangedLegacyHashAfterSuccessfulRollbackRetiresOldJournal() throws {
        let workspace = try workspace()
        let sentinel = try XCTUnwrap(workspace.materializeLegacySources().keys.first)
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        fileSystem.afterOperation = { event in
            if event.operation == .copyItem, event.firstURL?.lastPathComponent == "Personal" {
                try Data("changed source".utf8).write(to: sentinel)
            }
        }
        XCTAssertThrowsError(try coordinator(workspace, fileSystem).migrateIfNeeded()) {
            XCTAssertEqual($0 as? LibraryMigrationError, .sourceChanged)
        }
        let old = try XCTUnwrap(coordinator(workspace).allIncompleteJournals().first)
        try updateLastLaunchedAt(workspace)
        guard case let .migrated(_, receipt) = try coordinator(workspace).migrateIfNeeded() else {
            return XCTFail("A fully rolled-back journal must not block a different v1 snapshot")
        }
        XCTAssertNotEqual(receipt.migrationID, old.migrationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath:
            coordinator(workspace).controlPaths(for: old.migrationID).journal.path))
        XCTAssertTrue(try coordinator(workspace).allIncompleteJournals().isEmpty)
    }

    func testCrashBeforeAndAfterOldJournalRetirementAllowsNewSnapshot() throws {
        for timing in [MigrationOccurrenceFailingFileSystem.Timing.before, .after] {
            let workspace = try workspace()
            let coordinator = coordinator(workspace)
            let allocation = try preparedAllocation(workspace, coordinator)
            try updateLastLaunchedAt(workspace)
            let fileSystem = MigrationOccurrenceFailingFileSystem(
                failureRule: .init(.moveItem, occurrence: 1, timing: timing))
            XCTAssertThrowsError(try self.coordinator(workspace, fileSystem).migrateIfNeeded())
            guard case let .migrated(_, receipt) = try coordinator.migrateIfNeeded() else {
                return XCTFail("Retirement must be restartable on either side of the rename")
            }
            XCTAssertNotEqual(receipt.migrationID, allocation.journal.migrationID)
        }
    }

    func testObsoleteJournalOutsideRetainedBaseIsNotRetired() throws {
        let workspace = try workspace()
        let coordinator = coordinator(workspace)
        let allocation = try preparedAllocation(workspace, coordinator)
        let journalURL = coordinator.controlPaths(for: allocation.journal.migrationID).journal
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: journalURL)) as? [String: Any])
        var mappings = try XCTUnwrap(object["mappings"] as? [[String: Any]])
        let path = try XCTUnwrap(mappings[0]["newCanonicalPath"] as? String)
        mappings[0]["newCanonicalPath"] = path.replacingOccurrences(of: workspace.managedRootURL.path, with: workspace.externalRootURL.path)
        object["mappings"] = mappings
        try JSONSerialization.data(withJSONObject: object).write(to: journalURL)
        try updateLastLaunchedAt(workspace)
        let before = try workspace.allRegularFileBytes(under: workspace.rootURL)
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        fileSystem.beforeOperation = { event in
            if event.firstURL?.path.hasPrefix(workspace.externalRootURL.path) == true {
                XCTFail("An untrusted journal must not cause probes outside its retained library root")
            }
        }
        XCTAssertThrowsError(try self.coordinator(workspace, fileSystem).migrateIfNeeded())
        XCTAssertEqual(try workspace.allRegularFileBytes(under: workspace.rootURL), before)
    }

    func testChangedSourceDoesNotBlockRollbackOfUnchangedSourceDestination() throws {
        let workspace = try workspace(twoProfiles: true)
        let coordinator = coordinator(workspace)
        let allocation = try preparedAllocation(workspace, coordinator)
        let unchanged = try XCTUnwrap(allocation.records.first)
        let changed = try XCTUnwrap(allocation.records.last)
        try coordinator.executeCopies(journal: allocation.journal, sourceRecords: [unchanged])
        try Data("changed after crash".utf8).write(to:
            changed.source.sourceURL.appendingPathComponent("new-data"))
        guard case let .migrated(_, receipt) = try coordinator.migrateIfNeeded() else {
            return XCTFail("Only the unchanged source has a published destination")
        }
        XCTAssertEqual(receipt.migrationID, allocation.journal.migrationID)
        XCTAssertEqual(receipt.mappings.map(\.profileStorageID), allocation.journal.mappings.map(\.profileStorageID))
    }

    func testMissingSourceDoesNotBlockRollbackOfUnchangedSourceDestination() throws {
        let workspace = try workspace(twoProfiles: true)
        let coordinator = coordinator(workspace)
        let allocation = try preparedAllocation(workspace, coordinator)
        let unchanged = try XCTUnwrap(allocation.records.first)
        let missing = try XCTUnwrap(allocation.records.last)
        try coordinator.executeCopies(journal: allocation.journal, sourceRecords: [unchanged])
        try FileManager.default.removeItem(at: missing.source.sourceURL)
        guard case let .migrated(_, receipt) = try coordinator.migrateIfNeeded() else {
            return XCTFail("An absent source with no owned state must not block unrelated rollback")
        }
        XCTAssertEqual(receipt.mappings.last?.disposition, .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.paths.profileRoot.url.path))
    }

    func testChangedSourceWithOrphanedOwnedStateFailsClosed() throws {
        for leftover in ["owner", "publication", "staging"] {
            for changedLibrary in [false, true] {
                let workspace = try workspace()
                let coordinator = coordinator(workspace)
                let allocation = try preparedAllocation(workspace, coordinator)
                let record = try XCTUnwrap(allocation.records.first)
                let path: URL
                switch leftover {
                case "owner":
                    path = coordinator.ownerMarkerURL(destination: record.paths.profileRoot.url, mapping: record.mapping)
                    try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try coordinator.ownerData(for: allocation.journal, mapping: record.mapping).write(to: path)
                case "publication":
                    try coordinator.writePublicationState(journal: allocation.journal, mapping: record.mapping, state: .prepared)
                    path = coordinator.publicationURL(migrationID: allocation.journal.migrationID, mapping: record.mapping)
                default:
                    path = try record.paths.stagingRoot(transactionID: allocation.journal.migrationID).url
                    try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
                    try Data("partial copy".utf8).write(to: path.appendingPathComponent("partial"))
                }
                try Data("changed after crash".utf8).write(to: record.source.sourceURL.appendingPathComponent("new-data"))
                if changedLibrary { try updateLastLaunchedAt(workspace) }
                let before = try workspace.allRegularFileBytes(under: workspace.rootURL)
                XCTAssertThrowsError(try coordinator.migrateIfNeeded(), "\(leftover), changed library: \(changedLibrary)")
                XCTAssertEqual(try workspace.allRegularFileBytes(under: workspace.rootURL), before)
                XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
            }
        }
    }

    func testInterruptedRollbackDeletionConvergesFromTransactionTrash() throws {
        let workspace = try workspace()
        let coordinator = coordinator(workspace)
        let allocation = try preparedAllocation(workspace, coordinator)
        try coordinator.executeCopies(journal: allocation.journal, sourceRecords: allocation.records)
        let destination = try XCTUnwrap(allocation.records.first?.paths.profileRoot.url)
        let staging = try XCTUnwrap(allocation.records.first).paths.stagingRoot(transactionID: allocation.journal.migrationID).url
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        fileSystem.beforeOperation = { event in
            guard event.operation == .removeItem, let path = event.firstURL,
                path == destination || path == staging || path.path.contains("/RollbackCopies/")
            else { return }
            let enumerator = FileManager.default.enumerator(at: path, includingPropertiesForKeys: [.isRegularFileKey])
            while let entry = enumerator?.nextObject() as? URL {
                if try entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                    try FileManager.default.removeItem(at: entry)
                    break
                }
            }
            throw CocoaError(.fileWriteUnknown)
        }
        XCTAssertThrowsError(try self.coordinator(workspace, fileSystem).rollbackOwnedState(
            for: allocation.journal, sourceRecords: allocation.records.map(\.source)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        guard case .migrated = try coordinator.migrateIfNeeded() else {
            return XCTFail("A partial deletion in transaction trash must be recoverable")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testJournalDiscoveryLeavesAbandonedControlDirectoryUntouched() throws {
        let workspace = try workspace()
        let directory = workspace.migrationDirectory(migrationID: UUID())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pending = directory.appendingPathComponent(".journal.json.pending")
        try Data("partial journal".utf8).write(to: pending)
        XCTAssertTrue(try coordinator(workspace).allIncompleteJournals().isEmpty)
        XCTAssertEqual(try Data(contentsOf: pending), Data("partial journal".utf8))
    }

    func testStalePublicationTemporaryIsCleanedBeforeRetry() throws {
        let workspace = try workspace()
        let coordinator = coordinator(workspace)
        let allocation = try preparedAllocation(workspace, coordinator)
        let mapping = try XCTUnwrap(allocation.journal.mappings.first)
        let publication = coordinator.publicationURL(migrationID: allocation.journal.migrationID, mapping: mapping)
        let pending = publication.deletingLastPathComponent().appendingPathComponent(".\(publication.lastPathComponent).pending")
        try Data("incomplete publication".utf8).write(to: pending)
        guard case .migrated = try coordinator.migrateIfNeeded() else { return XCTFail("Expected migration") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
    }

    func testCrashBeforeAndAfterJournalReplacementKeepsRetryableIDs() throws {
        for timing in [MigrationOccurrenceFailingFileSystem.Timing.before, .after] {
            let workspace = try workspace()
            let coordinator = coordinator(workspace)
            let allocation = try preparedAllocation(workspace, coordinator)
            let source = try XCTUnwrap(allocation.records.first?.source.sourceURL)
            try Data("new data".utf8).write(to: source.appendingPathComponent("new-data"))
            let fileSystem = MigrationOccurrenceFailingFileSystem(
                failureRule: .init(.writeDataAtomically, occurrence: 1, timing: timing))
            let persistence = LibraryPersistence(fileSystem: LocalFileSystem(), applicationSupportURL: workspace.applicationSupportURL)
            guard case let .legacy(snapshot) = try persistence.loadSnapshot() else { return XCTFail("Expected v1") }
            let inventory = try coordinator.inventorySources(in: snapshot.library)
            let replacement = try coordinator.allocate(snapshot: snapshot, sources: inventory.profiles, existingJournal: allocation.journal)
            XCTAssertThrowsError(try self.coordinator(workspace, fileSystem).prepareControlState(
                journal: replacement.journal, originalBytes: snapshot.originalBytes, replacingJournal: allocation.journal))
            let persisted = try XCTUnwrap(coordinator.allIncompleteJournals().first)
            XCTAssertTrue(persisted == allocation.journal || persisted == replacement.journal)
            guard case let .migrated(_, receipt) = try coordinator.migrateIfNeeded() else {
                return XCTFail("Either atomic journal version must remain retryable")
            }
            XCTAssertEqual(receipt.migrationID, allocation.journal.migrationID)
            XCTAssertEqual(receipt.mappings.map(\.profileStorageID), allocation.journal.mappings.map(\.profileStorageID))
        }
    }

    func testQuotedAndBackslashEscapedGeneratedArgumentPathsAreRewritten() throws {
        for style in ["double", "backslash"] {
            let workspace = try workspace()
            _ = try workspace.installFixture(named: "valid-v1-library.json") { object in
                var document = try XCTUnwrap(object as? [String: Any])
                var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
                var profiles = try XCTUnwrap(applications[0]["profiles"] as? [[String: Any]])
                profiles[0]["storageName"] = "Personal Space"
                let path = workspace.managedRootURL.appendingPathComponent("Fixture-Browser/Personal Space/UserData").path
                let quoted = style == "double" ? "\"\(path)\"" : path.replacingOccurrences(of: " ", with: "\\ ")
                profiles[0]["argumentsText"] = "--before  --user-data-dir=\(quoted) --after"
                applications[0]["profiles"] = profiles
                document["applications"] = applications
                object = document
            }
            guard case let .migrated(applications, receipt) = try coordinator(workspace).migrateIfNeeded() else {
                return XCTFail("Expected migration")
            }
            let mapping = try XCTUnwrap(receipt.mappings.first)
            let profile = try XCTUnwrap(applications.first?.profiles.first)
            XCTAssertEqual(ShellWordsParser.parse(profile.argumentsText), ["--before", "--user-data-dir=\(mapping.newCanonicalPath)/UserData", "--after"])
            XCTAssertEqual(mapping.isolationConfiguration, .generated)
        }
    }

    func testRepeatedGeneratedCodexHomeOnlyRewritesAssignmentsForThatKey() throws {
        let workspace = try workspace()
        let path = workspace.managedRootURL.appendingPathComponent("Fixture-Browser/Personal/CodexHome").path
        _ = try workspace.installFixture(named: "valid-v1-library.json") { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
            var profiles = try XCTUnwrap(applications[0]["profiles"] as? [[String: Any]])
            profiles[0]["environmentText"] = "# \(path)\nCODEX_HOME=\(path)\n CODEX_HOME = '\(path)'\nOTHER=\(path)\n"
            applications[0]["profiles"] = profiles
            document["applications"] = applications
            object = document
        }
        guard case let .migrated(applications, receipt) = try coordinator(workspace).migrateIfNeeded() else {
            return XCTFail("Expected migration")
        }
        let mapping = try XCTUnwrap(receipt.mappings.first)
        XCTAssertEqual(mapping.isolationConfiguration, .generated)
        XCTAssertEqual(applications.first?.profiles.first?.environmentText,
            "# \(path)\nCODEX_HOME=\(mapping.newCanonicalPath)/CodexHome\n CODEX_HOME = '\(mapping.newCanonicalPath)/CodexHome'\nOTHER=\(path)\n")
    }

    func testGeneratedCodexHomeAlsoMentionedInCommentIsRewritten() throws {
        let workspace = try workspace()
        let path = workspace.managedRootURL.appendingPathComponent("Fixture-Browser/Personal/CodexHome").path
        _ = try workspace.installFixture(named: "valid-v1-library.json") { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
            var profiles = try XCTUnwrap(applications[0]["profiles"] as? [[String: Any]])
            profiles[0]["environmentText"] = "# \(path)\nCODEX_HOME=\(path)\n"
            applications[0]["profiles"] = profiles
            document["applications"] = applications
            object = document
        }
        guard case let .migrated(applications, receipt) = try coordinator(workspace).migrateIfNeeded() else {
            return XCTFail("Expected migration")
        }
        let mapping = try XCTUnwrap(receipt.mappings.first)
        XCTAssertEqual(mapping.isolationConfiguration, .generated)
        XCTAssertEqual(applications.first?.profiles.first?.environmentText,
            "# \(path)\nCODEX_HOME=\(mapping.newCanonicalPath)/CodexHome\n")
    }

    private func workspace(twoProfiles: Bool = false) throws -> MigrationFixtureWorkspace {
        let workspace = try MigrationFixtureWorkspace()
        workspaces.append(workspace)
        _ = try workspace.installFixture(named: "valid-v1-library.json") { object in
            guard twoProfiles else { return }
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
            var profiles = try XCTUnwrap(applications[0]["profiles"] as? [[String: Any]])
            var second = profiles[0]
            second["id"] = UUID().uuidString
            second["storageName"] = "Work"
            second["name"] = "Work"
            second["argumentsText"] = ""
            profiles.append(second)
            applications[0]["profiles"] = profiles
            document["applications"] = applications
            object = document
        }
        return workspace
    }

    private func coordinator(_ workspace: MigrationFixtureWorkspace,
        _ fileSystem: any FileSystem = LocalFileSystem()) -> LibraryMigrationCoordinator {
        LibraryMigrationCoordinator(fileSystem: fileSystem, applicationSupportURL: workspace.applicationSupportURL,
            now: { Date(timeIntervalSince1970: 100) })
    }

    private func preparedAllocation(_ workspace: MigrationFixtureWorkspace,
        _ coordinator: LibraryMigrationCoordinator) throws -> LibraryMigrationCoordinator.Allocation {
        _ = try workspace.materializeLegacySources()
        let persistence = LibraryPersistence(fileSystem: LocalFileSystem(), applicationSupportURL: workspace.applicationSupportURL)
        guard case let .legacy(snapshot) = try persistence.loadSnapshot() else { throw CocoaError(.fileReadCorruptFile) }
        let inventory = try coordinator.inventorySources(in: snapshot.library)
        let allocation = try coordinator.allocate(snapshot: snapshot, sources: inventory.profiles, existingJournal: nil)
        try coordinator.prepareControlState(journal: allocation.journal, originalBytes: snapshot.originalBytes)
        return allocation
    }

    private func updateLastLaunchedAt(_ workspace: MigrationFixtureWorkspace) throws {
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: workspace.libraryURL)) as? [String: Any])
        var applications = try XCTUnwrap(document["applications"] as? [[String: Any]])
        var profiles = try XCTUnwrap(applications[0]["profiles"] as? [[String: Any]])
        profiles[0]["lastLaunchedAt"] = 123456
        applications[0]["profiles"] = profiles
        document["applications"] = applications
        try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]).write(to: workspace.libraryURL)
    }
}
