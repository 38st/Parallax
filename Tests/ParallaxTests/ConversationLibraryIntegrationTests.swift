import XCTest
@testable import Parallax

final class ConversationLibraryIntegrationTests: XCTestCase {
    @MainActor
    private func fixture(launcher: any ApplicationLaunching = AuditNoopLauncher()) throws -> (LibraryStore, ManagedApplication, [UUID: [String]]) {
        let data = try ClaudeConversationFixture()
        let root = data.root
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        try FileManager.default.removeItem(at: data.destinationRecordURL)
        let bundle = try ValidApplicationBundleFixture.create(in: root)
        let app = ManagedApplication(displayName: "Synthetic Provider", bundleIdentifier: bundle.bundleIdentifier,
            appPath: bundle.url.path, preset: .claude, baseStoragePath: root.path,
            profiles: [LaunchProfile(name: "Account A"), LaunchProfile(name: "Account B")])
        let support = root.appendingPathComponent("Support")
        let repository = LibraryRepository(applicationSupportURL: support)
        _ = try repository.save([app], expectedVersion: .missing)
        // Recovery assertions control activity explicitly; a wall-clock refresh
        // must not race the fixture's durable opening marker on the main actor.
        let registry = try ProfileActivityRegistry(applicationSupportURL: support,
            refreshScheduler: SupervisorTestScheduler(),
            processInspector: TestWorkspaceProcessState(),
            completionScheduler: SupervisorTestScheduler())
        let store = LibraryStore(repository: repository, profileActivityRegistry: registry,
            launcher: launcher, settings: AppSettings())
        for (profile, source) in zip(app.profiles, [data.sourceRoot, data.destinationRoot]) {
            let paths = try store.managedPaths(for: app, profile: profile)
            try FileManager.default.createDirectory(at: paths.profileRoot.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: paths.profileRoot.url)
        }
        return (store, app, Dictionary(uniqueKeysWithValues: app.profiles.map { ($0.storageID, data.namespace.components) }))
    }

    private func makeLegacy(_ canonical: ConversationLibraryStore) throws {
        for binding in try XCTUnwrap(canonical.read()).bindings.values {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(binding)) as? [String: Any])
            object.removeValue(forKey: "rootVolumeUUID")
            object["rootVolumeID"] = binding.rootVolumeID + 1
            let legacy = try JSONDecoder().decode(ConversationAccountBinding.self,
                from: JSONSerialization.data(withJSONObject: object))
            try canonical.transaction { $0?.bindings[binding.profileStorageID.uuidString] = legacy }
        }
    }

    @MainActor
    func testFirstLaunchAfterUpgradeRepairsLegacyBindingsAndSurvivesRestart() async throws {
        let (store, app, namespaces) = try fixture()
        try await store.enrollConversationLibrary(application: app, source: app.profiles[0], namespaces: namespaces, expected: nil)
        let group = try XCTUnwrap(store.sharedHistoryGroup(application: app, profile: app.profiles[0]))
        let canonical = try store.conversationLibraryStore(group)
        let initial = store.launchConfigurationSource(application: app, profile: app.profiles[1], requestID: UUID())
        try await store.beginConversationSwitch(initial)
        try await store.prepareSharedHistoryForLaunch(initial)
        try ConversationLibraryService.completeOpening(store: canonical, targetID: initial.profileStorageID, requestID: initial.requestID)
        try makeLegacy(canonical)
        let before = try XCTUnwrap(canonical.read())
        let records = try nativeRecords(store, app: app)
        let reopened = LibraryStore(repository: store.repository, profileActivityRegistry: store.profileActivityRegistry,
            launcher: AuditNoopLauncher(), settings: AppSettings())
        let request = reopened.launchConfigurationSource(application: app, profile: app.profiles[0], requestID: UUID())
        try await reopened.beginConversationSwitch(request)
        let upgraded = try XCTUnwrap(canonical.read())
        XCTAssertTrue(upgraded.bindings.values.allSatisfy { $0.rootVolumeUUID != nil })
        XCTAssertEqual(upgraded.conversations, before.conversations)
        XCTAssertEqual(try nativeRecords(reopened, app: app), records)
        XCTAssertFalse(reopened.isProfileDataOperationRunning)
        try await reopened.prepareSharedHistoryForLaunch(request)
        try ConversationLibraryService.completeOpening(store: canonical, targetID: request.profileStorageID, requestID: request.requestID)
        let next = reopened.launchConfigurationSource(application: app, profile: app.profiles[1], requestID: UUID())
        try await reopened.beginConversationSwitch(next)
        try await reopened.prepareSharedHistoryForLaunch(next)
        XCTAssertEqual(try canonical.read()?.handoff?.phase, .opening)
    }

    @MainActor
    func testAccountReviewCanLaunchWithStaleBindingsWithoutChangingSharedHistory() async throws {
        let launcher = ConversationReviewRecordingLauncher()
        let (store, app, namespaces) = try fixture(launcher: launcher)
        store.settings.confirmBeforeLaunch = false
        try await store.enrollConversationLibrary(application: app, source: app.profiles[0], namespaces: namespaces, expected: nil)
        let canonical = try store.conversationLibraryStore(XCTUnwrap(store.sharedHistoryGroup(application: app, profile: app.profiles[0])))
        try makeLegacy(canonical)
        let before = try canonical.read()
        let records = try nativeRecords(store, app: app)
        await store.openConversationAccountForReview(application: app, profile: app.profiles[0])
        for task in store.launchPreparationTasks.values { await task.value }
        XCTAssertEqual(launcher.launches.count, 1, store.errorMessage ?? "No launch")
        XCTAssertNil(launcher.launches.first?.continuationURL)
        XCTAssertEqual(try canonical.read(), before)
        XCTAssertEqual(try nativeRecords(store, app: XCTUnwrap(store.applications.first)), records)
        XCTAssertFalse(store.isProfileDataOperationRunning)
        XCTAssertTrue(store.launchPreparationTasks.isEmpty)
        XCTAssertFalse(store.launchConfigurationSource(application: app, profile: app.profiles[0], requestID: UUID()).reviewsConversationAccount)
    }

    @MainActor
    func testAccountReviewKeepsConfirmationBoundToModeAndCurrentConfiguration() async throws {
        let launcher = ConversationReviewRecordingLauncher()
        let (store, app, _) = try fixture(launcher: launcher)
        store.settings.confirmBeforeLaunch = true
        await store.openConversationAccountForReview(application: app, profile: app.profiles[0])
        let request = try XCTUnwrap(store.launchRequests.pendingConfirmation(in: store.sceneID))
        XCTAssertTrue(request.configurationSnapshot.reviewsConversationAccount)
        var ordinary = request.configurationSnapshot
        ordinary.reviewsConversationAccount = false
        XCTAssertNotEqual(LaunchConfigurationCompiler.configurationFingerprint(for: ordinary), request.configurationFingerprint)
        XCTAssertTrue(launcher.launches.isEmpty)
        store.confirmLaunch()
        for task in store.launchPreparationTasks.values { await task.value }
        XCTAssertEqual(launcher.launches.count, 1, store.errorMessage ?? "No launch")

        let current = try XCTUnwrap(store.applications.first)
        await store.openConversationAccountForReview(application: current, profile: current.profiles[1])
        store.applications[0].profiles[1].argumentsText = "--changed-after-review"
        store.confirmLaunch()
        for task in store.launchPreparationTasks.values { await task.value }
        XCTAssertEqual(launcher.launches.count, 1)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testAccountReviewDoesNotBypassHandoffImportedApprovalOrDataOperations() async throws {
        let launcher = ConversationReviewRecordingLauncher()
        let (store, app, namespaces) = try fixture(launcher: launcher)
        store.settings.confirmBeforeLaunch = false
        try await store.enrollConversationLibrary(application: app, source: app.profiles[0], namespaces: namespaces, expected: nil)
        let canonical = try store.conversationLibraryStore(XCTUnwrap(store.sharedHistoryGroup(application: app, profile: app.profiles[0])))
        let pending = UUID()
        try ConversationLibraryService.beginSwitch(store: canonical, targetID: app.profiles[0].storageID, selectedID: nil, requestID: pending)
        await store.openConversationAccountForReview(application: app, profile: app.profiles[0])
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertEqual(try canonical.read()?.handoff?.id, pending)
        try ConversationLibraryService.recover(store: canonical, expectedRequestID: pending)
        store.isProfileDataOperationRunning = true
        await store.openConversationAccountForReview(application: app, profile: app.profiles[0])
        XCTAssertTrue(launcher.launches.isEmpty)
        store.isProfileDataOperationRunning = false
        var imported = app
        imported.profiles[0].launchConfigurationTrust = .importedPendingReview
        XCTAssertTrue(store.commit([imported], selectedApplicationID: nil, selectedProfileID: nil))
        await store.openConversationAccountForReview(application: imported, profile: imported.profiles[0])
        for task in store.launchPreparationTasks.values { await task.value }
        XCTAssertTrue(launcher.launches.isEmpty)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor
    func testRestartRecoversEveryPersistedSwitchPhaseWithoutChangingChats() async throws {
        for phase: ConversationHandoff.Phase in [.waiting, .capturing, .preparing, .ready, .opening] {
            let (store, app, namespaces) = try fixture()
            try await store.enrollConversationLibrary(application: app, source: app.profiles[0], namespaces: namespaces, expected: nil)
            let group = try XCTUnwrap(store.sharedHistoryGroup(application: app, profile: app.profiles[0]))
            let canonical = try store.conversationLibraryStore(group)
            let source = store.launchConfigurationSource(application: app, profile: app.profiles[1], requestID: UUID())
            try await store.beginConversationSwitch(source)
            // A durable journal can be observed at any of these stages after a restart.
            try canonical.transaction { $0?.handoff?.phase = phase }
            let before = try XCTUnwrap(canonical.read())
            let records = try nativeRecords(store, app: app)
            let reopened = LibraryStore(repository: store.repository, profileActivityRegistry: store.profileActivityRegistry,
                launcher: AuditNoopLauncher(), settings: AppSettings())
            let loaded = try XCTUnwrap(reopened.conversationLibrary(application: app, profile: app.profiles[0]))
            XCTAssertEqual(loaded, before)
            let recovered = try await reopened.recoverConversationSwitch(application: app, source: app.profiles[0],
                pending: XCTUnwrap(loaded.handoff))
            XCTAssertEqual(recovered.storageID, app.profiles[1].storageID)
            let after = try XCTUnwrap(canonical.read())
            XCTAssertNil(after.handoff)
            XCTAssertEqual(after.conversations, before.conversations)
            XCTAssertEqual(try nativeRecords(reopened, app: app), records)
            XCTAssertFalse(reopened.isProfileDataOperationRunning)
            XCTAssertTrue(reopened.launchPreparationTasks.isEmpty)
            let retry = reopened.launchConfigurationSource(application: app, profile: recovered, requestID: UUID())
            try await reopened.beginConversationSwitch(retry)
            try await reopened.prepareSharedHistoryForLaunch(retry)
            XCTAssertEqual(try canonical.read()?.handoff?.phase, .opening)
        }
    }

    @MainActor
    func testUnlinkedSpaceOpenDoesNotModifySharedHistoryOrEnrollIt() async throws {
        let (store, original, namespaces) = try fixture()
        var app = original
        let first = app.profiles[0]
        try await store.enrollConversationLibrary(application: app, source: first, namespaces: namespaces, expected: nil)
        try await store.setAllAccountHistory(true, application: app, expected: false)
        let unlinked = LaunchProfile(name: "Unlinked account")
        app.profiles.append(unlinked)
        XCTAssertTrue(store.commit([app], selectedApplicationID: nil, selectedProfileID: nil))
        let originalRoot = try store.managedPaths(for: app, profile: first).profileRoot.url
        let newRoot = try store.managedPaths(for: app, profile: unlinked).profileRoot.url
        try FileManager.default.copyItem(at: originalRoot, to: newRoot)
        let group = try XCTUnwrap(store.sharedHistoryGroup(application: app, profile: first))
        let canonical = try store.conversationLibraryStore(group)
        let before = try canonical.read()
        let records = try nativeRecords(store, app: app)
        let source = store.launchConfigurationSource(application: app, profile: unlinked, requestID: UUID())
        try await store.includeAllAccountHistoryForLaunch(source)
        try await store.beginConversationSwitch(source)
        try await store.prepareSharedHistoryForLaunch(source)
        XCTAssertEqual(try canonical.read(), before)
        XCTAssertEqual(try nativeRecords(store, app: app), records)
        XCTAssertNil(try store.sharedHistoryGroup(application: app, profile: unlinked))
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

private final class ConversationReviewRecordingLauncher: PreparedApplicationLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private var prepared: [PreparedLaunch] = []
    var launches: [PreparedLaunch] { lock.withLock { prepared } }
    func launch(prepared: PreparedLaunch, completion: @escaping @Sendable (Result<Void, Error>) -> Void) throws {
        lock.withLock { self.prepared.append(prepared) }
        completion(.success(()))
    }
    func launch(application: ManagedApplication, profile: LaunchProfile,
                completion: @escaping @Sendable (Result<Void, Error>) -> Void) throws {
        XCTFail("Review must use validated launch preparation")
        completion(.failure(LaunchError.preparationRequired))
    }
}

extension ConversationLibraryIntegrationTests {
    @MainActor
    func testFailureReplacesProgressAndUnrelatedCancellationCannotEraseIt() async throws {
        let (store, app, namespaces) = try fixture()
        try await store.enrollConversationLibrary(application: app, source: app.profiles[0], namespaces: namespaces, expected: nil)
        let source = store.launchConfigurationSource(application: app, profile: app.profiles[1], requestID: UUID())
        try await store.beginConversationSwitch(source)
        let records = try nativeRecords(store, app: app)
        let failure = ProfileActivityRegistryError.storageReservedForDataOperation.localizedDescription
        store.updateLaunchRequestStatus(requestID: source.requestID, state: .failed(failure))
        XCTAssertEqual(store.conversationSwitchMessage, failure)
        XCTAssertEqual(store.errorMessage, failure)
        XCTAssertTrue(store.conversationSwitchFailed)
        store.updateLaunchRequestStatus(requestID: UUID(), state: .cancelled)
        XCTAssertEqual(store.conversationSwitchMessage, failure)
        store.releaseWaitingConversationSwitch(source)
        XCTAssertNil(try store.conversationLibrary(application: app, profile: app.profiles[0])?.handoff)
        XCTAssertEqual(try nativeRecords(store, app: app), records)
    }

    @MainActor
    func testDuplicateSchedulingDoesNotCancelTheOwningTask() async throws {
        let (store, app, _) = try fixture()
        let source = store.launchConfigurationSource(application: app, profile: app.profiles[0], requestID: UUID())
        let owner = Task { @MainActor in }
        store.launchPreparationTasks[source.requestID] = owner
        store.schedulePreparedLaunch(source, profileName: app.profiles[0].name, override: nil, concurrentLaunchPolicy: .deny)
        XCTAssertFalse(owner.isCancelled)
        await owner.value
        store.launchPreparationTasks[source.requestID] = nil
    }

    @MainActor
    func testCompetingRequestCannotReleaseExistingSwitch() async throws {
        let (store, app, namespaces) = try fixture()
        try await store.enrollConversationLibrary(application: app, source: app.profiles[0], namespaces: namespaces, expected: nil)
        let owner = store.launchConfigurationSource(application: app, profile: app.profiles[0], requestID: UUID())
        let competitor = store.launchConfigurationSource(application: app, profile: app.profiles[1], requestID: UUID())
        try await store.beginConversationSwitch(owner)
        do {
            try await store.beginConversationSwitch(competitor)
            XCTFail("A second writer must not enter the handoff")
        } catch { XCTAssertEqual(error as? ConversationLibraryError, .busy) }
        store.releaseWaitingConversationSwitch(competitor)
        XCTAssertEqual(try store.conversationLibrary(application: app, profile: app.profiles[0])?.handoff?.id, owner.requestID)
        XCTAssertEqual(store.conversationSwitchRequestID, owner.requestID)
        store.releaseWaitingConversationSwitch(owner)
    }

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


extension ConversationLibraryIntegrationTests {
    @MainActor
    func testRecoveryWaitsForOwnedTaskAndRefusesUnknownOpeningLease() async throws {
        let (store, app, namespaces) = try fixture()
        try await store.enrollConversationLibrary(application: app, source: app.profiles[0], namespaces: namespaces, expected: nil)
        let source = store.launchConfigurationSource(application: app, profile: app.profiles[1], requestID: UUID())
        try await store.beginConversationSwitch(source)
        let pending = try XCTUnwrap(store.conversationLibrary(application: app, profile: app.profiles[0])?.handoff)
        let records = try nativeRecords(store, app: app)
        let owner = Task { @MainActor in }
        store.launchPreparationTasks[pending.id] = owner
        do {
            _ = try await store.recoverConversationSwitch(application: app, source: app.profiles[0], pending: pending)
            XCTFail("Recovery must wait for the task that owns the handoff")
        } catch { XCTAssertEqual(error as? ConversationLibraryError, .busy) }
        await owner.value
        store.launchPreparationTasks[pending.id] = nil
        let requestID = UUID()
        let profile = app.profiles[1]
        let lease = try store.profileActivityRegistry.acquireLaunchLease(identity: ProfileActivityIdentity(
            applicationID: app.id, applicationStorageID: app.storageID, profileID: profile.id, profileStorageID: profile.storageID), requestID: requestID)
        try store.profileActivityRegistry.markLaunchOpening(requestID: requestID)
        do {
            _ = try await store.recoverConversationSwitch(application: app, source: app.profiles[0], pending: pending)
            XCTFail("A native open without a known outcome must prevent another writer")
        } catch { /* The running/uncertain activity guard or data reservation must refuse recovery. */ }
        XCTAssertEqual(try store.conversationLibrary(application: app, profile: app.profiles[0])?.handoff, pending)
        XCTAssertEqual(try nativeRecords(store, app: app), records)
        await Task.detached { lease.release() }.value
        store.releaseWaitingConversationSwitch(source)
    }

    @MainActor
    func testRecoveryReturnsExactTargetRetainsRevisionsAndDoesNotLaunchInsidePanel() async throws {
        let (store, app, namespaces) = try fixture()
        try await store.enrollConversationLibrary(application: app, source: app.profiles[0], namespaces: namespaces, expected: nil)
        let source = store.launchConfigurationSource(application: app, profile: app.profiles[1], requestID: UUID())
        try await store.beginConversationSwitch(source)
        try await store.prepareSharedHistoryForLaunch(source)
        let original = try XCTUnwrap(store.conversationLibrary(application: app, profile: app.profiles[0]))
        let records = try nativeRecords(store, app: app)
        let pending = try XCTUnwrap(original.handoff)
        let unrelatedRequest = UUID()
        store.conversationSwitchRequestID = unrelatedRequest
        store.conversationSwitchMessage = "Another operation"
        store.errorMessage = "Another failure"
        let target = try await store.recoverConversationSwitch(application: app, source: app.profiles[0], pending: pending)
        let recovered = try XCTUnwrap(store.conversationLibrary(application: app, profile: app.profiles[0]))
        XCTAssertEqual(target.storageID, pending.targetProfileID)
        XCTAssertNil(recovered.handoff)
        XCTAssertEqual(recovered.conversations, original.conversations)
        XCTAssertEqual(try nativeRecords(store, app: app), records)
        XCTAssertTrue(store.launchPreparationTasks.isEmpty)
        XCTAssertTrue(store.activeTrackedLaunches.isEmpty)
        XCTAssertNil(store.launchRequests.status(for: source.requestID))
        XCTAssertEqual(store.conversationSwitchRequestID, unrelatedRequest)
        XCTAssertEqual(store.conversationSwitchMessage, "Another operation")
        XCTAssertEqual(store.errorMessage, "Another failure")
    }
    @MainActor
    func testReservedStorageFailureThroughSchedulerReplacesProgressAndKeepsOtherLease() async throws {
        let (store, app, namespaces) = try fixture()
        try await store.enrollConversationLibrary(application: app, source: app.profiles[0], namespaces: namespaces, expected: nil)
        let source = store.launchConfigurationSource(application: app, profile: app.profiles[1], requestID: UUID())
        let records = try nativeRecords(store, app: app)
        let reservation = try store.reserveProfileData(application: app, profiles: app.profiles)
        store.schedulePreparedLaunch(source, profileName: app.profiles[1].name, override: nil, concurrentLaunchPolicy: .deny)
        await store.launchPreparationTasks[source.requestID]?.value
        let failure = ProfileActivityRegistryError.storageReservedForDataOperation.localizedDescription
        XCTAssertEqual(store.errorMessage, failure)
        XCTAssertEqual(store.conversationSwitchMessage, failure)
        XCTAssertTrue(store.conversationSwitchFailed)
        XCTAssertNil(try store.conversationLibrary(application: app, profile: app.profiles[0])?.handoff)
        XCTAssertEqual(try nativeRecords(store, app: app), records)
        XCTAssertThrowsError(try store.reserveProfileData(application: app, profiles: app.profiles))
        await Task.detached { reservation.release() }.value
        let next = try store.reserveProfileData(application: app, profiles: app.profiles)
        await Task.detached { next.release() }.value
    }

}
