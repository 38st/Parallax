import XCTest
@testable import Parallax

@MainActor
final class AllAccountHistoryTests: XCTestCase {
    private struct Fixture {
        let data: ClaudeConversationFixture
        let repository: LibraryRepository
        let store: LibraryStore
        var application: ManagedApplication
    }

    private func fixture(count: Int = 2, initialized: Bool = true) throws -> Fixture {
        let data = try ClaudeConversationFixture()
        let root = data.root
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        let bundle = try ValidApplicationBundleFixture.create(in: root)
        let app = ManagedApplication(displayName: "Synthetic Provider", bundleIdentifier: bundle.bundleIdentifier,
            appPath: bundle.url.path, preset: .claude, baseStoragePath: root.path,
            profiles: (0..<count).map { LaunchProfile(name: "Account \($0)") })
        let repository = LibraryRepository(applicationSupportURL: root.appendingPathComponent("Support"))
        _ = try repository.save([app], expectedVersion: .missing)
        let f = Fixture(data: data, repository: repository,
            store: LibraryStore(repository: repository, settings: AppSettings()), application: app)
        if initialized {
            for profile in app.profiles { try initialize(profile, in: f) }
        }
        return f
    }

    private func initialize(_ profile: LaunchProfile, in f: Fixture, empty: Bool = false) throws {
        let root = try f.store.managedPaths(for: f.application, profile: profile).profileRoot.url
        try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: f.data.sourceRoot, to: root)
        if empty {
            try FileManager.default.removeItem(at: root.appendingPathComponent(
                f.data.namespace.components.joined(separator: "/")).appendingPathComponent(f.data.sourceRecordURL.lastPathComponent))
        }
    }

    private func addAccount(_ f: inout Fixture) throws -> LaunchProfile {
        let profile = LaunchProfile(name: "New Account")
        f.application.profiles.append(profile)
        XCTAssertTrue(f.store.commit([f.application], selectedApplicationID: nil, selectedProfileID: nil))
        return profile
    }

    private func group(_ f: Fixture) throws -> SharedHistoryGroup {
        try XCTUnwrap(f.store.allAccountHistoryGroup(f.application))
    }

    private func library(_ f: Fixture) throws -> ConversationLibrary {
        try XCTUnwrap(f.store.conversationLibraryStore(group(f)).read())
    }

    func testEnablingRetainsExistingLibraryAndSurvivesRestartWithoutRewritingHistory() async throws {
        let f = try fixture()
        let first = f.application.profiles[0]
        try await f.store.enrollConversationLibrary(application: f.application, source: first,
            namespaces: Dictionary(uniqueKeysWithValues: f.application.profiles.map { ($0.storageID, f.data.namespace.components) }), expected: nil)
        let originalGroup = try XCTUnwrap(f.store.sharedHistoryGroup(application: f.application, profile: first))
        let original = try XCTUnwrap(f.store.conversationLibraryStore(originalGroup).read())
        let native = try f.store.claudeConversationService(application: f.application, profile: first)
        let record = try XCTUnwrap(native.catalog().conversations.first)
        let bytes = try native.files.readFile(at: record.recordPath)
        try await f.store.setAllAccountHistory(true, application: f.application, expected: false,
            applicationIsRunning: { true })
        XCTAssertEqual(try group(f), originalGroup)
        XCTAssertEqual(try library(f), original)
        XCTAssertEqual(try native.files.readFile(at: record.recordPath), bytes)
        let restarted = LibraryStore(repository: f.repository, settings: AppSettings())
        XCTAssertTrue(try restarted.usesAllAccountHistory(f.application))
        XCTAssertEqual(try restarted.allAccountHistoryGroup(f.application)?.id, originalGroup.id)
    }

    func testPreferenceCanPrecedeSignInAndFirstAccountStartsOneLibrary() async throws {
        let f = try fixture(count: 1, initialized: false)
        let profile = f.application.profiles[0]
        try await f.store.setAllAccountHistory(true, application: f.application, expected: false)
        XCTAssertTrue(try f.store.usesAllAccountHistory(f.application))
        XCTAssertNil(try f.store.allAccountHistoryGroup(f.application))
        let source = f.store.launchConfigurationSource(application: f.application, profile: profile, requestID: UUID())
        try await f.store.includeAllAccountHistoryForLaunch(source)
        XCTAssertNil(try f.store.allAccountHistoryGroup(f.application))
        XCTAssertNotNil(f.store.conversationSwitchMessage)
        try initialize(profile, in: f)
        try await f.store.includeAllAccountHistoryForLaunch(source)
        XCTAssertEqual(try library(f).bindings.count, 1)
        XCTAssertEqual(try library(f).conversations.count, 1)
        XCTAssertEqual(try group(f).profileStorageIDs, [profile.storageID])
    }

    func testPreferenceCanPrecedeCreatingAnyAccount() async throws {
        var f = try fixture(count: 0)
        try await f.store.setAllAccountHistory(true, application: f.application, expected: false)
        XCTAssertTrue(try f.store.usesAllAccountHistory(f.application))
        XCTAssertNil(try f.store.allAccountHistoryGroup(f.application))
        let profile = try addAccount(&f)
        try initialize(profile, in: f)
        let source = f.store.launchConfigurationSource(application: f.application, profile: profile, requestID: UUID())
        try await f.store.includeAllAccountHistoryForLaunch(source)
        XCTAssertEqual(try library(f).bindings.count, 1)
    }

    func testFutureAccountAutomaticallyJoinsAndReceivesHistoryAtLaunchBoundary() async throws {
        var f = try fixture()
        try await f.store.setAllAccountHistory(true, application: f.application, expected: false)
        let original = try library(f)
        let profile = try addAccount(&f)
        try initialize(profile, in: f, empty: true)
        let target = try f.store.claudeConversationService(application: f.application, profile: profile)
        XCTAssertTrue(try target.catalog().conversations.isEmpty)
        let source = f.store.launchConfigurationSource(application: f.application, profile: profile, requestID: UUID())
        try await f.store.includeAllAccountHistoryForLaunch(source)
        XCTAssertEqual(try library(f).id, original.id)
        XCTAssertEqual(try library(f).bindings.count, 3)
        XCTAssertTrue(try target.catalog().conversations.isEmpty, "Enrollment must not write native records")
        try await f.store.beginConversationSwitch(source)
        try await f.store.prepareSharedHistoryForLaunch(source)
        XCTAssertEqual(Set(try target.catalog().conversations.map(\.sessionID)), Set(original.conversations.keys))
        XCTAssertEqual(try library(f).handoff?.phase, .opening)
    }

    func testTurningOffAutomaticInclusionKeepsLinksAndDisconnectStopsRelinking() async throws {
        var f = try fixture()
        try await f.store.setAllAccountHistory(true, application: f.application, expected: false)
        let originalGroup = try group(f)
        try await f.store.setAllAccountHistory(false, application: f.application, expected: true)
        XCTAssertEqual(try f.store.sharedHistoryGroup(application: f.application, profile: f.application.profiles[0]), originalGroup)
        let profile = try addAccount(&f)
        try initialize(profile, in: f)
        let source = f.store.launchConfigurationSource(application: f.application, profile: profile, requestID: UUID())
        try await f.store.includeAllAccountHistoryForLaunch(source)
        XCTAssertNil(try f.store.sharedHistoryGroup(application: f.application, profile: profile))
        try await f.store.setAllAccountHistory(true, application: f.application, expected: false)
        let joined = try group(f)
        let catalog = try f.store.conversationLibraryStore(joined)
        let retained = try catalog.read()
        try await f.store.setSharedHistory(application: f.application, source: profile, members: [], expected: joined)
        XCTAssertFalse(try f.store.usesAllAccountHistory(f.application))
        XCTAssertEqual(try catalog.read(), retained)
        try await f.store.includeAllAccountHistoryForLaunch(source)
        XCTAssertNil(try f.store.sharedHistoryGroup(application: f.application, profile: profile))
    }

    func testSchedulingOnlyNamespacesDoNotRequireAnAccountChoice() async throws {
        let f = try fixture()
        let path = try f.store.managedPaths(for: f.application, profile: f.application.profiles[1]).profileRoot.url
            .appendingPathComponent("UserData/claude-code-sessions/\(UUID())/\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: path.appendingPathComponent("scheduled-tasks.json"))
        try await f.store.setAllAccountHistory(true, application: f.application, expected: false)
        XCTAssertEqual(try library(f).bindings.count, 2)
        XCTAssertTrue(try library(f).bindings.values.allSatisfy { $0.namespace == f.data.namespace.components })
    }

    func testAmbiguousFutureHistoryNeedsReviewWithoutBlockingAlreadyLinkedAccounts() async throws {
        var f = try fixture()
        try await f.store.setAllAccountHistory(true, application: f.application, expected: false)
        let originalGroup = try group(f)
        let original = try library(f)
        let profile = try addAccount(&f)
        try initialize(profile, in: f)
        let path = try f.store.managedPaths(for: f.application, profile: profile).profileRoot.url
            .appendingPathComponent("UserData/claude-code-sessions/\(UUID())/\(UUID())")
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        try Data(contentsOf: f.data.sourceRecordURL).write(to: path.appendingPathComponent(f.data.sourceRecordURL.lastPathComponent))
        let source = f.store.launchConfigurationSource(application: f.application, profile: profile, requestID: UUID())
        do {
            try await f.store.includeAllAccountHistoryForLaunch(source)
            XCTFail("Multiple populated histories must not be guessed")
        } catch { XCTAssertEqual(error as? AllAccountHistoryError, .chooseHistory(profile.name)) }
        XCTAssertEqual(try group(f), originalGroup)
        XCTAssertEqual(try library(f), original)
        let existing = f.store.launchConfigurationSource(application: f.application, profile: f.application.profiles[0], requestID: UUID())
        try await f.store.includeAllAccountHistoryForLaunch(existing)
        try await f.store.enrollConversationLibrary(application: f.application, source: profile,
            namespaces: Dictionary(uniqueKeysWithValues: f.application.profiles.map { ($0.storageID, f.data.namespace.components) }), expected: originalGroup)
        XCTAssertEqual(try library(f).bindings.count, 3)
        XCTAssertEqual(try library(f).id, original.id)
    }

    func testCatalogPublicationCanBeRecoveredBeforeReceiptMembershipPublication() async throws {
        var f = try fixture()
        try await f.store.setAllAccountHistory(true, application: f.application, expected: false)
        let originalGroup = try group(f)
        let original = try library(f)
        let profile = try addAccount(&f)
        try initialize(profile, in: f)
        let participants = try f.application.profiles.map { try f.store.sharedHistoryParticipant(application: f.application, profile: $0) }
        let newParticipant = try XCTUnwrap(participants.first { $0.storageID == profile.storageID })
        let binding = try ConversationLibraryClaudeAdapter.bind(profileID: profile.storageID, label: profile.name,
            namespace: f.data.namespace.components, files: newParticipant.files)
        let catalog = try f.store.conversationLibraryStore(originalGroup)
        try ConversationLibraryService.includeAccounts(store: catalog, bindings: Array(original.bindings.values) + [binding], participants: participants)
        let interrupted = try catalog.read()
        XCTAssertEqual(try group(f).profileStorageIDs.count, 2)
        let oldSource = f.store.launchConfigurationSource(application: f.application, profile: f.application.profiles[0], requestID: UUID())
        try await f.store.includeAllAccountHistoryForLaunch(oldSource)
        XCTAssertEqual(try group(f).profileStorageIDs.count, 3)
        XCTAssertEqual(try library(f), interrupted)
    }

    func testAllAccountsIsNotLimitedToEightMembers() async throws {
        let f = try fixture(count: 9)
        try await f.store.setAllAccountHistory(true, application: f.application, expected: false)
        XCTAssertEqual(try group(f).profileStorageIDs.count, 9)
        XCTAssertEqual(try library(f).bindings.count, 9)
        XCTAssertEqual(try library(f).conversations.count, 1)
    }

    func testExternalStorageStaysOutsideSharedLibraryWithClearLaunchMessage() async throws {
        var f = try fixture(count: 1, initialized: false)
        f.application.profiles[0].argumentsText = "--user-data-dir=/synthetic-external"
        XCTAssertTrue(f.store.commit([f.application], selectedApplicationID: nil, selectedProfileID: nil))
        try await f.store.setAllAccountHistory(true, application: f.application, expected: false)
        XCTAssertTrue(try f.store.usesAllAccountHistory(f.application))
        XCTAssertNil(try f.store.allAccountHistoryGroup(f.application))
        let source = f.store.launchConfigurationSource(application: f.application, profile: f.application.profiles[0], requestID: UUID())
        try await f.store.includeAllAccountHistoryForLaunch(source)
        XCTAssertNil(try f.store.allAccountHistoryGroup(f.application))
        XCTAssertEqual(f.store.conversationSwitchMessage,
            String(localized: "This space uses its own Claude data folders, so its history is not part of the shared library."))
        XCTAssertFalse(f.store.isProfileDataOperationRunning)
    }

    func testUnfinishedSwitchPreventsPolicyChanges() async throws {
        let f = try fixture()
        try await f.store.setAllAccountHistory(true, application: f.application, expected: false)
        let catalog = try f.store.conversationLibraryStore(group(f))
        try ConversationLibraryService.beginSwitch(store: catalog, targetID: f.application.profiles[0].storageID,
            selectedID: nil, requestID: UUID())
        do {
            try await f.store.setAllAccountHistory(false, application: f.application, expected: true)
            XCTFail("An in-progress handoff must keep its policy")
        } catch { XCTAssertEqual(error as? ConversationLibraryError, .busy) }
        XCTAssertTrue(try f.store.usesAllAccountHistory(f.application))
        XCTAssertNotNil(try catalog.read()?.handoff)
    }
}
