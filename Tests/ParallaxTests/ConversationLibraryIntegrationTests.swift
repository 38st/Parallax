import XCTest
@testable import Parallax

final class ConversationLibraryIntegrationTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (LibraryStore, ManagedApplication, [UUID: [String]]) {
        let data = try ClaudeConversationFixture()
        let root = data.root
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: data.destinationRecordURL)
        let bundle = try ValidApplicationBundleFixture.create(in: root)
        let app = ManagedApplication(displayName: "Synthetic Provider", bundleIdentifier: bundle.bundleIdentifier,
            appPath: bundle.url.path, preset: .claude, baseStoragePath: root.path,
            profiles: [LaunchProfile(name: "Account A"), LaunchProfile(name: "Account B")])
        let repository = LibraryRepository(applicationSupportURL: root.appendingPathComponent("Support"))
        _ = try repository.save([app], expectedVersion: .missing)
        let store = LibraryStore(repository: repository, launcher: AuditNoopLauncher(), settings: AppSettings())
        for (profile, source) in zip(app.profiles, [data.sourceRoot, data.destinationRoot]) {
            let paths = try store.managedPaths(for: app, profile: profile)
            try FileManager.default.createDirectory(at: paths.profileRoot.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: paths.profileRoot.url)
        }
        return (store, app, Dictionary(uniqueKeysWithValues: app.profiles.map { ($0.storageID, data.namespace.components) }))
    }

    @MainActor
    func testEnrollmentMigrationAndDisconnectPreserveNativeAndLegacyData() async throws {
        let (store, app, namespaces) = try fixture()
        let source = app.profiles[0]
        try await store.setSharedHistory(application: app, source: source, members: Set(namespaces.keys), expected: nil,
            applicationIsRunning: { false })
        let legacy = try XCTUnwrap(store.sharedHistoryGroup(application: app, profile: source))
        let container = try XCTUnwrap(store.libraryPrimaryURL?.deletingLastPathComponent())
        let receiptURL = container.appendingPathComponent("shared-history.json")
        let receipt = try Data(contentsOf: receiptURL)
        let records = try nativeRecords(store, app: app)
        try await store.enrollConversationLibrary(application: app, source: source, namespaces: namespaces, expected: legacy)
        let migrated = try XCTUnwrap(store.sharedHistoryGroup(application: app, profile: source))
        XCTAssertEqual(migrated.id, legacy.id)
        XCTAssertEqual(migrated.conversationLibraryID, migrated.id)
        XCTAssertEqual(try nativeRecords(store, app: app), records)
        let backup = container.appendingPathComponent("shared-history-v1-" + LibraryPersistence.sha256(receipt) + ".json")
        XCTAssertEqual(try Data(contentsOf: backup), receipt)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        let canonical = try store.conversationLibraryStore(migrated)
        let first = try XCTUnwrap(canonical.read())
        XCTAssertEqual(first.conversations.count, 1)
        XCTAssertFalse(store.canChangeSharedHistoryData(application: app))
        do {
            try await store.synchronizeSharedHistory(migrated, application: app, applicationIsRunning: { false })
            XCTFail("Migrated groups must never use the legacy writer")
        } catch { XCTAssertEqual(error as? ConversationLibraryError, .changed) }
        try await store.enrollConversationLibrary(application: app, source: source, namespaces: namespaces, expected: migrated)
        XCTAssertEqual(try canonical.read(), first)
        try await store.setSharedHistory(application: app, source: source, members: [], expected: migrated)
        XCTAssertNil(try store.sharedHistoryGroup(application: app, profile: source))
        XCTAssertEqual(try canonical.read(), first)
        XCTAssertEqual(try nativeRecords(store, app: app), records)
        XCTAssertTrue(store.canChangeSharedHistoryData(application: app))
    }

    @MainActor
    func testInvalidNamespaceDoesNotPublishMigrationOrChangeHistories() async throws {
        let (store, app, namespaces) = try fixture()
        let records = try nativeRecords(store, app: app)
        var wrong = namespaces
        wrong[app.profiles[1].storageID] = ["UserData", "claude-code-sessions", UUID().uuidString, UUID().uuidString]
        do {
            try await store.enrollConversationLibrary(application: app, source: app.profiles[0], namespaces: wrong, expected: nil)
            XCTFail("Unconfirmed namespace must be rejected")
        } catch { XCTAssertEqual(error as? ConversationLibraryError, .accountChanged) }
        XCTAssertNil(try store.sharedHistoryGroup(application: app, profile: app.profiles[0]))
        XCTAssertEqual(try nativeRecords(store, app: app), records)
        XCTAssertFalse(store.isProfileDataOperationRunning)
    }

    @MainActor
    func testMigrationDoesNotResurrectAChatDeletedFromOneLegacyAccount() async throws {
        let (store, app, namespaces) = try fixture()
        let source = app.profiles[0]
        let target = app.profiles[1]
        try await store.setSharedHistory(application: app, source: source, members: Set(namespaces.keys), expected: nil,
            applicationIsRunning: { false })
        let legacy = try XCTUnwrap(store.sharedHistoryGroup(application: app, profile: source))
        let destination = try store.claudeConversationService(application: app, profile: target)
        let conversation = try XCTUnwrap(destination.catalog().conversations.first)
        let recordURL = URL(fileURLWithPath: destination.files.rootPath).appendingPathComponent(conversation.recordPath.components.joined(separator: "/"))
        try FileManager.default.removeItem(at: recordURL)
        try await store.enrollConversationLibrary(application: app, source: source, namespaces: namespaces, expected: legacy)
        let library = try XCTUnwrap(store.conversationLibrary(application: app, profile: source))
        XCTAssertEqual(library.conversations[conversation.sessionID]?.problems[target.storageID.uuidString], .missing)
        let request = store.launchConfigurationSource(application: app, profile: target, requestID: UUID())
        try await store.beginConversationSwitch(request)
        try await store.prepareSharedHistoryForLaunch(request)
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordURL.path))
        XCTAssertEqual(try store.conversationLibrary(application: app, profile: source)?.conversations.count, 1)
    }

    @MainActor
    func testLaunchPreparationUsesExactConversationAndDurableRequest() async throws {
        let (store, app, namespaces) = try fixture()
        try await store.enrollConversationLibrary(application: app, source: app.profiles[0], namespaces: namespaces, expected: nil)
        let group = try XCTUnwrap(store.sharedHistoryGroup(application: app, profile: app.profiles[0]))
        let canonical = try store.conversationLibraryStore(group)
        let id = try XCTUnwrap(canonical.read()?.conversations.keys.first)
        try canonical.transaction { $0?.selectedConversationID = id }
        let source = store.launchConfigurationSource(application: app, profile: app.profiles[1], requestID: UUID())
        try await store.beginConversationSwitch(source)
        XCTAssertEqual(try canonical.read()?.handoff?.phase, .waiting)
        try await store.prepareSharedHistoryForLaunch(source)
        XCTAssertEqual(try canonical.read()?.handoff?.phase, .opening)
        XCTAssertEqual(try store.conversationContinuationURL(source)?.absoluteString, "claude://code/continue?session=" + id)
        XCTAssertNil(try canonical.read()?.activeProfileID, "Preparation is not provider launch acceptance")
        XCTAssertNil(try store.conversationContinuationURL(store.launchConfigurationSource(application: app,
            profile: app.profiles[0], requestID: UUID())))
        try await store.updateConversationLibrary(application: app, profile: app.profiles[0]) {
            try ConversationLibraryService.recover(store: $0, expectedRequestID: source.requestID)
        }
        XCTAssertNil(try canonical.read()?.handoff)
        XCTAssertFalse(store.isProfileDataOperationRunning)
    }

    @MainActor
    func testContinuationURLRejectsArbitraryInputAndNeverSelectsLast() throws {
        for value in ["last", "", "local_not-a-uuid", "local_../../config", "local_\(UUID())&prompt=run"] {
            XCTAssertThrowsError(try LibraryStore.claudeContinuationURL(conversationID: value))
        }
        let id = "local_" + UUID().uuidString
        XCTAssertEqual(try LibraryStore.claudeContinuationURL(conversationID: id).absoluteString,
            "claude://code/continue?session=" + id)
    }

    @MainActor
    private func nativeRecords(_ store: LibraryStore, app: ManagedApplication) throws -> [UUID: [Data]] {
        try Dictionary(uniqueKeysWithValues: app.profiles.map { profile in
            let service = try store.claudeConversationService(application: app, profile: profile)
            let records = try service.catalog().conversations.map { try service.files.readFile(at: $0.recordPath) }
            return (profile.storageID, records)
        })
    }
}

extension ConversationLibraryIntegrationTests {
    @MainActor
    func testAuditBookkeepingCommitKeepsLaunchInputsButInputEditsInvalidateThem() throws {
        let (store, app, _) = try fixture()
        let profile = app.profiles[0]
        let source = store.launchConfigurationSource(application: app, profile: profile, requestID: UUID())
        XCTAssertTrue(store.commit(store.applications, selectedApplicationID: app.id, selectedProfileID: profile.id))
        let current = store.launchConfigurationSource(application: app, profile: profile, requestID: source.requestID)
        XCTAssertNotEqual(current.configurationRevision, source.configurationRevision)
        XCTAssertTrue(store.launchInputsMatch(source, application: app, profile: profile))
        var edited = profile
        edited.argumentsText += " --changed"
        XCTAssertFalse(store.launchInputsMatch(source, application: app, profile: edited))
        edited = profile
        edited.environmentText = "AUDIT_INPUT=changed"
        XCTAssertFalse(store.launchInputsMatch(source, application: app, profile: edited))
    }

    @MainActor
    func testAuditOverrideCancellationAndDeniedSchedulingReleaseWaitingHandoff() async throws {
        let (store, app, namespaces) = try fixture()
        try await store.enrollConversationLibrary(application: app, source: app.profiles[0], namespaces: namespaces, expected: nil)
        let group = try XCTUnwrap(store.sharedHistoryGroup(application: app, profile: app.profiles[0]))
        let canonical = try store.conversationLibraryStore(group)
        let profile = app.profiles[1]
        for action in 0..<3 {
            let source = store.launchConfigurationSource(application: app, profile: profile, requestID: UUID())
            try ConversationLibraryService.beginSwitch(store: canonical, targetID: profile.storageID, selectedID: nil, requestID: source.requestID)
            let fingerprint = LaunchConfigurationFingerprint(digest: "audit")
            if action == 0 {
                store.pendingLaunchDiagnosticRequest = .init(source: source, profileName: profile.name, fingerprint: fingerprint, diagnostics: [])
                store.cancelLaunchDiagnosticOverride()
            } else if action == 1 {
                store.pendingConcurrentLaunchRequest = .init(source: source, profileName: profile.name, fingerprint: fingerprint)
                store.cancelConcurrentLaunchOverride()
            } else {
                store.pendingRecoveryIdentities = nil
                store.isLibraryOperationInProgress = true
                store.schedulePreparedLaunch(source, profileName: profile.name, override: nil, concurrentLaunchPolicy: .deny)
                await store.launchPreparationTasks[source.requestID]?.value
            }
            XCTAssertNil(try canonical.read()?.handoff, "Action \(action)")
        }
    }
}

extension ConversationLibraryIntegrationTests {
    @MainActor
    func testAuditFailedLaunchPreparationReleasesWaitingHandoff() async throws {
        let (store, app, namespaces) = try fixture()
        try await store.enrollConversationLibrary(application: app, source: app.profiles[0], namespaces: namespaces, expected: nil)
        let canonical = try store.conversationLibraryStore(XCTUnwrap(store.sharedHistoryGroup(application: app, profile: app.profiles[0])))
        let profile = app.profiles[1]
        var source = store.launchConfigurationSource(application: app, profile: profile, requestID: UUID())
        try ConversationLibraryService.beginSwitch(store: canonical, targetID: profile.storageID, selectedID: nil, requestID: source.requestID)
        source.argumentsText = "--stale-input"
        store.schedulePreparedLaunch(source, profileName: profile.name, override: nil, concurrentLaunchPolicy: .deny)
        await store.launchPreparationTasks[source.requestID]?.value
        XCTAssertNil(try canonical.read()?.handoff)
    }
}
