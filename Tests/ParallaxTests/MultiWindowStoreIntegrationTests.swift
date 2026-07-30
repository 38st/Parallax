import Foundation
import XCTest
@testable import Parallax

final class MultiWindowStoreIntegrationTests: XCTestCase {
    private var temporaryDirectory =
        FileManager.default.temporaryDirectory
    private var defaults: UserDefaults?
    private var defaultsSuiteName: String?

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Multi-Window-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let suite = "parallax.multi-window.\(UUID().uuidString)"
        defaultsSuiteName = suite
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults?.removePersistentDomain(forName: suite)
    }

    override func tearDownWithError() throws {
        if let defaults, let defaultsSuiteName {
            defaults.removePersistentDomain(forName: defaultsSuiteName)
        }
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    @MainActor
    func testPeerReloadPropagatesSharedLibraryWithoutOverwritingSelection()
        throws
    {
        let support = temporaryDirectory.appendingPathComponent(
            "Support",
            isDirectory: true
        )
        let repository = LibraryRepository(
            applicationSupportURL: support
        )
        let firstProfile = LaunchProfile(name: "First")
        let secondProfile = LaunchProfile(name: "Second")
        let first = ManagedApplication(
            displayName: "First App",
            appPath: "/Applications/First.app",
            profiles: [firstProfile]
        )
        let second = ManagedApplication(
            displayName: "Second App",
            appPath: "/Applications/Second.app",
            profiles: [secondProfile]
        )
        _ = try repository.save(
            [first, second],
            expectedVersion: .missing
        )
        let broadcaster = LibraryChangeBroadcaster()
        let registry = ProfileActivityRegistry()
        let firstScene = UUID()
        let secondScene = UUID()
        let firstStore = try makeStore(
            support: support,
            repository: repository,
            registry: registry,
            sceneID: firstScene,
            broadcaster: broadcaster
        )
        let secondStore = try makeStore(
            support: support,
            repository: repository,
            registry: registry,
            sceneID: secondScene,
            broadcaster: broadcaster
        )
        firstStore.selectedApplicationID = first.id
        firstStore.selectedProfileID = firstProfile.id
        secondStore.selectedApplicationID = second.id
        secondStore.selectedProfileID = secondProfile.id

        var renamed = first
        renamed.displayName = "Renamed First App"
        firstStore.updateApplication(renamed)

        XCTAssertEqual(
            broadcaster.latestEvent?.sourceSceneID,
            firstScene
        )
        secondStore.reloadFromSharedRepository()

        XCTAssertEqual(firstStore.selectedApplicationID, first.id)
        XCTAssertEqual(firstStore.selectedProfileID, firstProfile.id)
        XCTAssertEqual(secondStore.selectedApplicationID, second.id)
        XCTAssertEqual(secondStore.selectedProfileID, secondProfile.id)
        XCTAssertEqual(
            secondStore.applications.first?.displayName,
            "Renamed First App"
        )
    }

    @MainActor
    func testBroadcasterSequencesChangesAndRetainsOriginatingScene()
        throws
    {
        let broadcaster = LibraryChangeBroadcaster()
        let first = UUID()
        let second = UUID()

        broadcaster.publish(sourceSceneID: first)
        let firstEvent = broadcaster.latestEvent
        broadcaster.publish(sourceSceneID: second)
        let secondEvent = broadcaster.latestEvent

        XCTAssertEqual(firstEvent?.sourceSceneID, first)
        XCTAssertEqual(secondEvent?.sourceSceneID, second)
        XCTAssertGreaterThan(
            try XCTUnwrap(secondEvent?.sequence),
            try XCTUnwrap(firstEvent?.sequence)
        )
    }

    @MainActor
    func testDestructiveConfirmationCannotBeRetargetedBySelection()
        throws
    {
        let fixture = try makeDestructiveFixture()
        let firstRoot = try fixture.store.managedPaths(
            for: fixture.firstApplication,
            profile: fixture.firstProfile
        ).profileRoot.url
        let secondRoot = try fixture.store.managedPaths(
            for: fixture.secondApplication,
            profile: fixture.secondProfile
        ).profileRoot.url
        try FileManager.default.createDirectory(
            at: firstRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondRoot,
            withIntermediateDirectories: true
        )
        try Data("first".utf8).write(
            to: firstRoot.appendingPathComponent("sentinel")
        )
        try Data("second".utf8).write(
            to: secondRoot.appendingPathComponent("sentinel")
        )

        fixture.store.requestClearProfileData(
            for: fixture.firstApplication,
            profile: fixture.firstProfile
        )
        let presentation = try XCTUnwrap(
            fixture.store.pendingDestructiveActionPresentation
        )
        fixture.store.selectedApplicationID =
            fixture.secondApplication.id
        fixture.store.selectedProfileID = fixture.secondProfile.id
        fixture.store.confirmDestructiveAction()

        XCTAssertEqual(
            presentation.applicationID,
            fixture.firstApplication.id
        )
        XCTAssertEqual(
            presentation.profileID,
            fixture.firstProfile.id
        )
        XCTAssertEqual(presentation.canonicalPath, firstRoot.path)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: firstRoot.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: secondRoot.appendingPathComponent(
                    "sentinel"
                ).path
            )
        )
    }

    @MainActor
    func testActiveDestructiveActionRequiresExactExpertOverride()
        throws
    {
        let fixture = try makeDestructiveFixture()
        let firstRoot = try fixture.store.managedPaths(
            for: fixture.firstApplication,
            profile: fixture.firstProfile
        ).profileRoot.url
        try FileManager.default.createDirectory(
            at: firstRoot,
            withIntermediateDirectories: true
        )
        try Data("active".utf8).write(
            to: firstRoot.appendingPathComponent("sentinel")
        )
        let lease = try fixture.registry.acquire(
            identity: ProfileActivityIdentity(
                applicationID: fixture.firstApplication.id,
                applicationStorageID:
                    fixture.firstApplication.storageID,
                profileID: fixture.firstProfile.id,
                profileStorageID: fixture.firstProfile.storageID
            ),
            requestID: UUID()
        )

        fixture.store.requestClearProfileData(
            for: fixture.firstApplication,
            profile: fixture.firstProfile
        )
        fixture.store.confirmDestructiveAction()

        XCTAssertTrue(
            fixture.store.isShowingDestructiveExpertOverride
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: firstRoot.path)
        )

        fixture.store.confirmDestructiveExpertOverride()

        XCTAssertFalse(
            fixture.store.isShowingDestructiveExpertOverride
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: firstRoot.path)
        )
        lease.release()
    }

    @MainActor
    func testSameStorageAliasCannotBypassDestructiveActivityGate()
        throws
    {
        let fixture = try makeDestructiveFixture()
        let firstRoot = try fixture.store.managedPaths(
            for: fixture.firstApplication,
            profile: fixture.firstProfile
        ).profileRoot.url
        try FileManager.default.createDirectory(
            at: firstRoot,
            withIntermediateDirectories: true
        )
        try Data("active alias".utf8).write(
            to: firstRoot.appendingPathComponent("sentinel")
        )
        let aliasIdentity = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: fixture.firstApplication.storageID,
            profileID: UUID(),
            profileStorageID: fixture.firstProfile.storageID
        )
        let lease = try fixture.registry.acquire(
            identity: aliasIdentity,
            requestID: UUID()
        )
        defer { lease.release() }

        XCTAssertTrue(
            fixture.store.isProfileActive(
                fixture.firstApplication,
                profile: fixture.firstProfile
            )
        )
        fixture.store.requestClearProfileData(
            for: fixture.firstApplication,
            profile: fixture.firstProfile
        )
        fixture.store.confirmDestructiveAction()

        XCTAssertTrue(
            fixture.store.isShowingDestructiveExpertOverride
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: firstRoot.path)
        )
    }

    @MainActor
    func testLargeDestructiveIOYieldsTheMainActor() async throws {
        let enteredWorker = expectation(
            description: "profile data worker entered filesystem phase"
        )
        let releaseWorker = DispatchSemaphore(value: 0)
        let fixture = try makeDestructiveFixture(
            transactionBoundary: { boundary in
                if boundary == .beforeEffect(.moveToStaging) {
                    enteredWorker.fulfill()
                    releaseWorker.wait()
                }
            }
        )
        let root = try fixture.store.managedPaths(
            for: fixture.firstApplication,
            profile: fixture.firstProfile
        ).profileRoot.url
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x41, count: 1_048_576).write(
            to: root.appendingPathComponent("large-payload")
        )
        fixture.store.requestClearProfileData(
            for: fixture.firstApplication,
            profile: fixture.firstProfile
        )

        let operation = Task {
            await fixture.store.confirmDestructiveActionAsync()
        }
        await fulfillment(of: [enteredWorker], timeout: 2)

        XCTAssertTrue(fixture.store.isProfileDataOperationRunning)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: root.path),
            "worker should remain paused while the main actor stays testable"
        )
        fixture.store.requestProfileDuplication(
            for: fixture.firstApplication,
            profile: fixture.firstProfile
        )
        XCTAssertTrue(
            fixture.store.errorMessage?.contains(
                "current profile data operation"
            ) == true
        )

        releaseWorker.signal()
        await operation.value
        XCTAssertFalse(fixture.store.isProfileDataOperationRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertNil(fixture.store.errorMessage)
    }

    @MainActor
    func testStoreEditSessionsMergeNonOverlappingPeerChangesAndRejectOverlap()
        throws
    {
        let support = temporaryDirectory.appendingPathComponent(
            "EditSupport",
            isDirectory: true
        )
        let original = ManagedApplication(
            displayName: "Original",
            appPath: "/Applications/Original.app",
            preset: .automatic
        )
        let repository = LibraryRepository(
            applicationSupportURL: support
        )
        _ = try repository.save(
            [original],
            expectedVersion: .missing
        )
        let registry = ProfileActivityRegistry()
        let firstStore = try makeStore(
            support: support,
            repository: repository,
            registry: registry,
            sceneID: UUID(),
            broadcaster: LibraryChangeBroadcaster()
        )
        let secondStore = try makeStore(
            support: support,
            repository: repository,
            registry: registry,
            sceneID: UUID(),
            broadcaster: LibraryChangeBroadcaster()
        )
        let baselineVersion = try XCTUnwrap(
            firstStore.currentLibraryVersion
        )
        var nameDraft = original
        nameDraft.displayName = "Peer Name"
        XCTAssertTrue(
            firstStore.applyApplicationEdit(
                draft: nameDraft,
                baseline: original,
                baselineVersion: baselineVersion
            )
        )

        secondStore.reloadFromSharedRepository()
        var presetDraft = original
        presetDraft.preset = .chrome
        XCTAssertTrue(
            secondStore.applyApplicationEdit(
                draft: presetDraft,
                baseline: original,
                baselineVersion: baselineVersion
            )
        )
        let merged = try XCTUnwrap(
            secondStore.applications.first
        )
        XCTAssertEqual(merged.displayName, "Peer Name")
        XCTAssertEqual(merged.preset, .chrome)

        let overlapBaseline = merged
        let overlapVersion = try XCTUnwrap(
            secondStore.currentLibraryVersion
        )
        var firstOverlap = overlapBaseline
        firstOverlap.displayName = "First overlap"
        firstStore.reloadFromSharedRepository()
        XCTAssertTrue(
            firstStore.applyApplicationEdit(
                draft: firstOverlap,
                baseline: overlapBaseline,
                baselineVersion: overlapVersion
            )
        )
        secondStore.reloadFromSharedRepository()
        var secondOverlap = overlapBaseline
        secondOverlap.displayName = "Second overlap"

        XCTAssertFalse(
            secondStore.applyApplicationEdit(
                draft: secondOverlap,
                baseline: overlapBaseline,
                baselineVersion: overlapVersion
            )
        )
        XCTAssertTrue(
            secondStore.errorMessage?.contains("displayName")
                == true
        )
        XCTAssertEqual(
            secondStore.applications.first?.displayName,
            "First overlap"
        )
    }

    @MainActor
    private func makeStore(
        support: URL,
        repository: LibraryRepository,
        registry: ProfileActivityRegistry,
        sceneID: UUID,
        broadcaster: LibraryChangeBroadcaster
    ) throws -> LibraryStore {
        LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            repository: repository,
            profileActivityRegistry: registry,
            launcher: MultiWindowLauncher(),
            settings: AppSettings(
                userDefaults: try XCTUnwrap(defaults)
            ),
            sceneID: sceneID,
            libraryChangeBroadcaster: broadcaster
        )
    }

    @MainActor
    private func makeDestructiveFixture(
        transactionBoundary:
            (@Sendable (ProfileDataTransactionBoundary) throws -> Void)? = nil
    ) throws
        -> DestructiveStoreFixture
    {
        let support = temporaryDirectory.appendingPathComponent(
            "DestructiveSupport",
            isDirectory: true
        )
        let managed = temporaryDirectory.appendingPathComponent(
            "Managed",
            isDirectory: true
        )
        let firstProfile = LaunchProfile(name: "First")
        let secondProfile = LaunchProfile(name: "Second")
        let firstApplication = ManagedApplication(
            displayName: "First App",
            appPath: "/Applications/First.app",
            baseStoragePath: managed.path,
            profiles: [firstProfile]
        )
        let secondApplication = ManagedApplication(
            displayName: "Second App",
            appPath: "/Applications/Second.app",
            baseStoragePath: managed.path,
            profiles: [secondProfile]
        )
        let repository = LibraryRepository(
            applicationSupportURL: support
        )
        _ = try repository.save(
            [firstApplication, secondApplication],
            expectedVersion: .missing
        )
        let registry = ProfileActivityRegistry()
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            repository: repository,
            profileDataTransactions:
                try ProfileDataTransactionCoordinator(
                    applicationSupportURL: support,
                    transactionBoundary: transactionBoundary
                ),
            profileActivityRegistry: registry,
            launcher: MultiWindowLauncher(),
            settings: AppSettings(
                userDefaults: try XCTUnwrap(defaults)
            ),
            sceneID: UUID(),
            libraryChangeBroadcaster: LibraryChangeBroadcaster()
        )
        return DestructiveStoreFixture(
            store: store,
            registry: registry,
            firstApplication: firstApplication,
            firstProfile: firstProfile,
            secondApplication: secondApplication,
            secondProfile: secondProfile
        )
    }
}

private struct DestructiveStoreFixture {
    let store: LibraryStore
    let registry: ProfileActivityRegistry
    let firstApplication: ManagedApplication
    let firstProfile: LaunchProfile
    let secondApplication: ManagedApplication
    let secondProfile: LaunchProfile
}

private struct MultiWindowLauncher: ApplicationLaunching {
    func launch(
        application: ManagedApplication,
        profile: LaunchProfile,
        completion:
            @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        completion(.success(()))
    }
}
