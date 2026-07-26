import Foundation
import XCTest
@testable import Parallax

final class LibraryMigrationRecoveryHardeningTests: XCTestCase {
    private var workspaces: [MigrationFixtureWorkspace] = []

    override func tearDownWithError() throws {
        workspaces.forEach { $0.remove() }
        workspaces.removeAll()
    }

    func testSuccessfulReplaceFollowedByThirdPartyBytesDoesNotFinalizeReceipt() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let deterministic = ids(suffix: 201, profileCount: 1)
        let paths = workspace.assertableStateURLs(migrationID: deterministic[0])
        let thirdPartyBytes = Data(#"{"thirdPartyWriter":true}"#.utf8)
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        fileSystem.afterOperation = { event in
            guard event.operation == .replaceItem else { return }
            try thirdPartyBytes.write(to: workspace.libraryURL, options: .atomic)
        }

        XCTAssertThrowsError(
            try coordinator(
                workspace: workspace,
                fileSystem: fileSystem,
                uuids: deterministic
            ).migrateIfNeeded()
        ) { error in
            XCTAssertEqual(error as? LibraryMigrationError, .recoveryConflict)
        }

        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), thirdPartyBytes)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.receipt.path),
            "A receipt must not claim completion when post-replace bytes do not match v2."
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: paths.journal.path))
    }

    func testCommittedRecoveryRefusesMissingOrMutatedPublishedDestination() throws {
        for mutation in PublishedDestinationMutation.allCases {
            let workspace = try makeWorkspace()
            _ = try workspace.installFixture(named: "valid-v1-library.json")
            _ = try workspace.materializeLegacySources()
            let deterministic = ids(
                suffix: 210 + mutation.rawValue,
                profileCount: 1
            )
            let migrationID = deterministic[0]
            let destination = v2ProfileURL(
                workspace: workspace,
                applicationStorageID: deterministic[1],
                profileStorageID: deterministic[2]
            )
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
            XCTAssertNoThrow(
                try LibraryPersistence.decodeApplications(
                    from: Data(contentsOf: workspace.libraryURL)
                )
            )

            switch mutation {
            case .missing:
                try FileManager.default.removeItem(at: destination)
            case .mutated:
                try Data("unowned-post-commit-change".utf8).write(
                    to: destination.appendingPathComponent("mutation.sentinel")
                )
            }

            XCTAssertThrowsError(
                try coordinator(
                    workspace: workspace,
                    uuids: ids(suffix: 999, profileCount: 1)
                ).migrateIfNeeded(),
                "Committed recovery must verify a \(mutation) destination."
            ) { error in
                XCTAssertEqual(error as? LibraryMigrationError, .recoveryConflict)
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: workspace
                        .assertableStateURLs(migrationID: migrationID)
                        .receipt.path
                )
            )
        }
    }

    func testOwnerAndPublishedDestinationAreDurableBeforeLibraryReplace() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let deterministic = ids(suffix: 220, profileCount: 1)
        let destination = v2ProfileURL(
            workspace: workspace,
            applicationStorageID: deterministic[1],
            profileStorageID: deterministic[2]
        )
        let owner = ownerMarkerURL(
            destination: destination,
            applicationStorageID: deterministic[1],
            profileStorageID: deterministic[2]
        )
        let fileSystem = MigrationOccurrenceFailingFileSystem()

        _ = try coordinator(
            workspace: workspace,
            fileSystem: fileSystem,
            uuids: deterministic
        ).migrateIfNeeded()

        let events = fileSystem.events
        let ownerWrite = try eventIndex(
            in: events,
            operation: .writeData,
            firstURL: owner
        )
        let ownerSync = try eventIndex(
            in: events,
            operation: .synchronize,
            firstURL: owner
        )
        let ownerParentSync = try eventIndex(
            in: events,
            operation: .synchronize,
            firstURL: owner.deletingLastPathComponent(),
            after: ownerSync
        )
        let destinationPublish = try eventIndex(
            in: events,
            operation: .moveItem,
            secondURL: destination
        )
        let destinationSync = try eventIndex(
            in: events,
            operation: .synchronize,
            firstURL: destination,
            after: destinationPublish
        )
        let destinationParentSync = try eventIndex(
            in: events,
            operation: .synchronize,
            firstURL: destination.deletingLastPathComponent(),
            after: destinationSync
        )
        let replace = try eventIndex(in: events, operation: .replaceItem)

        XCTAssertLessThan(ownerWrite, ownerSync)
        XCTAssertLessThan(ownerSync, ownerParentSync)
        XCTAssertLessThan(ownerParentSync, destinationPublish)
        XCTAssertLessThan(destinationPublish, destinationSync)
        XCTAssertLessThan(destinationSync, destinationParentSync)
        XCTAssertLessThan(destinationParentSync, replace)
    }

    func testPublishedDestinationWithoutOwnerMarkerRecoversWithJournaledIDs() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(
            named: "valid-v1-library.json"
        )
        _ = try workspace.materializeLegacySources()
        let deterministic = ids(suffix: 230, profileCount: 1)
        let migrationID = deterministic[0]
        let destination = v2ProfileURL(
            workspace: workspace,
            applicationStorageID: deterministic[1],
            profileStorageID: deterministic[2]
        )
        let owner = ownerMarkerURL(
            destination: destination,
            applicationStorageID: deterministic[1],
            profileStorageID: deterministic[2]
        )
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        fileSystem.afterOperation = { event in
            guard
                event.operation == .moveItem,
                event.secondURL?.standardizedFileURL
                    == destination.standardizedFileURL
            else {
                return
            }
            try FileManager.default.removeItem(at: owner)
            throw RecoveryHardeningInjectedError.simulatedCrash
        }

        XCTAssertThrowsError(
            try coordinator(
                workspace: workspace,
                fileSystem: fileSystem,
                uuids: deterministic
            ).migrateIfNeeded()
        )
        let journal = workspace
            .assertableStateURLs(migrationID: migrationID)
            .journal
        let journalBytes = try Data(contentsOf: journal)
        let destinationBytes = try workspace.allRegularFileBytes(under: destination)

        let recoveryOutcome = try coordinator(
            workspace: workspace,
            uuids: ids(suffix: 998, profileCount: 1)
        ).migrateIfNeeded()
        let recoveredApplications = try migratedApplications(
            from: recoveryOutcome
        )

        XCTAssertNotEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
        XCTAssertEqual(recoveredApplications.first?.storageID, deterministic[1])
        XCTAssertEqual(
            recoveredApplications.first?.profiles.first?.storageID,
            deterministic[2]
        )
        XCTAssertEqual(
            try workspace.allRegularFileBytes(under: destination),
            destinationBytes
        )
        let journalText = try XCTUnwrap(
            String(data: journalBytes, encoding: .utf8)
        )
        XCTAssertTrue(journalText.contains(deterministic[1].uuidString.lowercased()))
        XCTAssertTrue(journalText.contains(deterministic[2].uuidString.lowercased()))
    }

    func testRollbackRemovalFailureLeavesRecoverableStateAndRetryUsesSameIDs() throws {
        let workspace = try makeWorkspace()
        _ = try workspace.installFixture(named: "valid-v1-library.json")
        _ = try workspace.materializeLegacySources()
        let deterministic = ids(suffix: 240, profileCount: 1)
        let migrationID = deterministic[0]
        let destination = v2ProfileURL(
            workspace: workspace,
            applicationStorageID: deterministic[1],
            profileStorageID: deterministic[2]
        )
        let fileSystem = MigrationOccurrenceFailingFileSystem(
            failureRule: .init(.removeItem, occurrence: 1, timing: .before)
        )
        fileSystem.afterOperation = { event in
            guard
                event.operation == .moveItem,
                event.secondURL?.standardizedFileURL
                    == destination.standardizedFileURL
            else {
                return
            }
            throw RecoveryHardeningInjectedError.simulatedCrash
        }

        XCTAssertThrowsError(
            try coordinator(
                workspace: workspace,
                fileSystem: fileSystem,
                uuids: deterministic
            ).migrateIfNeeded()
        )
        let journal = workspace
            .assertableStateURLs(migrationID: migrationID)
            .journal
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.path))

        let outcome = try coordinator(
            workspace: workspace,
            uuids: ids(suffix: 997, profileCount: 1)
        ).migrateIfNeeded()
        let applications = try migratedApplications(from: outcome)

        XCTAssertEqual(applications.first?.storageID, deterministic[1])
        XCTAssertEqual(
            applications.first?.profiles.first?.storageID,
            deterministic[2]
        )
    }

    func testHostileJournalOutsideDecodedBaseIsRejectedWithoutProbeOrMutation() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(
            named: "valid-v1-library.json"
        )
        _ = try workspace.materializeLegacySources()
        let deterministic = ids(suffix: 250, profileCount: 1)
        let migrationID = deterministic[0]
        let failingFileSystem = MigrationOccurrenceFailingFileSystem(
            failureRule: .init(.copyItem, occurrence: 1, timing: .after)
        )
        XCTAssertThrowsError(
            try coordinator(
                workspace: workspace,
                fileSystem: failingFileSystem,
                uuids: deterministic
            ).migrateIfNeeded()
        )

        let hostileBase = workspace.externalRootURL.appendingPathComponent(
            "HostileJournalBase",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: hostileBase,
            withIntermediateDirectories: true
        )
        let externalSentinel = hostileBase.appendingPathComponent("external.sentinel")
        let externalBytes = Data("outside-journal-target".utf8)
        try externalBytes.write(to: externalSentinel)
        let hostileDestination = v2ProfileURL(
            baseRoot: hostileBase,
            applicationStorageID: deterministic[1],
            profileStorageID: deterministic[2]
        )
        let journal = workspace
            .assertableStateURLs(migrationID: migrationID)
            .journal
        var journalObject = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: journal)
            ) as? [String: Any]
        )
        var mappings = try XCTUnwrap(
            journalObject["mappings"] as? [[String: Any]]
        )
        mappings[0]["newCanonicalPath"] = hostileDestination.path
        journalObject["mappings"] = mappings
        let hostileJournalBytes = try JSONSerialization.data(
            withJSONObject: journalObject,
            options: [.prettyPrinted, .sortedKeys]
        )
        try hostileJournalBytes.write(to: journal, options: .atomic)
        let recordingFileSystem = MigrationOccurrenceFailingFileSystem()

        XCTAssertThrowsError(
            try coordinator(
                workspace: workspace,
                fileSystem: recordingFileSystem,
                uuids: ids(suffix: 996, profileCount: 1)
            ).migrateIfNeeded()
        ) { error in
            XCTAssertEqual(error as? LibraryMigrationError, .invalidJournal)
        }

        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: externalSentinel), externalBytes)
        XCTAssertFalse(
            recordingFileSystem.events.contains {
                isUnder($0.firstURL, root: hostileBase)
                    || isUnder($0.secondURL, root: hostileBase)
            },
            "Journal paths outside the decoded base must be rejected before probing."
        )
    }

    func testSymlinkSwapAtCopyOrPublishParentsNeverWritesExternalData() throws {
        for target in SymlinkSwapTarget.allCases {
            let workspace = try makeWorkspace()
            let originalBytes = try workspace.installFixture(
                named: "valid-v1-library.json"
            )
            _ = try workspace.materializeLegacySources()
            let deterministic = ids(
                suffix: 260 + target.rawValue,
                profileCount: 1
            )
            let external = workspace.externalRootURL.appendingPathComponent(
                "swap-\(target)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: external,
                withIntermediateDirectories: true
            )
            let swapped = RecoveryAtomicFlag()
            let fileSystem = MigrationOccurrenceFailingFileSystem()
            fileSystem.beforeOperation = { event in
                guard let parent = target.parentToSwap(for: event) else {
                    return
                }
                try swapped.runOnce {
                    if FileManager.default.fileExists(atPath: parent.path) {
                        try FileManager.default.removeItem(at: parent)
                    }
                    try FileManager.default.createSymbolicLink(
                        at: parent,
                        withDestinationURL: external
                    )
                }
            }

            XCTAssertThrowsError(
                try coordinator(
                    workspace: workspace,
                    fileSystem: fileSystem,
                    uuids: deterministic
                ).migrateIfNeeded(),
                "The \(target) symlink swap must abort migration."
            )

            XCTAssertTrue(swapped.hasRun, "The \(target) hook did not execute.")
            XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(
                    at: external,
                    includingPropertiesForKeys: nil
                ).isEmpty,
                "The \(target) swap redirected a mutation outside managed staging."
            )
        }
    }

    func testConflictingSplitAndEqualsUserDataArgumentsRemainByteForByte() throws {
        let workspace = try makeWorkspace()
        let oldUserData = workspace.managedRootURL
            .appendingPathComponent(
                "Fixture-Browser/Personal/UserData",
                isDirectory: true
            )
            .path
        let arguments =
            "--user-data-dir /explicit/external/split-form "
            + "--user-data-dir=\(oldUserData) "
            + "--opaque=unchanged"
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
                uuids: ids(suffix: 270, profileCount: 1)
            ).migrateIfNeeded()
        )

        XCTAssertEqual(
            applications.first?.profiles.first?.argumentsText,
            arguments,
            "Ambiguous singleton syntax must be preserved wholesale for later review."
        )
    }

    func testLegacyApplicationRootRegularFileBlocksWithZeroWrites() throws {
        let workspace = try makeWorkspace()
        let originalBytes = try workspace.installFixture(
            named: "valid-v1-library.json"
        )
        let applicationRoot = workspace.managedRootURL.appendingPathComponent(
            "Fixture-Browser",
            isDirectory: false
        )
        let applicationRootBytes = Data("legacy-app-root-is-a-file".utf8)
        try applicationRootBytes.write(to: applicationRoot)
        let fileSystem = MigrationOccurrenceFailingFileSystem()

        let outcome = try coordinator(
            workspace: workspace,
            fileSystem: fileSystem,
            uuids: ids(suffix: 280, profileCount: 1)
        ).migrateIfNeeded()
        guard case let .requiresResolution(plan) = outcome else {
            return XCTFail("A legacy application root file must block migration.")
        }

        XCTAssertTrue(plan.blockers.contains { $0.kind == .unsupportedSourceItem })
        XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
        XCTAssertEqual(try Data(contentsOf: applicationRoot), applicationRootBytes)
        XCTAssertFalse(
            fileSystem.events.contains {
                Self.mutatingOperations.contains($0.operation)
            }
        )
    }

    func testMultiProfileNthCopyAndPublicationAfterActionFailuresRecoverDeterministically() throws {
        for failure in MultiProfileFailure.allCases {
            let workspace = try makeWorkspace()
            let originalBytes = try installThreeProfileFixture(in: workspace)
            let sourceSentinels = try workspace.materializeLegacySources()
            let deterministic = ids(
                suffix: 290 + failure.rawValue,
                profileCount: 3
            )
            let secondDestination = v2ProfileURL(
                workspace: workspace,
                applicationStorageID: deterministic[1],
                profileStorageID: deterministic[3]
            )
            let fileSystem: MigrationOccurrenceFailingFileSystem
            switch failure {
            case .nthCopyBefore:
                fileSystem = MigrationOccurrenceFailingFileSystem(
                    failureRule: .init(
                        .copyItem,
                        occurrence: 3,
                        timing: .before
                    )
                )
            case .nthCopyAfter:
                fileSystem = MigrationOccurrenceFailingFileSystem(
                    failureRule: .init(
                        .copyItem,
                        occurrence: 3,
                        timing: .after
                    )
                )
            case .nthPublicationAfter:
                fileSystem = MigrationOccurrenceFailingFileSystem()
                fileSystem.afterOperation = { event in
                    guard
                        event.operation == .moveItem,
                        event.secondURL?.standardizedFileURL
                            == secondDestination.standardizedFileURL
                    else {
                        return
                    }
                    throw RecoveryHardeningInjectedError.simulatedCrash
                }
            }

            XCTAssertThrowsError(
                try coordinator(
                    workspace: workspace,
                    fileSystem: fileSystem,
                    uuids: deterministic
                ).migrateIfNeeded(),
                "Expected injected \(failure) failure."
            )
            XCTAssertEqual(try Data(contentsOf: workspace.libraryURL), originalBytes)
            for (source, bytes) in sourceSentinels {
                XCTAssertEqual(try Data(contentsOf: source), bytes)
            }

            let outcome = try coordinator(
                workspace: workspace,
                uuids: ids(suffix: 995, profileCount: 3)
            ).migrateIfNeeded()
            let applications = try migratedApplications(from: outcome)
            XCTAssertEqual(applications.first?.storageID, deterministic[1])
            XCTAssertEqual(
                applications.first?.profiles.map(\.storageID),
                Array(deterministic[2...4])
            )
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

    private func installThreeProfileFixture(
        in workspace: MigrationFixtureWorkspace
    ) throws -> Data {
        try workspace.installFixture(
            named: "valid-v1-library.json"
        ) { object in
            var document = try XCTUnwrap(object as? [String: Any])
            var applications = try XCTUnwrap(
                document["applications"] as? [[String: Any]]
            )
            var profiles = try XCTUnwrap(
                applications[0]["profiles"] as? [[String: Any]]
            )
            var second = profiles[0]
            second["id"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa2"
            second["name"] = "Second"
            second["storageName"] = "Second"
            second["argumentsText"] = ""
            var third = profiles[0]
            third["id"] = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa3"
            third["name"] = "Third"
            third["storageName"] = "Third"
            third["argumentsText"] = ""
            profiles.append(second)
            profiles.append(third)
            applications[0]["profiles"] = profiles
            document["applications"] = applications
            object = document
        }
    }

    private func ids(suffix: Int, profileCount: Int) -> [UUID] {
        (0..<(2 + profileCount)).compactMap { index in
            UUID(
                uuidString: String(
                    format: "%08x-0000-4000-8000-%012x",
                    0x7100_0000 + index,
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
        v2ProfileURL(
            baseRoot: workspace.managedRootURL,
            applicationStorageID: applicationStorageID,
            profileStorageID: profileStorageID
        )
    }

    private func v2ProfileURL(
        baseRoot: URL,
        applicationStorageID: UUID,
        profileStorageID: UUID
    ) -> URL {
        baseRoot
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

    private func ownerMarkerURL(
        destination: URL,
        applicationStorageID: UUID,
        profileStorageID: UUID
    ) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".\(profileStorageID.uuidString.lowercased())."
                + "\(applicationStorageID.uuidString.lowercased()).owner"
        )
    }

    private func eventIndex(
        in events: [MigrationOccurrenceFailingFileSystem.Event],
        operation: MigrationOccurrenceFailingFileSystem.Operation,
        firstURL: URL? = nil,
        secondURL: URL? = nil,
        after minimumIndex: Int = -1
    ) throws -> Int {
        try XCTUnwrap(
            events.indices.first { index in
                guard index > minimumIndex else { return false }
                let event = events[index]
                guard event.operation == operation else { return false }
                if let firstURL {
                    guard event.firstURL?.standardizedFileURL
                        == firstURL.standardizedFileURL else {
                        return false
                    }
                }
                if let secondURL {
                    guard event.secondURL?.standardizedFileURL
                        == secondURL.standardizedFileURL else {
                        return false
                    }
                }
                return true
            },
            "Missing \(operation) event for \(firstURL?.path ?? secondURL?.path ?? "*")."
        )
    }

    private func isUnder(_ candidate: URL?, root: URL) -> Bool {
        guard let candidate else { return false }
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.starts(with: rootComponents)
    }
}

private enum PublishedDestinationMutation: Int, CaseIterable {
    case missing
    case mutated
}

private enum MultiProfileFailure: Int, CaseIterable {
    case nthCopyBefore
    case nthCopyAfter
    case nthPublicationAfter
}

private enum SymlinkSwapTarget: Int, CaseIterable, CustomStringConvertible {
    case sourceCopies
    case publishCopies
    case profiles

    var description: String {
        switch self {
        case .sourceCopies:
            "SourceCopies"
        case .publishCopies:
            "PublishCopies"
        case .profiles:
            "Profiles"
        }
    }

    func parentToSwap(
        for event: MigrationOccurrenceFailingFileSystem.Event
    ) -> URL? {
        switch self {
        case .sourceCopies:
            guard
                event.operation == .copyItem,
                event.secondURL?.deletingLastPathComponent().lastPathComponent
                    == "SourceCopies"
            else {
                return nil
            }
            return event.secondURL?.deletingLastPathComponent()
        case .publishCopies:
            guard
                event.operation == .copyItem,
                event.secondURL?.deletingLastPathComponent().lastPathComponent
                    == "PublishCopies"
            else {
                return nil
            }
            return event.secondURL?.deletingLastPathComponent()
        case .profiles:
            guard
                event.operation == .writeData,
                event.firstURL?.pathExtension == "owner"
            else {
                return nil
            }
            return event.firstURL?.deletingLastPathComponent()
        }
    }
}

private enum RecoveryHardeningInjectedError: Error {
    case simulatedCrash
}

private final class RecoveryAtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var ran = false

    var hasRun: Bool {
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
