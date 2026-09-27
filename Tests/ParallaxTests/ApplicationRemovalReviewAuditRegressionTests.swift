import Darwin
import Foundation
import Observation
import XCTest
@testable import Parallax

final class ApplicationRemovalReviewAuditRegressionTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = root.appendingPathComponent("ApplicationRemovalReview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testOfflineVolumeDoesNotCommitRemoval() throws {
        for choice in [ApplicationRemovalDataChoice.archive, .delete] {
            let workspace = root.appendingPathComponent(UUID().uuidString)
            let mountContainer = workspace.appendingPathComponent("Volumes")
            try FileManager.default.createDirectory(at: mountContainer, withIntermediateDirectories: true)
            let fixture = try RemovalAuditFixture(root: workspace, choice: choice, createData: false,
                base: mountContainer.appendingPathComponent("Offline/Parallax"))
            XCTAssertThrowsError(try fixture.execute(fixture.coordinator())) { error in
                XCTAssertEqual((error as? ApplicationRemovalTransactionError)?.code, .storageUnavailable)
            }
            guard case .loaded(let snapshot) = fixture.repository.load() else { return XCTFail() }
            XCTAssertEqual(snapshot.applications, [fixture.application])
            XCTAssertTrue(try fixture.journal.pendingTransactions().isEmpty)
        }
    }

    func testRecoveryRollsBackMissingLowerAndLaterRetainedLibraries() throws {
        for replacement in ["missing", "lower", "later-retained"] {
            let fixture = try fixture(.delete)
            try fixture.interrupt(after: .stageProfile(fixture.application.profiles[0].storageID, 0))
            let repository: any LibraryRepositoryPersisting
            if replacement == "later-retained" {
                guard case .loaded(let snapshot) = fixture.repository.load() else { return XCTFail() }
                let updated = try fixture.repository.save([fixture.application], expectedVersion: snapshot.versionToken)
                _ = try fixture.repository.save([fixture.application], expectedVersion: updated.versionToken)
                repository = fixture.repository
            } else {
                let other = LibraryRepository(applicationSupportURL: root.appendingPathComponent(UUID().uuidString))
                if replacement == "lower" {
                    _ = try other.save([], expectedVersion: .missing)
                }
                repository = other
            }
            let result = try repository.tryWithExclusiveAccess { access in
                try fixture.coordinator().recover(transactionID: fixture.transactionID, repository: repository, access: access)
            }
            guard case .acquired(let outcome) = result else { return XCTFail() }
            XCTAssertEqual(outcome.completion, .rolledBack)
            XCTAssertEqual(try String(contentsOf: fixture.sources[0].appendingPathComponent("payload.txt"), encoding: .utf8), "payload 0")
        }
    }

    func testLegacyPreparedMarkerlessDataCannotBePurged() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .commitMetadata)
        try fixture.journal.persist(fixture.manifest)
        let staged = URL(fileURLWithPath: fixture.manifest.entries[0].stagedPath)
        try FileManager.default.removeItem(at: staged.appendingPathComponent(
            ApplicationRemovalTransactionPaths.ownerMarkerName(fixture.transactionID)))
        try Data("intruder".utf8).write(to: staged.appendingPathComponent("intruder.txt"))
        XCTAssertThrowsError(try fixture.recover())
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("intruder.txt").path))
    }

    func testLegacyPartialRollbackRecoversRemainingEntries() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .stageProfile(fixture.application.profiles[1].storageID, 1))
        try fixture.journal.persist(fixture.manifest)
        let entry = fixture.manifest.entries[1]
        try FileManager.default.moveItem(atPath: entry.stagedPath, toPath: entry.sourcePath)
        try FileManager.default.removeItem(at: fixture.sources[1].appendingPathComponent(
            ApplicationRemovalTransactionPaths.ownerMarkerName(fixture.transactionID)))
        XCTAssertEqual(try fixture.recover().completion, .rolledBack)
        XCTAssertTrue(try fixture.journal.pendingTransactions().isEmpty)
        for source in fixture.sources {
            XCTAssertTrue(FileManager.default.fileExists(atPath: source.appendingPathComponent("payload.txt").path))
        }
    }

    func testSingletonSymlinkIsRejectedBeforePublishingManifestOrMetadata() throws {
        for choice in [ApplicationRemovalDataChoice.archive, .delete] {
            let fixture = try fixture(choice)
            let link = fixture.sources[0].appendingPathComponent("SingletonLock")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing-host-1234")
            XCTAssertThrowsError(try fixture.execute(fixture.coordinator())) { error in
                XCTAssertTrue(error.localizedDescription.contains("Singleton"), error.localizedDescription)
            }
            guard case .loaded(let snapshot) = fixture.repository.load() else { return XCTFail() }
            XCTAssertEqual(snapshot.applications, [fixture.application])
            XCTAssertTrue(try fixture.journal.pendingTransactions().isEmpty)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "missing-host-1234")
        }
    }

    func testLegacyRecoveryToleratesRecordedDeviceMismatch() throws {
        for choice in [ApplicationRemovalDataChoice.archive, .delete] {
            let fixture = try fixture(choice)
            try fixture.interrupt(after: .commitMetadata)
            var legacy = fixture.manifest
            legacy.phase = .metadataCommitted
            let data = try JSONEncoder().encode(legacy)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            var entries = try XCTUnwrap(object["entries"] as? [[String: Any]])
            for index in entries.indices { entries[index]["expectedDevice"] = UInt64.max }
            object["entries"] = entries
            let changed = try JSONDecoder().decode(ApplicationRemovalTransactionManifest.self,
                from: JSONSerialization.data(withJSONObject: object))
            try fixture.journal.persist(changed)
            XCTAssertEqual(try fixture.recover().completion, .committed)
        }
    }

    func testMissingLeafUnderMountContainerIsUnavailable() throws {
        let container = root.appendingPathComponent("Mounts")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let fixture = try RemovalAuditFixture(root: root.appendingPathComponent("Support"),
            choice: .delete, createData: false, base: container.appendingPathComponent("Offline"))
        let coordinator = try ApplicationRemovalTransactionCoordinator(applicationSupportURL: fixture.root,
            isMountContainer: { $0.standardizedFileURL == container.standardizedFileURL })
        XCTAssertThrowsError(try fixture.execute(coordinator)) { error in
            XCTAssertEqual((error as? ApplicationRemovalTransactionError)?.code, .storageUnavailable)
        }
        XCTAssertTrue(try fixture.journal.pendingTransactions().isEmpty)
    }

    func testStableVolumeIdentityAllowsDeviceChangeAndRejectsOtherVolume() throws {
        for volumeUUID in [String?.some("AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"), nil] {
            let fixture = try fixture(.delete)
            let initial = try ApplicationRemovalTransactionCoordinator(applicationSupportURL: fixture.root,
                identitySource: { secure in
                    ApplicationRemovalTransactionRootIdentity(device: 7, inode: secure.rootIdentity.inode, volumeUUID: volumeUUID)
                }, transactionBoundary: { boundary in
                    if boundary == .afterEffectBeforeRecord(.commitMetadata) {
                        throw ApplicationRemovalTransactionInterruption.simulatedCrash
                    }
                })
            XCTAssertThrowsError(try fixture.execute(initial))
            XCTAssertEqual(try fixture.journal.loadManifest(transactionID: fixture.transactionID).entries[0].baseRootDevice, 7)
            if volumeUUID != nil {
                let otherVolume = try ApplicationRemovalTransactionCoordinator(applicationSupportURL: fixture.root,
                    identitySource: { secure in
                        ApplicationRemovalTransactionRootIdentity(device: 7, inode: secure.rootIdentity.inode,
                            volumeUUID: "11111111-2222-3333-4444-555555555555")
                    })
                XCTAssertThrowsError(try fixture.repository.tryWithExclusiveAccess { access in
                    try otherVolume.recover(transactionID: fixture.transactionID, repository: fixture.repository, access: access)
                })
            }
            let remounted = try ApplicationRemovalTransactionCoordinator(applicationSupportURL: fixture.root,
                identitySource: { secure in
                    let identity = ApplicationRemovalTransactionRootIdentity(device: -1,
                        inode: secure.rootIdentity.inode, volumeUUID: volumeUUID)
                    XCTAssertEqual(identity.device, UInt64(truncatingIfNeeded: dev_t(-1)))
                    return identity
                })
            let recovered = try fixture.repository.tryWithExclusiveAccess { access in
                try remounted.recover(transactionID: fixture.transactionID, repository: fixture.repository, access: access)
            }
            guard case .acquired(let outcome) = recovered else { return XCTFail() }
            XCTAssertEqual(outcome.completion, .committed)
        }
    }

    func testCrashAfterFinalizationJournalBeforeFilesystemEffectRecovers() throws {
        for choice in [ApplicationRemovalDataChoice.archive, .delete] {
            let fixture = try fixture(choice)
            let interrupted = try fixture.coordinator { boundary in
                switch boundary {
                case .beforeEffect(.finalizeArchive(_, 0)), .beforeEffect(.publishTombstone(_, 0)):
                    throw ApplicationRemovalTransactionInterruption.simulatedCrash
                default: break
                }
            }
            XCTAssertThrowsError(try fixture.execute(interrupted))
            let manifest = try fixture.journal.loadManifest(transactionID: fixture.transactionID)
            XCTAssertEqual(manifest.entries[0].finalizationStarted, true)
            let path = choice == .archive ? manifest.entries[0].archivePath : manifest.entries[0].stagedPath
            XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent(
                ApplicationRemovalTransactionPaths.ownerMarkerName(fixture.transactionID)).path))
            XCTAssertEqual(try fixture.recover().completion, .committed)
        }
    }

    func testChildListingDoesNotReadProfileContents() throws {
        let fixture = try fixture(.delete)
        let link = fixture.sources[0].appendingPathComponent("UnreadableLink")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "absent")
        let secure = try SecureManagedFileSystem(rootURL: fixture.base)
        let source = try ApplicationRemovalTransactionPaths.source(fixture.manifest.entries[0],
            applicationStorageID: fixture.application.storageID)
        XCTAssertEqual(try ApplicationRemovalTransactionFileSystem.children(of: source, in: secure),
            ["UnreadableLink", "payload.txt"])
    }

    private func fixture(_ choice: ApplicationRemovalDataChoice) throws -> RemovalAuditFixture {
        try RemovalAuditFixture(root: root.appendingPathComponent(UUID().uuidString), choice: choice, createData: true)
    }
}

extension ApplicationRemovalFlowAuditRegressionTests {
    @MainActor
    func testContainedOverrideThroughSymlinkIsNotExternal() throws {
        let fixture = try fixture()
        var app = fixture.app
        let base = URL(fileURLWithPath: try XCTUnwrap(app.baseStoragePath))
        let alias = base.deletingLastPathComponent().appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: base)
        app.baseStoragePath = alias.path
        for index in app.profiles.indices {
            let path = ManagedPathResolver.profileRootURL(baseRootURL: alias,
                applicationStorageID: app.storageID, profileStorageID: app.profiles[index].storageID)
            app.profiles[index].argumentsText = ShellWordsParser.quote("--user-data-dir=\(path.appendingPathComponent("Custom").path)")
        }
        XCTAssertTrue(try fixture.store.applicationRemovalProfileTargets(app).allSatisfy { $0.externalPaths.isEmpty })
        XCTAssertNil(fixture.store.errorMessage)
    }

    @MainActor
    func testMalformedGeneratedUserDataDoesNotChangeRemovalError() throws {
        let fixture = try fixture()
        var app = fixture.app
        app.profiles[0].isolationOwnership.userData = .generated
        app.profiles[0].argumentsText = "--user-data-dir"
        fixture.store.errorMessage = "Existing message"
        _ = try fixture.store.applicationRemovalProfileTargets(app)
        XCTAssertEqual(fixture.store.errorMessage, "Existing message")
    }

    @MainActor
    func testPendingRemovalFailureClearsStateAndRetainsReservationDuringFinalization() async throws {
        for asynchronous in [false, true] {
            let fixture = try fixture(boundary: { boundary in
                if case .afterEffectBeforeRecord(.stageProfile(_, 0)) = boundary {
                    throw ApplicationRemovalTransactionInterruption.simulatedCrash
                }
            })
            for profile in fixture.app.profiles {
                let source = try fixture.store.managedPaths(for: fixture.app, profile: profile).profileRoot.url
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            }
            fixture.store.beginApplicationRemoval(fixture.app, dataChoice: .delete)
            let registry = fixture.registry
            let identities = fixture.app.profiles.map { ProfileActivityIdentity(applicationID: fixture.app.id,
                applicationStorageID: fixture.app.storageID, profileID: $0.id, profileStorageID: $0.storageID) }
            withObservationTracking {
                _ = fixture.broadcaster.latestEvent
            } onChange: {
                for identity in identities {
                    XCTAssertTrue(registry.isStorageReserved(applicationStorageID: identity.applicationStorageID,
                        profileStorageID: identity.profileStorageID))
                }
            }
            if asynchronous {
                await fixture.store.confirmApplicationRemovalAsync()
            } else {
                fixture.store.confirmApplicationRemoval()
            }
            XCTAssertTrue(fixture.store.applications.isEmpty, fixture.store.errorMessage ?? "No failure reported")
            XCTAssertNil(fixture.store.libraryVersionToken)
            XCTAssertNil(fixture.store.startOverAuthorization())
            XCTAssertFalse(fixture.store.canRestoreLibraryBackup)
            for identity in identities {
                XCTAssertFalse(registry.isStorageReserved(applicationStorageID: identity.applicationStorageID,
                    profileStorageID: identity.profileStorageID))
            }
        }
    }
}

extension ApplicationRemovalFlowAuditRegressionTests {
    @MainActor
    func testReservationIsHeldBeforeBackupCreation() throws {
        let registry = ProfileActivityRegistry()
        let identities = ReviewAuditIdentities()
        let fixture = try fixture(registry: registry, backupHook: { _ in
            XCTAssertFalse(identities.values.isEmpty)
            for identity in identities.values {
                XCTAssertTrue(registry.isStorageReserved(applicationStorageID: identity.applicationStorageID,
                    profileStorageID: identity.profileStorageID))
                XCTAssertThrowsError(try registry.acquire(identity: identity, requestID: UUID()))
            }
            throw ReviewAuditError.injected
        })
        identities.values = fixture.app.profiles.map { ProfileActivityIdentity(applicationID: fixture.app.id,
            applicationStorageID: fixture.app.storageID, profileID: $0.id, profileStorageID: $0.storageID) }
        fixture.store.beginApplicationRemoval(fixture.app, dataChoice: .delete)
        fixture.store.confirmApplicationRemoval()
        XCTAssertNotNil(fixture.store.errorMessage)
        for identity in identities.values {
            XCTAssertFalse(registry.isStorageReserved(applicationStorageID: identity.applicationStorageID,
                profileStorageID: identity.profileStorageID))
        }
    }
}

private enum ReviewAuditError: Error { case injected }
private final class ReviewAuditIdentities {
    var values: [ProfileActivityIdentity] = []
}

extension ApplicationRemovalReviewAuditRegressionTests {
    func testKeepFilesRetiresOnlyReviewedJournalAndPreservesEveryCopy() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .stageProfile(fixture.application.profiles[0].storageID, 0))
        try FileManager.default.createDirectory(at: fixture.sources[0], withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: fixture.sources[0].appendingPathComponent("replacement.txt"))
        var other = fixture.manifest
        other = ApplicationRemovalTransactionManifest(transactionID: UUID(), applicationID: other.applicationID,
            applicationStorageID: other.applicationStorageID, dataChoice: other.dataChoice,
            priorRevision: other.priorRevision, priorSHA256: other.priorSHA256,
            targetRevision: other.targetRevision, targetSHA256: other.targetSHA256,
            stagingRootPath: other.stagingRootPath, phase: other.phase, entries: other.entries)
        try fixture.journal.persist(other)
        let before = try fixture.journal.manifestData(transactionID: other.transactionID)
        let reviewedData = try fixture.journal.manifestData(transactionID: fixture.transactionID)
        let coordinator = try fixture.coordinator()
        let review = try coordinator.recoveryReview(transactionID: fixture.transactionID)
        XCTAssertTrue(review.locations.contains(URL(fileURLWithPath: fixture.manifest.entries[0].stagedPath, isDirectory: true)))
        _ = try fixture.repository.tryWithExclusiveAccess { access in
            try coordinator.keepFilesAndContinue(review, repository: fixture.repository, access: access)
        }
        XCTAssertEqual(try fixture.journal.pendingTransactions(), [other.transactionID])
        XCTAssertEqual(try fixture.journal.manifestData(transactionID: other.transactionID), before)
        XCTAssertEqual(try String(contentsOf: fixture.sources[0].appendingPathComponent("replacement.txt"), encoding: .utf8), "replacement")
        XCTAssertEqual(try String(contentsOf: URL(fileURLWithPath: fixture.manifest.entries[0].stagedPath).appendingPathComponent("payload.txt"), encoding: .utf8), "payload 0")
        XCTAssertEqual(try fixture.journal.completedOutcome(transactionID: fixture.transactionID)?.completion, .keptFiles)
        let completionURL = fixture.journal.rootURL.appendingPathComponent("\(fixture.transactionID.uuidString.lowercased()).completed.json")
        let completion = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: completionURL)) as? [String: Any])
        XCTAssertEqual(completion["preservedManifest"] as? String, reviewedData.base64EncodedString())
    }

    func testKeepFilesRejectsChangedJournalReview() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .stageProfile(fixture.application.profiles[0].storageID, 0))
        let coordinator = try fixture.coordinator()
        let review = try coordinator.recoveryReview(transactionID: fixture.transactionID)
        var changed = try fixture.journal.loadManifest(transactionID: fixture.transactionID)
        changed.phase = .metadataCommitted
        try fixture.journal.persist(changed)
        XCTAssertThrowsError(try fixture.repository.tryWithExclusiveAccess { access in
            try coordinator.keepFilesAndContinue(review, repository: fixture.repository, access: access)
        })
        XCTAssertEqual(try fixture.journal.pendingTransactions(), [fixture.transactionID])
    }
}

extension ApplicationRemovalReviewAuditRegressionTests {
    func testSingletonAppearingBeforeCommitPreventsMetadataCommit() throws {
        for choice in [ApplicationRemovalDataChoice.archive, .delete] {
            let fixture = try fixture(choice)
            let coordinator = try fixture.coordinator { boundary in
                guard boundary == .beforeEffect(.commitMetadata) else { return }
                let path = choice == .archive ? fixture.manifest.entries[0].archivePath : fixture.manifest.entries[0].stagedPath
                try FileManager.default.createSymbolicLink(atPath: URL(fileURLWithPath: path)
                    .appendingPathComponent("SingletonLock").path, withDestinationPath: "missing-host-1234")
            }
            XCTAssertThrowsError(try fixture.execute(coordinator)) { error in
                XCTAssertEqual((error as? ApplicationRemovalTransactionError)?.code, .unsupportedProfileTree)
            }
            guard case .loaded(let snapshot) = fixture.repository.load() else { return XCTFail() }
            XCTAssertEqual(snapshot.applications, [fixture.application])
            XCTAssertEqual(try fixture.journal.pendingTransactions(), [fixture.transactionID])
        }
    }

    func testPreparedLegacyJournalCannotAuthorizeLaterMarkerlessEntry() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .commitMetadata)
        try fixture.journal.persist(fixture.manifest)
        let missingMarker = URL(fileURLWithPath: fixture.manifest.entries[1].stagedPath)
            .appendingPathComponent(ApplicationRemovalTransactionPaths.ownerMarkerName(fixture.transactionID))
        try FileManager.default.removeItem(at: missingMarker)
        XCTAssertThrowsError(try fixture.recover())
        XCTAssertEqual(try fixture.journal.loadManifest(transactionID: fixture.transactionID).phase, .prepared)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.manifest.entries[0].stagedPath))
    }
}

extension ApplicationRemovalFlowAuditRegressionTests {
    @MainActor
    func testConfirmedKeepFilesRestoresHealthyStoreWithoutChangingMetadata() async throws {
        let fixture = try fixture(boundary: { boundary in
            if case .afterEffectBeforeRecord(.stageProfile(_, 0)) = boundary {
                throw ApplicationRemovalTransactionInterruption.simulatedCrash
            }
        })
        for profile in fixture.app.profiles {
            let source = try fixture.store.managedPaths(for: fixture.app, profile: profile).profileRoot.url
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try Data("original".utf8).write(to: source.appendingPathComponent("payload.txt"))
        }
        guard case .loaded(let before) = fixture.repository.load() else { return XCTFail() }
        fixture.store.beginApplicationRemoval(fixture.app, dataChoice: .delete)
        fixture.store.confirmApplicationRemoval()
        await fixture.store.refreshApplicationRemovalRecoveryReviews()
        let review = try XCTUnwrap(fixture.store.pendingApplicationRemovalRecoveries.first)
        let preserved = review.locations.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("payload.txt").path) }
        XCTAssertEqual(preserved.count, 2)
        fixture.store.keepApplicationRemovalFilesAndContinue(review)
        XCTAssertNil(fixture.store.errorMessage)
        XCTAssertEqual(fixture.store.applications, before.applications)
        XCTAssertEqual(fixture.store.libraryVersionToken, before.versionToken)
        XCTAssertTrue(fixture.store.canMutateLibrary())
        XCTAssertTrue(fixture.store.isShowingApplicationRemovalConfirmation)
        for location in preserved {
            XCTAssertEqual(try String(contentsOf: location.appendingPathComponent("payload.txt"), encoding: .utf8), "original")
        }
        guard case .loaded(let after) = fixture.repository.load() else { return XCTFail() }
        XCTAssertEqual(after.originalBytes, before.originalBytes)
    }
}
