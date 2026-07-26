import Foundation
import XCTest
@testable import Parallax

final class StorageRelocationTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testPreviewUsesCanonicalApplicationPathsAndPreservesExplicitIsolation() throws {
        let fixture = try makeFixture()
        var application = fixture.application
        var profile = application.profiles[0]
        profile.argumentsText += " --explicit-flag"
        profile.environmentText += "\nEXTERNAL_ROOT=/Volumes/External/Profile"
        profile.isolationOwnership = ProfileIsolationOwnership(
            userData: .generated,
            codexHome: .explicit
        )
        profile.environmentText = "CODEX_HOME=/Volumes/External/Codex\nEXTERNAL_ROOT=value"
        application.profiles[0] = profile

        let preview = try fixture.coordinator.prepare(
            application: application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )

        XCTAssertEqual(
            preview.source.applicationRoot.url,
            fixture.sourcePaths.applicationRoot.url
        )
        XCTAssertEqual(
            preview.destination.applicationRoot.url,
            fixture.destinationPaths.applicationRoot.url
        )
        XCTAssertEqual(preview.generatedRewrites.map(\.field), [.userData])
        XCTAssertEqual(preview.preservedExternalPaths.map(\.value), [
            "/Volumes/External/Codex",
        ])
        XCTAssertTrue(
            preview.relocatedApplication.profiles[0].argumentsText.contains(
                fixture.destinationProfilePaths.userData.url.path
            )
        )
        XCTAssertTrue(
            preview.relocatedApplication.profiles[0].environmentText.contains(
                "CODEX_HOME=/Volumes/External/Codex"
            )
        )
        XCTAssertEqual(
            preview.relocatedApplication.profiles[0].isolationOwnership.codexHome,
            .explicit
        )
    }

    func testPreviewBlocksUnexpectedDestinationAndActiveProfile() throws {
        let activity = TestRelocationActivityProvider()
        let fixture = try makeFixture(activityProvider: activity)
        try FileManager.default.createDirectory(
            at: fixture.destinationPaths.applicationRoot.url,
            withIntermediateDirectories: true
        )
        activity.activeProfileStorageIDs = [
            fixture.application.profiles[0].storageID
        ]

        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )

        XCTAssertTrue(preview.blockers.contains(.unexpectedDestination))
        XCTAssertTrue(
            preview.blockers.contains(
                .activeProfiles([fixture.application.profiles[0].id])
            )
        )
    }

    func testExecutionRechecksActivityAndVersion() throws {
        let activity = TestRelocationActivityProvider()
        let fixture = try makeFixture(activityProvider: activity)
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        let prepared = try fixture.preparedCommit(for: preview)

        activity.activeProfileStorageIDs = [
            fixture.application.profiles[0].storageID
        ]
        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                preview,
                preparedCommit: prepared,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? StorageRelocationError)?.code,
                .activeProfile
            )
        }

        activity.activeProfileStorageIDs = []
        var changed = fixture.snapshot.applications
        changed[0].displayName = "Changed by another writer"
        _ = try fixture.repository.save(
            changed,
            expectedVersion: fixture.version
        )
        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                preview,
                preparedCommit: prepared,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? StorageRelocationError)?.code,
                .stalePreview
            )
        }
    }

    func testSuccessfulRelocationMovesApplicationAndArchiveData() throws {
        let fixture = try makeFixture(createSourceData: true)
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        let prepared = try fixture.preparedCommit(for: preview)

        let outcome = try fixture.coordinator.execute(
            preview,
            preparedCommit: prepared,
            repository: fixture.repository
        )

        XCTAssertEqual(outcome.application, preview.relocatedApplication)
        XCTAssertEqual(outcome.versionToken, prepared.targetVersion)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destinationPaths.applicationRoot.url
                    .appendingPathComponent("profile-data.txt").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destinationPaths.applicationArchiveRoot.url
                    .appendingPathComponent("archive-data.txt").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.sourcePaths.applicationRoot.url.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.sourcePaths.applicationArchiveRoot.url.path
            )
        )
        guard case let .loaded(committed) = fixture.repository.load() else {
            return XCTFail("Expected committed library")
        }
        XCTAssertEqual(committed.versionToken, prepared.targetVersion)
        XCTAssertEqual(
            committed.applications.first,
            preview.relocatedApplication
        )
    }

    func testMetadataFailureRollsPublishedDataBackToSource() throws {
        let fixture = try makeFixture(createSourceData: true)
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        let failingRepository = LibraryRepository(
            applicationSupportURL: fixture.repositorySupportURL,
            backupHook: { _, _ in throw TestError.injected }
        )
        let prepared = try failingRepository.prepare(
            [preview.relocatedApplication],
            expectedVersion: fixture.version
        )

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                preview,
                preparedCommit: prepared,
                repository: failingRepository
            )
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.sourcePaths.applicationRoot.url
                    .appendingPathComponent("profile-data.txt").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.sourcePaths.applicationArchiveRoot.url
                    .appendingPathComponent("archive-data.txt").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationPaths.applicationRoot.url.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationPaths.applicationArchiveRoot.url.path
            )
        )
    }

    func testEveryTransactionBoundaryFailureHasDeterministicRecovery() throws {
        let suiteDirectory = temporaryDirectory
        defer { temporaryDirectory = suiteDirectory }

        for failurePoint in RelocationFailurePoint.allCases {
            temporaryDirectory = suiteDirectory.appendingPathComponent(
                failurePoint.rawValue,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: true
            )
            let boundary = TestStorageRelocationBoundary()
            let fixture = try makeFixture(
                createSourceData: true,
                transactionBoundary: boundary.call
            )
            let preview = try fixture.coordinator.prepare(
                application: fixture.application,
                destinationBaseRoot: fixture.destinationRoot.path,
                expectedVersion: fixture.version
            )
            let prepared = try fixture.preparedCommit(for: preview)
            var rollbackWasRequested = false
            boundary.body = { event in
                switch failurePoint {
                case .afterPlanDurable:
                    if case .afterPlanDurable = event {
                        throw TestError.injected
                    }
                case .afterStaging:
                    if case .afterStaging = event {
                        throw TestError.injected
                    }
                case .rollbackCompletionReceipt:
                    if case .afterStaging = event {
                        rollbackWasRequested = true
                        throw TestError.injected
                    }
                    if rollbackWasRequested,
                       case .beforeCompletionReceipt = event {
                        throw TestError.injected
                    }
                case .beforeApplicationCleanup:
                    if case let .beforeSourceCleanup(url) = event,
                       url == fixture.sourcePaths.applicationRoot.url {
                        throw TestError.injected
                    }
                case .beforeArchiveCleanup:
                    if case let .beforeSourceCleanup(url) = event,
                       url
                        == fixture.sourcePaths.applicationArchiveRoot.url {
                        throw TestError.injected
                    }
                case .committedCompletionReceipt:
                    if case .beforeCompletionReceipt = event {
                        throw TestError.injected
                    }
                }
            }

            XCTAssertThrowsError(
                try fixture.coordinator.execute(
                    preview,
                    preparedCommit: prepared,
                    repository: fixture.repository
                ),
                failurePoint.rawValue
            ) { error in
                if failurePoint == .afterStaging {
                    guard case TestError.injected = error else {
                        return XCTFail(
                            "Expected injected failure for \(failurePoint.rawValue), got \(error)"
                        )
                    }
                } else {
                    XCTAssertEqual(
                        (error as? StorageRelocationError)?.code,
                        .rollbackRequired,
                        failurePoint.rawValue
                    )
                }
            }

            try assertFailureState(
                failurePoint,
                fixture: fixture,
                preview: preview
            )

            let restarted = try StorageRelocationCoordinator(
                applicationSupportURL: fixture.repositorySupportURL,
                fileSystem: LocalFileSystem(),
                activityProvider: TestRelocationActivityProvider()
            )
            let pendingIDs = try restarted.pendingRelocations()
                .map(\.transactionID)
            if failurePoint == .afterStaging {
                XCTAssertTrue(
                    pendingIDs.isEmpty,
                    failurePoint.rawValue
                )
            } else {
                XCTAssertEqual(
                    pendingIDs,
                    [preview.requestID],
                    failurePoint.rawValue
                )
            }

            let firstRecovery = try restarted.recover(
                transactionID: preview.requestID,
                repository: fixture.repository
            )
            let secondRecovery = try restarted.recover(
                transactionID: preview.requestID,
                repository: fixture.repository
            )
            XCTAssertEqual(
                secondRecovery,
                firstRecovery,
                failurePoint.rawValue
            )
            try assertRecoveredState(
                failurePoint,
                recovery: firstRecovery,
                fixture: fixture,
                preview: preview,
                prepared: prepared
            )
            XCTAssertTrue(
                try restarted.pendingRelocations().isEmpty,
                failurePoint.rawValue
            )
        }
    }

    func testPreparedCommitCannotCarryUnrelatedMetadataChanges() throws {
        let fixture = try makeFixture(createSourceData: true)
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        var unrelatedTarget = preview.relocatedApplication
        unrelatedTarget.displayName = "Unreviewed metadata edit"
        let prepared = try fixture.repository.prepare(
            [unrelatedTarget],
            expectedVersion: fixture.version
        )

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                preview,
                preparedCommit: prepared,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? StorageRelocationError)?.code,
                .stalePreview
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.sourcePaths.applicationRoot.url.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationPaths.applicationRoot.url.path
            )
        )
    }

    func testSourceChangeAfterPublicationRollsBackWithoutCommitting() throws {
        let fixture = try makeFixture(createSourceData: true)
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        let prepared = try fixture.preparedCommit(for: preview)
        let sourceFile = fixture.sourcePaths.applicationRoot.url
            .appendingPathComponent("profile-data.txt")

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                preview,
                preparedCommit: prepared,
                repository: fixture.repository
            ) { phase in
                if phase == .committingMetadata {
                    try! Data("changed while relocating".utf8).write(
                        to: sourceFile
                    )
                }
            }
        ) { error in
            XCTAssertEqual(
                (error as? StorageRelocationError)?.code,
                .sourceChanged
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: sourceFile),
            Data("changed while relocating".utf8)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationPaths.applicationRoot.url.path
            )
        )
        guard case let .loaded(snapshot) = fixture.repository.load() else {
            return XCTFail("Expected prior library")
        }
        XCTAssertEqual(snapshot.versionToken, fixture.version)
    }

    func testCentralPlanIsDurableBeforeManagedFilesystemEffects() throws {
        let boundary = TestStorageRelocationBoundary()
        let fixture = try makeFixture(
            createSourceData: true,
            transactionBoundary: boundary.call
        )
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        let prepared = try fixture.preparedCommit(for: preview)
        boundary.body = { event in
            guard case let .afterPlanDurable(transactionID) = event else {
                return
            }
            let planURL = fixture.repositorySupportURL
                .appendingPathComponent("Parallax", isDirectory: true)
                .appendingPathComponent(
                    "StorageRelocations",
                    isDirectory: true
                )
                .appendingPathComponent(
                    transactionID.uuidString.lowercased() + ".plan.json"
                )
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: planURL.path)
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.destinationPaths.applicationRoot.url.path
                )
            )
        }

        _ = try fixture.coordinator.execute(
            preview,
            preparedCommit: prepared,
            repository: fixture.repository
        )

        XCTAssertTrue(boundary.events.contains {
            if case .afterPlanDurable = $0 { return true }
            return false
        })
    }

    func testRestartDiscoversAndRecoversPendingCommittedRelocation() throws {
        let boundary = TestStorageRelocationBoundary()
        boundary.body = { event in
            if case .beforeCompletionReceipt = event {
                throw TestError.injected
            }
        }
        let fixture = try makeFixture(
            createSourceData: true,
            transactionBoundary: boundary.call
        )
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        let prepared = try fixture.preparedCommit(for: preview)

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                preview,
                preparedCommit: prepared,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? StorageRelocationError)?.code,
                .rollbackRequired
            )
        }

        let restarted = try StorageRelocationCoordinator(
            applicationSupportURL: fixture.repositorySupportURL,
            fileSystem: LocalFileSystem(),
            activityProvider: TestRelocationActivityProvider()
        )
        XCTAssertEqual(
            try restarted.pendingRelocations().map(\.transactionID),
            [preview.requestID]
        )

        let outcomes = try restarted.recoverAll(
            repository: fixture.repository
        )

        XCTAssertEqual(outcomes.count, 1)
        guard case let .committed(outcome) = outcomes[0] else {
            return XCTFail("Expected committed restart recovery")
        }
        XCTAssertEqual(outcome.versionToken, prepared.targetVersion)
        XCTAssertTrue(try restarted.pendingRelocations().isEmpty)
    }

    func testSourceSwapBeforeCleanupIsNeverRemoved() throws {
        let boundary = TestStorageRelocationBoundary()
        let fixture = try makeFixture(
            createSourceData: true,
            transactionBoundary: boundary.call
        )
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        let prepared = try fixture.preparedCommit(for: preview)
        let source = fixture.sourcePaths.applicationRoot.url
        let preserved = fixture.sourceRoot.appendingPathComponent(
            "preserved-original",
            isDirectory: true
        )
        let replacementSentinel = source.appendingPathComponent(
            "replacement.txt",
            isDirectory: false
        )
        boundary.body = { event in
            guard case let .beforeSourceCleanup(url) = event,
                  url == source
            else {
                return
            }
            try FileManager.default.moveItem(at: source, to: preserved)
            try FileManager.default.createDirectory(
                at: source,
                withIntermediateDirectories: true
            )
            try Data("replacement".utf8).write(to: replacementSentinel)
        }

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                preview,
                preparedCommit: prepared,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? StorageRelocationError)?.code,
                .rollbackRequired
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: replacementSentinel),
            Data("replacement".utf8)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: preserved
                    .appendingPathComponent("profile-data.txt").path
            )
        )
        XCTAssertEqual(
            try fixture.coordinator.pendingRelocations()
                .map(\.transactionID),
            [preview.requestID]
        )
    }

    func testRecoveryRollsBackPublishedCopiesWhenLibraryIsPrior() throws {
        let fixture = try makeFixture(createSourceData: true)
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        let prepared = try fixture.preparedCommit(for: preview)
        let receiptURL = try publishRecoveryFixture(
            fixture: fixture,
            preview: preview,
            prepared: prepared
        )

        let result = try fixture.coordinator.recover(
            preview,
            receiptURL: receiptURL,
            repository: fixture.repository
        )

        XCTAssertEqual(result, .rolledBack)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.sourcePaths.applicationRoot.url.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationPaths.applicationRoot.url.path
            )
        )
    }

    func testRecoveryCleansSourceWhenLibraryIsTarget() throws {
        let fixture = try makeFixture(createSourceData: true)
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        let prepared = try fixture.preparedCommit(for: preview)
        let receiptURL = try publishRecoveryFixture(
            fixture: fixture,
            preview: preview,
            prepared: prepared
        )
        _ = try fixture.repository.withExclusiveMutation(
            expectedVersion: fixture.version
        ) { capability in
            try capability.commit(prepared)
        }

        let result = try fixture.coordinator.recover(
            preview,
            receiptURL: receiptURL,
            repository: fixture.repository
        )

        XCTAssertEqual(
            result,
            .committed(
                StorageRelocationOutcome(
                    transactionID: preview.requestID,
                    application: preview.relocatedApplication,
                    versionToken: prepared.targetVersion,
                    receiptURL: nil
                )
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.sourcePaths.applicationRoot.url.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destinationPaths.applicationRoot.url.path
            )
        )
    }

    func testRecoveryPreservesBothCopiesForAmbiguousLibrary() throws {
        let fixture = try makeFixture(createSourceData: true)
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        let prepared = try fixture.preparedCommit(for: preview)
        let receiptURL = try publishRecoveryFixture(
            fixture: fixture,
            preview: preview,
            prepared: prepared
        )
        var unrelated = fixture.application
        unrelated.displayName = "Different committed state"
        let unrelatedSnapshot = try fixture.repository.save(
            [unrelated],
            expectedVersion: fixture.version
        )
        let originalReceipt = try JSONDecoder().decode(
            StorageRelocationReceipt.self,
            from: Data(contentsOf: receiptURL)
        )
        let tamperedReceipt = StorageRelocationReceipt(
            transactionID: originalReceipt.transactionID,
            applicationID: originalReceipt.applicationID,
            applicationStorageID: originalReceipt.applicationStorageID,
            priorVersion: originalReceipt.priorVersion,
            targetVersion: StorageRelocationVersionToken(
                unrelatedSnapshot.versionToken
            ),
            sourceBasePath: originalReceipt.sourceBasePath,
            destinationBasePath: originalReceipt.destinationBasePath,
            state: originalReceipt.state,
            detail: originalReceipt.detail
        )
        try JSONEncoder().encode(tamperedReceipt).write(
            to: receiptURL,
            options: .atomic
        )

        XCTAssertThrowsError(
            try fixture.coordinator.recover(
                preview,
                receiptURL: receiptURL,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? StorageRelocationError)?.code,
                .ambiguousLibraryState
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.sourcePaths.applicationRoot.url.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.destinationPaths.applicationRoot.url.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: receiptURL.path)
        )
    }

    func testCancellationBeforeExecutionLeavesSourceUntouched() throws {
        let fixture = try makeFixture(createSourceData: true)
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        let cancellation = StorageRelocationCancellation()
        cancellation.cancel()
        let prepared = try fixture.preparedCommit(for: preview)

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                preview,
                preparedCommit: prepared,
                repository: fixture.repository,
                cancellation: cancellation
            )
        ) { error in
            XCTAssertEqual(
                (error as? StorageRelocationError)?.code,
                .cancelled
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.sourcePaths.applicationRoot.url.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationPaths.applicationRoot.url.path
            )
        )
    }

    func testCancellationAfterStagingRollsBackBothManagedTrees() throws {
        let fixture = try makeFixture(createSourceData: true)
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        let cancellation = StorageRelocationCancellation()
        let prepared = try fixture.preparedCommit(for: preview)

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                preview,
                preparedCommit: prepared,
                repository: fixture.repository,
                cancellation: cancellation
            ) { phase in
                if phase == .stagingArchives {
                    cancellation.cancel()
                }
            }
        ) { error in
            XCTAssertEqual(
                (error as? StorageRelocationError)?.code,
                .cancelled
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.sourcePaths.applicationRoot.url
                    .appendingPathComponent("profile-data.txt").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.sourcePaths.applicationArchiveRoot.url
                    .appendingPathComponent("archive-data.txt").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationPaths.applicationRoot.url.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationPaths.applicationArchiveRoot.url.path
            )
        )
    }

    func testLegacyUnknownExactManagedValuesBecomeGenerated() throws {
        let fixture = try makeFixture()
        var application = fixture.application
        application.profiles[0].isolationOwnership = .legacyUnknown

        let preview = try fixture.coordinator.prepare(
            application: application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )

        XCTAssertEqual(
            Set(preview.generatedRewrites.map(\.field)),
            Set([.userData, .codexHome])
        )
        XCTAssertEqual(
            preview.relocatedApplication.profiles[0].isolationOwnership,
            ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            )
        )
    }

    func testExplicitValueMatchingGeneratedPathIsNotRewritten() throws {
        let fixture = try makeFixture()
        var application = fixture.application
        application.profiles[0].isolationOwnership = .explicit

        let preview = try fixture.coordinator.prepare(
            application: application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )

        XCTAssertTrue(preview.generatedRewrites.isEmpty)
        XCTAssertEqual(
            Set(preview.preservedExternalPaths.map(\.field)),
            Set([.userData, .codexHome])
        )
        XCTAssertEqual(
            preview.relocatedApplication.profiles[0].argumentsText,
            application.profiles[0].argumentsText
        )
        XCTAssertEqual(
            preview.relocatedApplication.profiles[0].environmentText,
            application.profiles[0].environmentText
        )
    }

    func testSameCanonicalRootIsBlocked() throws {
        let fixture = try makeFixture()

        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.sourceRoot.path,
            expectedVersion: fixture.version
        )

        XCTAssertTrue(preview.blockers.contains(.sameStorageLocation))
    }

    func testDestinationAppearingAfterPreviewIsNeverOverwritten() throws {
        let fixture = try makeFixture(createSourceData: true)
        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )
        try FileManager.default.createDirectory(
            at: fixture.destinationPaths.applicationRoot.url,
            withIntermediateDirectories: true
        )
        let sentinel = fixture.destinationPaths.applicationRoot.url
            .appendingPathComponent("do-not-overwrite.txt")
        try Data("existing".utf8).write(to: sentinel)
        let prepared = try fixture.preparedCommit(for: preview)

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                preview,
                preparedCommit: prepared,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? StorageRelocationError)?.code,
                .unexpectedDestination
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("existing".utf8)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.sourcePaths.applicationRoot.url.path
            )
        )
    }

    func testInsufficientCapacityBlocksBeforeMutation() throws {
        let fixture = try makeFixture(
            createSourceData: true,
            availableCapacity: { _ in 0 }
        )

        let preview = try fixture.coordinator.prepare(
            application: fixture.application,
            destinationBaseRoot: fixture.destinationRoot.path,
            expectedVersion: fixture.version
        )

        XCTAssertTrue(
            preview.blockers.contains {
                guard case .insufficientSpace = $0 else { return false }
                return true
            }
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.sourcePaths.applicationRoot.url.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destinationPaths.applicationRoot.url.path
            )
        )
    }

    func testMissingOwnershipDecodesAsLegacyUnknown() throws {
        let profile = LaunchProfile(name: "Legacy")
        let encoded = try JSONEncoder().encode(profile)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "isolationOwnership")
        object.removeValue(forKey: "childEnvironmentPolicy")
        object.removeValue(forKey: "sensitiveEnvironmentKeys")
        object.removeValue(forKey: "launchConfigurationTrust")
        let oldData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(LaunchProfile.self, from: oldData)

        XCTAssertEqual(decoded.isolationOwnership.userData, .legacyUnknown)
        XCTAssertEqual(decoded.isolationOwnership.codexHome, .legacyUnknown)
        XCTAssertEqual(decoded.childEnvironmentPolicy, .safeDefault)
        XCTAssertTrue(decoded.sensitiveEnvironmentKeys.isEmpty)
        XCTAssertEqual(decoded.launchConfigurationTrust, .local)
    }

    private func assertFailureState(
        _ failurePoint: RelocationFailurePoint,
        fixture: Fixture,
        preview: StorageRelocationPreview
    ) throws {
        let expectedApplication = failurePoint.commitsMetadata
            ? preview.relocatedApplication
            : fixture.application
        try assertLibrary(
            fixture,
            expectedApplication: expectedApplication,
            message: failurePoint.rawValue
        )
        try assertRelocationTrees(
            fixture,
            sourceApplication: failurePoint.sourceApplicationAfterFailure,
            sourceArchives: failurePoint.sourceArchivesAfterFailure,
            destinationApplication: failurePoint.commitsMetadata,
            destinationArchives: failurePoint.commitsMetadata,
            staging: failurePoint.leavesStagingAfterFailure,
            transactionID: preview.requestID,
            message: failurePoint.rawValue
        )
    }

    private func assertRecoveredState(
        _ failurePoint: RelocationFailurePoint,
        recovery: StorageRelocationRecoveryOutcome,
        fixture: Fixture,
        preview: StorageRelocationPreview,
        prepared: PreparedLibraryCommit
    ) throws {
        if failurePoint.commitsMetadata {
            guard case let .committed(outcome) = recovery else {
                return XCTFail(
                    "Expected committed recovery for \(failurePoint.rawValue)"
                )
            }
            XCTAssertEqual(
                outcome.transactionID,
                preview.requestID,
                failurePoint.rawValue
            )
            XCTAssertEqual(
                outcome.application,
                preview.relocatedApplication,
                failurePoint.rawValue
            )
            XCTAssertEqual(
                outcome.versionToken,
                prepared.targetVersion,
                failurePoint.rawValue
            )
            try assertLibrary(
                fixture,
                expectedApplication: preview.relocatedApplication,
                message: failurePoint.rawValue
            )
            try assertRelocationTrees(
                fixture,
                sourceApplication: false,
                sourceArchives: false,
                destinationApplication: true,
                destinationArchives: true,
                staging: false,
                transactionID: preview.requestID,
                message: failurePoint.rawValue
            )
        } else {
            XCTAssertEqual(
                recovery,
                .rolledBack,
                failurePoint.rawValue
            )
            try assertLibrary(
                fixture,
                expectedApplication: fixture.application,
                message: failurePoint.rawValue
            )
            try assertRelocationTrees(
                fixture,
                sourceApplication: true,
                sourceArchives: true,
                destinationApplication: false,
                destinationArchives: false,
                staging: false,
                transactionID: preview.requestID,
                message: failurePoint.rawValue
            )
        }
    }

    private func assertLibrary(
        _ fixture: Fixture,
        expectedApplication: ManagedApplication,
        message: String
    ) throws {
        guard case let .loaded(snapshot) = fixture.repository.load() else {
            return XCTFail("Expected loaded library: \(message)")
        }
        XCTAssertEqual(
            snapshot.applications,
            [expectedApplication],
            message
        )
    }

    private func assertRelocationTrees(
        _ fixture: Fixture,
        sourceApplication: Bool,
        sourceArchives: Bool,
        destinationApplication: Bool,
        destinationArchives: Bool,
        staging: Bool,
        transactionID: UUID,
        message: String
    ) throws {
        try assertTree(
            fixture.sourcePaths.applicationRoot.url,
            expected: sourceApplication,
            fileName: "profile-data.txt",
            contents: "profile",
            message: message
        )
        try assertTree(
            fixture.sourcePaths.applicationArchiveRoot.url,
            expected: sourceArchives,
            fileName: "archive-data.txt",
            contents: "archive",
            message: message
        )
        try assertTree(
            fixture.destinationPaths.applicationRoot.url,
            expected: destinationApplication,
            fileName: "profile-data.txt",
            contents: "profile",
            message: message
        )
        try assertTree(
            fixture.destinationPaths.applicationArchiveRoot.url,
            expected: destinationArchives,
            fileName: "archive-data.txt",
            contents: "archive",
            message: message
        )
        let stagingURL = fixture.destinationPaths.stagingRoot(
            transactionID: transactionID
        ).url
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: stagingURL.path),
            staging,
            message
        )
    }

    private func assertTree(
        _ root: URL,
        expected: Bool,
        fileName: String,
        contents: String,
        message: String
    ) throws {
        XCTAssertEqual(
            FileManager.default.fileExists(atPath: root.path),
            expected,
            message
        )
        if expected {
            XCTAssertEqual(
                try Data(
                    contentsOf: root.appendingPathComponent(fileName)
                ),
                Data(contents.utf8),
                message
            )
        }
    }

    private func publishRecoveryFixture(
        fixture: Fixture,
        preview: StorageRelocationPreview,
        prepared: PreparedLibraryCommit
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: fixture.destinationPaths.applicationRoot.url
                .deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: fixture.destinationPaths.applicationArchiveRoot.url
                .deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(
            at: fixture.sourcePaths.applicationRoot.url,
            to: fixture.destinationPaths.applicationRoot.url
        )
        try FileManager.default.copyItem(
            at: fixture.sourcePaths.applicationArchiveRoot.url,
            to: fixture.destinationPaths.applicationArchiveRoot.url
        )
        let staging = preview.destination.stagingRoot(
            transactionID: preview.requestID
        )
        try FileManager.default.createDirectory(
            at: staging.url,
            withIntermediateDirectories: true
        )
        let receiptURL = staging.url.appendingPathComponent(
            "relocation.json",
            isDirectory: false
        )
        let receipt = StorageRelocationReceipt(
            transactionID: preview.requestID,
            applicationID: preview.applicationID,
            applicationStorageID: preview.applicationStorageID,
            priorVersion: StorageRelocationVersionToken(
                prepared.priorVersion
            ),
            targetVersion: StorageRelocationVersionToken(
                prepared.targetVersion
            ),
            sourceBasePath:
                preview.source.canonicalBaseRootURL.path,
            destinationBasePath:
                preview.destination.canonicalBaseRootURL.path,
            state: .published,
            detail: nil
        )
        try JSONEncoder().encode(receipt).write(
            to: receiptURL,
            options: .atomic
        )
        return receiptURL
    }

    private func makeFixture(
        activityProvider: TestRelocationActivityProvider = TestRelocationActivityProvider(),
        createSourceData: Bool = false,
        availableCapacity: ((URL) -> UInt64?)? = nil,
        transactionBoundary:
            (@Sendable (StorageRelocationBoundary) throws -> Void)? = nil
    ) throws -> Fixture {
        let sourceRoot = temporaryDirectory
            .appendingPathComponent("Source", isDirectory: true)
        let destinationRoot = temporaryDirectory
            .appendingPathComponent("Destination", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sourceRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: destinationRoot,
            withIntermediateDirectories: true
        )
        let applicationID = UUID()
        let profileID = UUID()
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem())
        let sourceProfilePaths = try resolver.resolve(
            configuredBaseRoot: sourceRoot.path,
            applicationStorageID: applicationID,
            profileStorageID: profileID
        )
        let destinationProfilePaths = try resolver.resolve(
            configuredBaseRoot: destinationRoot.path,
            applicationStorageID: applicationID,
            profileStorageID: profileID
        )
        let sourcePaths = try resolver.resolveApplication(
            configuredBaseRoot: sourceRoot.path,
            applicationStorageID: applicationID
        )
        let destinationPaths = try resolver.resolveApplication(
            configuredBaseRoot: destinationRoot.path,
            applicationStorageID: applicationID
        )
        let profile = LaunchProfile(
            storageID: profileID,
            name: "Work",
            argumentsText: ShellWordsParser.quote(
                "--user-data-dir=\(sourceProfilePaths.userData.url.path)"
            ),
            environmentText:
                "CODEX_HOME=\(sourceProfilePaths.codexHome.url.path)",
            isolationOwnership: ProfileIsolationOwnership(
                userData: .generated,
                codexHome: .generated
            )
        )
        let application = ManagedApplication(
            storageID: applicationID,
            displayName: "Browser",
            appPath: "/Applications/Browser.app",
            preset: .codex,
            baseStoragePath: sourceRoot.path,
            profiles: [profile]
        )
        let repositorySupportURL = temporaryDirectory
            .appendingPathComponent("Repository", isDirectory: true)
        let repository = LibraryRepository(
            applicationSupportURL: repositorySupportURL,
            backupHook: { _, _ in }
        )
        let snapshot = try repository.save(
            [application],
            expectedVersion: .missing
        )

        if createSourceData {
            try FileManager.default.createDirectory(
                at: sourcePaths.applicationRoot.url,
                withIntermediateDirectories: true
            )
            try Data("profile".utf8).write(
                to: sourcePaths.applicationRoot.url
                    .appendingPathComponent("profile-data.txt")
            )
            try FileManager.default.createDirectory(
                at: sourcePaths.applicationArchiveRoot.url,
                withIntermediateDirectories: true
            )
            try Data("archive".utf8).write(
                to: sourcePaths.applicationArchiveRoot.url
                    .appendingPathComponent("archive-data.txt")
            )
        }

        let coordinator = try StorageRelocationCoordinator(
            applicationSupportURL: repositorySupportURL,
            fileSystem: LocalFileSystem(),
            activityProvider: activityProvider,
            availableCapacity: availableCapacity,
            transactionBoundary: transactionBoundary
        )
        return Fixture(
            application: application,
            coordinator: coordinator,
            sourceRoot: sourceRoot,
            destinationRoot: destinationRoot,
            sourcePaths: sourcePaths,
            destinationPaths: destinationPaths,
            destinationProfilePaths: destinationProfilePaths,
            repositorySupportURL: repositorySupportURL,
            repository: repository,
            snapshot: snapshot,
            version: snapshot.versionToken
        )
    }

    private enum RelocationFailurePoint: String, CaseIterable {
        case afterPlanDurable
        case afterStaging
        case rollbackCompletionReceipt
        case beforeApplicationCleanup
        case beforeArchiveCleanup
        case committedCompletionReceipt

        var commitsMetadata: Bool {
            switch self {
            case .afterPlanDurable,
                 .afterStaging,
                 .rollbackCompletionReceipt:
                false
            case .beforeApplicationCleanup,
                 .beforeArchiveCleanup,
                 .committedCompletionReceipt:
                true
            }
        }

        var sourceApplicationAfterFailure: Bool {
            switch self {
            case .beforeArchiveCleanup,
                 .committedCompletionReceipt:
                false
            case .afterPlanDurable,
                 .afterStaging,
                 .rollbackCompletionReceipt,
                 .beforeApplicationCleanup:
                true
            }
        }

        var sourceArchivesAfterFailure: Bool {
            self != .committedCompletionReceipt
        }

        var leavesStagingAfterFailure: Bool {
            switch self {
            case .beforeApplicationCleanup,
                 .beforeArchiveCleanup:
                true
            case .afterPlanDurable,
                 .afterStaging,
                 .rollbackCompletionReceipt,
                 .committedCompletionReceipt:
                false
            }
        }
    }
}

private struct Fixture {
    let application: ManagedApplication
    let coordinator: StorageRelocationCoordinator
    let sourceRoot: URL
    let destinationRoot: URL
    let sourcePaths: ResolvedApplicationStoragePaths
    let destinationPaths: ResolvedApplicationStoragePaths
    let destinationProfilePaths: ResolvedProfilePaths
    let repositorySupportURL: URL
    let repository: LibraryRepository
    let snapshot: LibraryRepositorySnapshot
    let version: LibraryVersionToken

    func preparedCommit(
        for preview: StorageRelocationPreview
    ) throws -> PreparedLibraryCommit {
        var applications = snapshot.applications
        let index = try XCTUnwrap(
            applications.firstIndex(where: {
                $0.id == preview.applicationID
            })
        )
        applications[index] = preview.relocatedApplication
        return try repository.prepare(
            applications,
            expectedVersion: version
        )
    }
}

private final class TestRelocationActivityProvider:
    StorageRelocationActivityProviding,
    @unchecked Sendable
{
    var activeProfileStorageIDs: Set<UUID> = []

    func activeProfileStorageIDs(
        applicationStorageID: UUID,
        profileStorageIDs: Set<UUID>
    ) -> Set<UUID> {
        activeProfileStorageIDs.intersection(profileStorageIDs)
    }
}

private final class TestStorageRelocationBoundary: @unchecked Sendable {
    private let lock = NSLock()
    var body: ((StorageRelocationBoundary) throws -> Void)?
    private(set) var events: [StorageRelocationBoundary] = []

    var call: @Sendable (StorageRelocationBoundary) throws -> Void {
        { [self] event in
            let body = lock.withLock {
                events.append(event)
                return self.body
            }
            try body?(event)
        }
    }
}

private enum TestError: Error {
    case injected
}
