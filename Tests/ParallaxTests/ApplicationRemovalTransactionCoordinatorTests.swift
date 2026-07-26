import Foundation
import XCTest
@testable import Parallax

final class ApplicationRemovalTransactionCoordinatorTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-ApplicationRemoval-\(UUID().uuidString)",
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

    func testArchiveStagesEveryProfileBeforeOneMetadataCommit() throws {
        let fixture = try makeFixture(choice: .archive, profileCount: 3)
        let trace = BoundaryTrace()
        let coordinator = try fixture.coordinator { boundary in
            trace.append(boundary)
        }

        let outcome = try coordinator.execute(
            fixture.transactionRequest,
            preparedCommit: fixture.preparedCommit,
            repository: fixture.repository
        )

        XCTAssertEqual(outcome.completion, .committed)
        XCTAssertEqual(outcome.dataChoice, .archive)
        XCTAssertEqual(outcome.archiveURLs.count, 3)
        XCTAssertEqual(try fixture.loadedApplications(), [])
        XCTAssertTrue(fixture.sourceURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        for profile in fixture.profiles {
            let archiveURL = try XCTUnwrap(
                outcome.archiveURLs[profile.storageID]
            )
            XCTAssertEqual(
                try String(
                    contentsOf: archiveURL.appendingPathComponent(
                        "payload.txt"
                    ),
                    encoding: .utf8
                ),
                profile.name
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.externalSentinelURL.path
            )
        )
        XCTAssertTrue(try coordinator.pendingTransactions().isEmpty)

        let stageIndices = trace.values.compactMap { boundary -> Int? in
            guard
                case .afterRecord(
                    .stageProfile(_, let index)
                ) = boundary
            else { return nil }
            return index
        }
        let commitIndex = try XCTUnwrap(
            trace.values.firstIndex {
                if case .beforeEffect(.commitMetadata) = $0 {
                    true
                } else {
                    false
                }
            }
        )
        XCTAssertEqual(stageIndices, [0, 1, 2])
        XCTAssertTrue(
            trace.values[..<commitIndex].contains {
                if case .afterRecord(.stageProfile(_, 2)) = $0 {
                    true
                } else {
                    false
                }
            }
        )
    }

    func testDeletePurgesOnlyManagedStagingAndPreservesExternalData()
        throws
    {
        let fixture = try makeFixture(choice: .delete, profileCount: 2)
        let coordinator = try fixture.coordinator()

        let outcome = try coordinator.execute(
            fixture.transactionRequest,
            preparedCommit: fixture.preparedCommit,
            repository: fixture.repository
        )

        XCTAssertEqual(outcome.completion, .committed)
        XCTAssertEqual(outcome.archiveURLs, [:])
        XCTAssertEqual(try fixture.loadedApplications(), [])
        XCTAssertTrue(fixture.sourceURLs.allSatisfy {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.externalSentinelURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.stagingRootURL.path
            )
        )
    }

    func testNthProfileFailureRollsBackAllPriorMovesAndMetadata()
        throws
    {
        let fixture = try makeFixture(choice: .delete, profileCount: 3)
        let coordinator = try fixture.coordinator { boundary in
            if case .beforeEffect(.stageProfile(_, 1)) = boundary {
                throw ApplicationRemovalTestError.injected
            }
        }

        XCTAssertThrowsError(
            try coordinator.execute(
                fixture.transactionRequest,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )

        XCTAssertEqual(try fixture.loadedApplications(), [fixture.application])
        try fixture.assertEverySourceRestored()
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.stagingRootURL.path
            )
        )
        XCTAssertTrue(try coordinator.pendingTransactions().isEmpty)
    }

    func testMetadataBoundaryFailureRollsBackEveryStagedProfile()
        throws
    {
        let fixture = try makeFixture(choice: .archive, profileCount: 3)
        let coordinator = try fixture.coordinator { boundary in
            if case .beforeEffect(.commitMetadata) = boundary {
                throw ApplicationRemovalTestError.injected
            }
        }

        XCTAssertThrowsError(
            try coordinator.execute(
                fixture.transactionRequest,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )

        XCTAssertEqual(try fixture.loadedApplications(), [fixture.application])
        try fixture.assertEverySourceRestored()
        XCTAssertTrue(
            fixture.expectedArchiveURLs.allSatisfy {
                !FileManager.default.fileExists(atPath: $0.path)
            }
        )
    }

    func testPreCommitCrashRecoveryRollsBackIdempotently() throws {
        let fixture = try makeFixture(choice: .delete, profileCount: 3)
        let crashing = try fixture.coordinator { boundary in
            if case .afterEffectBeforeRecord(
                .stageProfile(_, 1)
            ) = boundary {
                throw ApplicationRemovalTransactionInterruption
                    .simulatedCrash
            }
        }

        XCTAssertThrowsError(
            try crashing.execute(
                fixture.transactionRequest,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.sourceURLs[0].path
            )
        )

        let recovering = try fixture.coordinator()
        let first = try recovering.recover(
            transactionID: fixture.transactionID,
            repository: fixture.repository
        )
        let second = try recovering.recover(
            transactionID: fixture.transactionID,
            repository: fixture.repository
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.completion, .rolledBack)
        XCTAssertEqual(try fixture.loadedApplications(), [fixture.application])
        try fixture.assertEverySourceRestored()
        XCTAssertTrue(try recovering.pendingTransactions().isEmpty)
    }

    func testPostCommitCrashRecoveryFinishesOwnedDeleteIdempotently()
        throws
    {
        let fixture = try makeFixture(choice: .delete, profileCount: 2)
        let crashing = try fixture.coordinator { boundary in
            if case .afterRecord(.commitMetadata) = boundary {
                throw ApplicationRemovalTransactionInterruption
                    .simulatedCrash
            }
        }

        XCTAssertThrowsError(
            try crashing.execute(
                fixture.transactionRequest,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )
        XCTAssertEqual(try fixture.loadedApplications(), [])
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.stagingRootURL.path
            )
        )

        let recovering = try fixture.coordinator()
        let first = try recovering.recover(
            transactionID: fixture.transactionID,
            repository: fixture.repository
        )
        let second = try recovering.recover(
            transactionID: fixture.transactionID,
            repository: fixture.repository
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.completion, .committed)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.stagingRootURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.externalSentinelURL.path
            )
        )
    }

    @MainActor
    func testLibraryStoreStartupFinishesPendingPostCommitRemoval()
        throws
    {
        let fixture = try makeFixture(choice: .delete, profileCount: 2)
        let crashing = try fixture.coordinator { boundary in
            if case .afterRecord(.commitMetadata) = boundary {
                throw ApplicationRemovalTransactionInterruption
                    .simulatedCrash
            }
        }
        XCTAssertThrowsError(
            try crashing.execute(
                fixture.transactionRequest,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.stagingRootURL.path
            )
        )

        let suiteName =
            "Parallax.ApplicationRemoval.Startup.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(
            UserDefaults(suiteName: suiteName)
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let recovering = try fixture.coordinator()
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: fixture.appSupportURL
            ),
            repository: fixture.repository,
            applicationRemovalTransactions: recovering,
            settings: AppSettings(userDefaults: defaults)
        )

        XCTAssertEqual(store.applications, [])
        if case .loaded = store.loadState {
            // Expected.
        } else {
            XCTFail("Store did not finish startup recovery.")
        }
        XCTAssertTrue(try recovering.pendingTransactions().isEmpty)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.stagingRootURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.externalSentinelURL.path
            )
        )
    }

    func testPostCommitDeleteRefusesUnownedStagedData() throws {
        let fixture = try makeFixture(choice: .delete, profileCount: 1)
        let crashing = try fixture.coordinator { boundary in
            if case .afterRecord(.commitMetadata) = boundary {
                throw ApplicationRemovalTransactionInterruption
                    .simulatedCrash
            }
        }
        XCTAssertThrowsError(
            try crashing.execute(
                fixture.transactionRequest,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )

        let stagedProfile = fixture.stagingRootURL
            .appendingPathComponent(
                fixture.profiles[0].storageID.uuidString.lowercased(),
                isDirectory: true
            )
        let ownerFiles = try FileManager.default.contentsOfDirectory(
            at: stagedProfile,
            includingPropertiesForKeys: nil
        ).filter {
            $0.lastPathComponent.hasPrefix(".parallax-owner-")
        }
        XCTAssertEqual(ownerFiles.count, 1)
        try FileManager.default.removeItem(at: ownerFiles[0])
        let intruder = stagedProfile.appendingPathComponent("intruder.txt")
        try Data("not-owned".utf8).write(to: intruder)

        let recovering = try fixture.coordinator()
        XCTAssertThrowsError(
            try recovering.recover(
                transactionID: fixture.transactionID,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? ApplicationRemovalTransactionError)?.code,
                .unownedStagedData
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: intruder.path)
        )
        XCTAssertEqual(try fixture.loadedApplications(), [])
    }

    func testCanonicalTargetOutsideStorageNamespaceIsRejected()
        throws
    {
        let fixture = try makeFixture(choice: .archive, profileCount: 1)
        let original = fixture.targets[0]
        let invalid = ApplicationRemovalProfileTarget(
            profileID: original.profileID,
            profileStorageID: original.profileStorageID,
            profileName: original.profileName,
            managedProfileRoot: DestructiveActionPathSnapshot(
                canonicalURL: fixture.managedRootURL
                    .appendingPathComponent("outside", isDirectory: true),
                fileIdentity: original.managedProfileRoot.fileIdentity
            ),
            externalPaths: original.externalPaths
        )
        let request = ApplicationRemovalTransactionRequest(
            transactionID: fixture.transactionID,
            executionAuthorization: fixture.executionAuthorization,
            profiles: [invalid]
        )
        let coordinator = try fixture.coordinator()

        XCTAssertThrowsError(
            try coordinator.execute(
                request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? ApplicationRemovalTransactionError)?.code,
                .invalidTarget
            )
        }
        XCTAssertEqual(try fixture.loadedApplications(), [fixture.application])
        try fixture.assertEverySourceRestored()
    }

    func testIdentityBearingSourceRemovedBeforePlanningAbortsMetadataCommit()
        throws
    {
        let fixture = try makeFixture(choice: .delete, profileCount: 1)
        try FileManager.default.removeItem(at: fixture.sourceURLs[0])
        let coordinator = try fixture.coordinator()

        XCTAssertThrowsError(
            try coordinator.execute(
                fixture.transactionRequest,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? ApplicationRemovalTransactionError)?.code,
                .targetChanged
            )
        }
        XCTAssertEqual(
            try fixture.loadedApplications(),
            [fixture.application]
        )
        XCTAssertTrue(try coordinator.pendingTransactions().isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.externalSentinelURL.path
            )
        )
    }

    private func makeFixture(
        choice: ApplicationRemovalDataChoice,
        profileCount: Int
    ) throws -> ApplicationRemovalTransactionFixture {
        let appSupportURL = temporaryDirectory.appendingPathComponent(
            "ApplicationSupport",
            isDirectory: true
        )
        let managedRootURL = temporaryDirectory.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: appSupportURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: managedRootURL,
            withIntermediateDirectories: true
        )

        let applicationID = UUID()
        let applicationStorageID = UUID()
        let profiles = (0..<profileCount).map {
            LaunchProfile(
                id: UUID(),
                storageID: UUID(),
                name: "Profile \($0 + 1)"
            )
        }
        let application = ManagedApplication(
            id: applicationID,
            storageID: applicationStorageID,
            displayName: "Chromium",
            appPath: "/Applications/Chromium.app",
            baseStoragePath: managedRootURL.path,
            profiles: profiles
        )
        let sourceURLs = profiles.map {
            managedRootURL
                .appendingPathComponent(".parallax", isDirectory: true)
                .appendingPathComponent("Applications", isDirectory: true)
                .appendingPathComponent(
                    applicationStorageID.uuidString.lowercased(),
                    isDirectory: true
                )
                .appendingPathComponent("Profiles", isDirectory: true)
                .appendingPathComponent(
                    $0.storageID.uuidString.lowercased(),
                    isDirectory: true
                )
        }
        for (profile, sourceURL) in zip(profiles, sourceURLs) {
            try FileManager.default.createDirectory(
                at: sourceURL,
                withIntermediateDirectories: true
            )
            try profile.name.write(
                to: sourceURL.appendingPathComponent("payload.txt"),
                atomically: true,
                encoding: .utf8
            )
        }

        let externalRoot = temporaryDirectory.appendingPathComponent(
            "External",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: externalRoot,
            withIntermediateDirectories: true
        )
        let externalSentinel = externalRoot.appendingPathComponent(
            "keep.txt"
        )
        try "external".write(
            to: externalSentinel,
            atomically: true,
            encoding: .utf8
        )

        let repository = LibraryRepository(
            applicationSupportURL: appSupportURL
        )
        let snapshot = try repository.save(
            [application],
            expectedVersion: .missing
        )
        let targets = try zip(profiles, sourceURLs).map {
            profile,
            sourceURL in
            let attributes = try LocalFileSystem().attributesOfItem(
                at: sourceURL
            )
            return ApplicationRemovalProfileTarget(
                profileID: profile.id,
                profileStorageID: profile.storageID,
                profileName: profile.name,
                managedProfileRoot: DestructiveActionPathSnapshot(
                    canonicalURL: sourceURL,
                    fileIdentity: attributes.identity
                ),
                externalPaths: [
                    ApplicationRemovalExternalPath(
                        role: .userData,
                        declaredPath: externalRoot.path
                    )
                ]
            )
        }
        let request = try ApplicationRemovalRequest(
            requestID: UUID(),
            sceneID: UUID(),
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            applicationName: application.displayName,
            profiles: targets,
            dataChoice: choice,
            repositoryVersion: snapshot.versionToken
        )
        let backup = LibraryRecoveryArtifact(
            id: UUID(),
            kind: .backup,
            reason: .destructiveRewrite,
            content: .currentLibrary,
            createdAt: Date(timeIntervalSince1970: 1),
            libraryURL: appSupportURL.appendingPathComponent(
                "verified-backup.json"
            ),
            byteCount: snapshot.originalBytes.count,
            sha256: try XCTUnwrap(
                snapshot.versionToken.primarySHA256
            )
        )
        let priorBackup = try request.acceptPriorBackup(backup)
        let current = ApplicationRemovalCurrentTarget(
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            applicationName: application.displayName,
            profiles: targets,
            repositoryVersion: snapshot.versionToken
        )
        let activity = ApplicationRemovalActivitySnapshot(
            profiles: targets.map {
                ApplicationRemovalProfileActivity(
                    applicationID: applicationID,
                    applicationStorageID: applicationStorageID,
                    profileID: $0.profileID,
                    profileStorageID: $0.profileStorageID,
                    state: .inactive
                )
            }
        )
        let execution = try request.authorizeExecution(
            currentTarget: current,
            activity: activity,
            priorBackup: priorBackup
        )
        let prepared = try repository.prepare(
            [],
            expectedVersion: snapshot.versionToken
        )
        let transactionID = UUID()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        return ApplicationRemovalTransactionFixture(
            appSupportURL: appSupportURL,
            managedRootURL: managedRootURL,
            application: application,
            profiles: profiles,
            sourceURLs: sourceURLs,
            targets: targets,
            executionAuthorization: execution,
            repository: repository,
            preparedCommit: prepared,
            transactionID: transactionID,
            timestamp: timestamp,
            externalSentinelURL: externalSentinel
        )
    }
}

private enum ApplicationRemovalTestError: Error {
    case injected
}

private final class BoundaryTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ApplicationRemovalTransactionBoundary] = []

    var values: [ApplicationRemovalTransactionBoundary] {
        lock.withLock { storage }
    }

    func append(_ value: ApplicationRemovalTransactionBoundary) {
        lock.withLock {
            storage.append(value)
        }
    }
}

private struct ApplicationRemovalTransactionFixture {
    let appSupportURL: URL
    let managedRootURL: URL
    let application: ManagedApplication
    let profiles: [LaunchProfile]
    let sourceURLs: [URL]
    let targets: [ApplicationRemovalProfileTarget]
    let executionAuthorization: ApplicationRemovalExecutionAuthorization
    let repository: LibraryRepository
    let preparedCommit: PreparedLibraryCommit
    let transactionID: UUID
    let timestamp: Date
    let externalSentinelURL: URL

    var transactionRequest: ApplicationRemovalTransactionRequest {
        ApplicationRemovalTransactionRequest(
            transactionID: transactionID,
            executionAuthorization: executionAuthorization,
            profiles: targets
        )
    }

    var stagingRootURL: URL {
        managedRootURL
            .appendingPathComponent(".parallax", isDirectory: true)
            .appendingPathComponent(
                "ApplicationRemovalTransactions",
                isDirectory: true
            )
            .appendingPathComponent(
                transactionID.uuidString.lowercased(),
                isDirectory: true
            )
    }

    var expectedArchiveURLs: [URL] {
        profiles.map {
            managedRootURL
                .appendingPathComponent(".parallax", isDirectory: true)
                .appendingPathComponent("Archives", isDirectory: true)
                .appendingPathComponent(
                    application.storageID.uuidString.lowercased(),
                    isDirectory: true
                )
                .appendingPathComponent(
                    $0.storageID.uuidString.lowercased(),
                    isDirectory: true
                )
                .appendingPathComponent(
                    "1700000000000-\(transactionID.uuidString.lowercased())",
                    isDirectory: true
                )
        }
    }

    func coordinator(
        boundary:
            (@Sendable (ApplicationRemovalTransactionBoundary) throws -> Void)?
            = nil
    ) throws -> ApplicationRemovalTransactionCoordinator {
        try ApplicationRemovalTransactionCoordinator(
            applicationSupportURL: appSupportURL,
            now: { timestamp },
            transactionBoundary: boundary
        )
    }

    func loadedApplications() throws -> [ManagedApplication] {
        guard case .loaded(let snapshot) = repository.load() else {
            throw ApplicationRemovalTestError.injected
        }
        return snapshot.applications
    }

    func assertEverySourceRestored(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for (profile, sourceURL) in zip(profiles, sourceURLs) {
            XCTAssertEqual(
                try String(
                    contentsOf: sourceURL.appendingPathComponent(
                        "payload.txt"
                    ),
                    encoding: .utf8
                ),
                profile.name,
                file: file,
                line: line
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: externalSentinelURL.path
            ),
            file: file,
            line: line
        )
    }
}
