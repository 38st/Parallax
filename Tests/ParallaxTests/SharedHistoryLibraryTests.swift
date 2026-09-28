import XCTest
@testable import Parallax

final class SharedHistoryLibraryTests: XCTestCase {
    @MainActor
    private func fixture(preset: AppPreset = .claude) throws -> (LibraryStore, ManagedApplication) {
        let data = try ClaudeConversationFixture()
        let fixtureRoot = data.root
        addTeardownBlock { try FileManager.default.removeItem(at: fixtureRoot) }
        try FileManager.default.removeItem(at: data.destinationRecordURL)
        let bundle = try ValidApplicationBundleFixture.create(in: data.root)
        let plistURL = bundle.url.appendingPathComponent("Contents/Info.plist")
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        plist["CFBundleShortVersionString"] = "2.9939.2"
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: plistURL)
        let application = ManagedApplication(displayName: "Synthetic Provider", bundleIdentifier: bundle.bundleIdentifier,
            appPath: bundle.url.path, preset: preset, baseStoragePath: data.root.path,
            profiles: [LaunchProfile(name: "Account A"), LaunchProfile(name: "Account B")])
        let repository = LibraryRepository(applicationSupportURL: data.root.appendingPathComponent("Support"))
        _ = try repository.save([application], expectedVersion: .missing)
        let store = LibraryStore(repository: repository, settings: AppSettings())
        for (profile, root) in zip(application.profiles, [data.sourceRoot, data.destinationRoot]) {
            let paths = try store.managedPaths(for: application, profile: profile)
            try FileManager.default.createDirectory(at: paths.profileRoot.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: root, to: paths.profileRoot.url)
            if preset == .codex { try FileManager.default.createDirectory(at: paths.codexHome.url, withIntermediateDirectories: true) }
        }
        return (store, application)
    }

    @MainActor
    func testOptInPersistsAndDisconnectKeepsBothChats() async throws {
        let (store, app) = try fixture()
        let source = app.profiles[0]
        XCTAssertNil(try store.sharedHistoryGroup(application: app, profile: source))
        try await store.setSharedHistory(application: app, source: source,
            members: Set(app.profiles.map(\.storageID)), expected: nil, applicationIsRunning: { false })
        let group = try XCTUnwrap(store.sharedHistoryGroup(application: app, profile: source))
        XCTAssertEqual(group.knownConversationIDs.count, 1)
        XCTAssertEqual(try store.sharedHistoryGroup(application: app, profile: app.profiles[1]), group)
        XCTAssertFalse(store.isProfileDataOperationRunning)
        let lease = try store.reserveProfileData(application: app, profiles: app.profiles)
        lease.release()
        XCTAssertFalse(store.canMutateProfile(app, profile: source, allowActiveDataOverride: true))
        store.beginApplicationRemoval(app)
        XCTAssertNil(store.pendingApplicationRemoval)
        XCTAssertFalse(store.canChangeSharedHistoryData(application: app))
        let before = try app.profiles.map { try SharedHistoryService.catalog(store.sharedHistoryParticipant(application: app, profile: $0)) }
        try await store.setSharedHistory(application: app, source: source, members: [], expected: group)
        XCTAssertNil(try store.sharedHistoryGroup(application: app, profile: source))
        XCTAssertTrue(store.canMutateProfile(app, profile: source, allowActiveDataOverride: false))
        XCTAssertEqual(try app.profiles.map { try SharedHistoryService.catalog(store.sharedHistoryParticipant(application: app, profile: $0)) }, before)
    }

    @MainActor
    func testRunningAppAndInvalidSelectionDoNotEnableSharing() async throws {
        let (store, app) = try fixture()
        let source = app.profiles[0]
        for (members, running) in [(Set([source.storageID]), false), (Set(app.profiles.map(\.storageID)), true)] {
            do {
                try await store.setSharedHistory(application: app, source: source,
                    members: members, expected: nil, applicationIsRunning: { running })
                XCTFail("Should reject this opt-in")
            } catch { XCTAssertEqual(error as? SharedHistoryError, running ? .running : .invalidSelection) }
        }
        XCTAssertNil(try store.sharedHistoryGroup(application: app, profile: source))
    }

    @MainActor
    func testReservationsBlockSynchronizationAndInterruptedOptInCanRetry() async throws {
        let (store, app) = try fixture()
        let source = app.profiles[0]
        let lease = try store.reserveProfileData(application: app, profiles: [app.profiles[1]])
        do {
            try await store.setSharedHistory(application: app, source: source,
                members: Set(app.profiles.map(\.storageID)), expected: nil, applicationIsRunning: { false })
            XCTFail("Reserved destination must not be changed")
        } catch { XCTAssertNotNil(error as? ProfileActivityRegistryError) }
        lease.release()
        let group = try XCTUnwrap(store.sharedHistoryGroup(application: app, profile: source))
        XCTAssertTrue(group.knownConversationIDs.isEmpty)
        try await store.synchronizeSharedHistory(group, application: app, applicationIsRunning: { false })
        XCTAssertEqual(try store.sharedHistoryGroup(application: app, profile: source)?.knownConversationIDs.count, 1)
    }

    @MainActor
    func testLaunchSynchronizesAndRejectsStaleLaunchConfiguration() async throws {
        let (store, app) = try fixture()
        try await store.setSharedHistory(application: app, source: app.profiles[0], members: Set(app.profiles.map(\.storageID)),
            expected: nil, applicationIsRunning: { false })
        let source = store.launchConfigurationSource(application: app, profile: app.profiles[1], requestID: UUID())
        try await store.prepareSharedHistoryForLaunch(source)
        var stale = app.profiles[1]
        stale.argumentsText = "--changed"
        let old = store.launchConfigurationSource(application: app, profile: stale, requestID: UUID())
        do { try await store.prepareSharedHistoryForLaunch(old); XCTFail("Stale launch must stop") }
        catch { XCTAssertEqual(error as? SharedHistoryError, .changed) }
    }

    @MainActor
    func testCodexIndexFailureRetainsOptInAndReleasesLeasesForRetry() async throws {
        let (store, app) = try fixture(preset: .codex)
        do {
            try await store.setSharedHistory(application: app, source: app.profiles[0], members: Set(app.profiles.map(\.storageID)),
                expected: nil, applicationIsRunning: { false }, refreshCodexIndex: { _ in throw SharedHistoryError.indexFailed })
            XCTFail("Index failure must not look like a successful switch")
        } catch { XCTAssertEqual(error as? SharedHistoryError, .indexFailed) }
        XCTAssertFalse(store.isProfileDataOperationRunning)
        let group = try XCTUnwrap(store.sharedHistoryGroup(application: app, profile: app.profiles[0]))
        try await store.synchronizeSharedHistory(group, application: app, applicationIsRunning: { false }, refreshCodexIndex: { _ in })
        let lease = try store.reserveProfileData(application: app, profiles: app.profiles)
        lease.release()
    }

    @MainActor
    func testStaleReceiptCannotDisconnectChangedGroup() async throws {
        let (store, app) = try fixture()
        try await store.setSharedHistory(application: app, source: app.profiles[0], members: Set(app.profiles.map(\.storageID)),
            expected: nil, applicationIsRunning: { false })
        do {
            try await store.setSharedHistory(application: app, source: app.profiles[0], members: [], expected: nil)
            XCTFail("Stale window must not disconnect a new group")
        } catch { XCTAssertEqual(error as? SharedHistoryError, .changed) }
        XCTAssertNotNil(try store.sharedHistoryGroup(application: app, profile: app.profiles[0]))
    }

    @MainActor
    func testChangedStorageRootCannotInheritPreviousOptIn() async throws {
        let (store, app) = try fixture()
        try await store.setSharedHistory(application: app, source: app.profiles[0], members: Set(app.profiles.map(\.storageID)),
            expected: nil, applicationIsRunning: { false })
        let original = try XCTUnwrap(store.sharedHistoryGroup(application: app, profile: app.profiles[0]))
        var changed = original
        changed.rootPaths[app.profiles[0].storageID.uuidString] = "/synthetic/other-root"
        try store.sharedHistoryStore?.replace(original, with: changed)
        do {
            try await store.synchronizeSharedHistory(changed, application: app, applicationIsRunning: { false })
            XCTFail("Changing configured storage requires fresh opt-in")
        } catch { XCTAssertEqual(error as? SharedHistoryError, .changed) }
        let lease = try store.reserveProfileData(application: app, profiles: app.profiles)
        lease.release()
    }

    @MainActor
    func testCodexAcceptsOwnedAccountSessionHomeAndRefusesOtherExplicitHomes() throws {
        let (store, original) = try fixture(preset: .codex)
        let container = try XCTUnwrap(store.libraryPrimaryURL?.deletingLastPathComponent())
        let owned = container.appendingPathComponent("AccountSessions/\(UUID().uuidString)/CodexHome")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        var app = original
        app.profiles[0].environmentText = "CODEX_HOME=\(owned.path)"
        store.applications = [app]
        let participant = try store.sharedHistoryParticipant(application: app, profile: app.profiles[0])
        XCTAssertEqual(participant.files.rootIdentity, try SecureManagedFileSystem(rootURL: owned).rootIdentity)
        for environment in ["CODEX_HOME=/external/synthetic", "CODEX_HOME=\(owned.path)\nCODEX_SQLITE_HOME=/external/index"] {
            app.profiles[0].environmentText = environment
            store.applications = [app]
            XCTAssertThrowsError(try store.sharedHistoryParticipant(application: app, profile: app.profiles[0])) {
                XCTAssertEqual($0 as? SharedHistoryError, .unavailable)
            }
        }
    }
}
