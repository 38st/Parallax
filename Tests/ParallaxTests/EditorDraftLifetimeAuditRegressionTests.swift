import XCTest
@testable import Parallax

@MainActor
final class EditorDraftLifetimeAuditRegressionTests: XCTestCase {
    func testClosingSceneDiscardsOnlyUnreferencedStagedSecrets() async {
        let secrets = EditorAuditSecretStore()
        let profile = LaunchProfile(name: "Work")
        let shared = EnvironmentSecretReference()
        let abandoned = EnvironmentSecretReference()
        var duplicate = LaunchProfile(name: "Duplicate")
        duplicate.environmentText = "TOKEN=\(shared.token)"
        let application = ManagedApplication(
            displayName: "Synthetic", appPath: "/tmp/Synthetic.app",
            profiles: [profile, duplicate]
        )
        let store = LibraryStore(
            persistence: EditorAuditPersistence(applications: [application]),
            secretStore: secrets
        )
        remember([shared, abandoned], in: store, application: application, profile: profile)

        await store.closeProfileEditing()

        XCTAssertTrue(store.profileEditingDrafts.isEmpty)
        XCTAssertFalse(store.acceptsProfileEditingDrafts)
        let removed = await secrets.removed
        XCTAssertEqual(removed, [abandoned])
    }

    func testPeerRemovalCleansDraftWithoutClosingOtherEditors() async {
        let secrets = EditorAuditSecretStore()
        let profile = LaunchProfile(name: "Removed")
        let retainedProfile = LaunchProfile(name: "Retained")
        let reference = EnvironmentSecretReference()
        let retained = EnvironmentSecretReference()
        let application = ManagedApplication(
            displayName: "Synthetic", appPath: "/tmp/Synthetic.app",
            profiles: [profile, retainedProfile]
        )
        let store = LibraryStore(
            persistence: EditorAuditPersistence(applications: [application]),
            secretStore: secrets
        )
        remember([reference], in: store, application: application, profile: profile)
        remember([retained], in: store, application: application, profile: retainedProfile)
        store.applications[0].profiles.removeFirst()

        await store.discardRemovedProfileEditingDrafts()

        let removed = await secrets.removed
        XCTAssertEqual(removed, [reference])
        XCTAssertEqual(store.profileEditingDrafts.map(\.draft.id), [retainedProfile.id])
        XCTAssertTrue(store.acceptsProfileEditingDrafts)
    }

    func testQuitWaitsForLateStagingAndDiscardsItsReference() async {
        let client = EditorAuditClient()
        client.suspendStaging = true
        let session = client.session()
        session.activate()
        session.beginAddingKeychainSecret()
        session.keychainEnvironmentKey = "TOKEN"
        session.keychainSecretValue = "synthetic"
        session.saveKeychainSecret()
        await waitUntil { client.stageContinuation != nil }
        let cleanup = Task { await client.editorDraftRegistry.discardAllDrafts() }
        await waitUntil { !client.acceptsProfileEditingDrafts }
        client.finishStage()
        await cleanup.value

        XCTAssertEqual(client.deleted.count, 1)
        XCTAssertTrue(client.pending.isEmpty)
        XCTAssertTrue(session.stagedKeychainReferences.isEmpty)
    }

    func testAnotherWindowsPendingDraftProtectsSharedReference() async {
        let first = EditorAuditClient()
        let second = EditorAuditClient(editorDraftRegistry: first.editorDraftRegistry)
        let reference = EnvironmentSecretReference()
        let session = second.session()
        session.draft.environmentText = "TOKEN=\(reference.token)"
        session.draftDidChange()

        let deleted = await first.discardUnreferencedKeychainSecret(reference)

        XCTAssertFalse(deleted)
        XCTAssertTrue(first.deleted.isEmpty)
    }

    func testQuitWaitsForAnAlreadyPendingSecretDiscard() async {
        let client = EditorAuditClient()
        let session = client.session()
        session.activate()
        session.beginAddingKeychainSecret()
        session.keychainEnvironmentKey = "TOKEN"
        session.keychainSecretValue = "synthetic"
        session.saveKeychainSecret()
        await waitUntil { !session.stagedKeychainReferences.isEmpty }
        client.suspendDiscard = true
        session.revertDraft()
        await waitUntil { client.discardContinuation != nil }
        var completed = false
        let cleanup = Task {
            await client.editorDraftRegistry.discardAllDrafts()
            completed = true
        }
        await waitUntil { !client.acceptsProfileEditingDrafts }
        XCTAssertFalse(completed)
        client.discardContinuation?.resume()
        client.discardContinuation = nil
        await cleanup.value
        XCTAssertEqual(client.deleted.count, 1)
    }

    func testUnavailableLibraryRetainsDraftsAndStagedSecrets() async {
        let states: [LibraryStore.LoadState] = [
            .loading,
            .recoveryRequired(originalBytes: nil, message: "Synthetic recovery"),
            .unsupportedNewerVersion(originalBytes: nil, message: "Synthetic version"),
            .unrecoverable(originalBytes: nil, message: "Synthetic failure")
        ]
        for state in states {
            let secrets = EditorAuditSecretStore()
            let profile = LaunchProfile(name: "Work")
            let reference = EnvironmentSecretReference()
            let application = ManagedApplication(
                displayName: "Synthetic", appPath: "/tmp/Synthetic.app", profiles: [profile]
            )
            let store = LibraryStore(
                persistence: EditorAuditPersistence(applications: [application]), secretStore: secrets
            )
            remember([reference], in: store, application: application, profile: profile)
            store.loadState = state
            store.applications = []
            await store.discardRemovedProfileEditingDrafts()
            XCTAssertEqual(store.profileEditingDrafts.count, 1)
            let removed = await secrets.removed
            XCTAssertTrue(removed.isEmpty)
            remember([reference], in: store, application: application, profile: profile)
            XCTAssertEqual(store.profileEditingDrafts.count, 1)
            await store.editorDraftRegistry.waitForSecretTasks(for: store)
            let removedAfterRemembering = await secrets.removed
            XCTAssertTrue(removedAfterRemembering.isEmpty)
        }
    }

    func testUndoableReplacementRetainsDraftUntilUndoRestoresRow() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("parallax-editor-replacement-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(applicationSupportURL: root)
        let profile = LaunchProfile(name: "Original")
        let application = ManagedApplication(
            displayName: "Synthetic", appPath: "/tmp/Synthetic.app", profiles: [profile]
        )
        _ = try repository.save([application], expectedVersion: .missing)
        let coordinator = LibraryImportReplacementCoordinator(
            repository: repository,
            backupStore: LibraryBackupStore(recoveryRoot: root.appendingPathComponent("Recovery"))
        )
        let secrets = EditorAuditSecretStore()
        let store = LibraryStore(
            persistence: EditorAuditPersistence(applications: [application]),
            repository: repository, secretStore: secrets
        )
        XCTAssertTrue(store.canConfirmProfileRemoval)
        let reference = EnvironmentSecretReference()
        remember([reference], in: store, application: application, profile: profile)
        let replacement = try coordinator.replace(using: coordinator.preview(
            importData: JSONEncoder().encode(LibraryDocument(applications: []))
        ))
        store.applications = replacement.snapshot.applications
        store.libraryVersionToken = replacement.snapshot.versionToken
        store.lastImportReplacement = replacement
        await store.discardRemovedProfileEditingDrafts()
        remember([reference], in: store, application: application, profile: profile)
        XCTAssertEqual(store.profileEditingDrafts.count, 1)
        let undone = try coordinator.undo(replacement: replacement)
        store.applications = undone.snapshot.applications
        store.libraryVersionToken = undone.snapshot.versionToken
        store.lastImportReplacement = nil
        await store.discardRemovedProfileEditingDrafts()
        await store.editorDraftRegistry.waitForSecretTasks(for: store)
        XCTAssertEqual(store.profileEditingDrafts.count, 1)
        let removed = await secrets.removed
        XCTAssertTrue(removed.isEmpty)
        store.applications = []
        await store.discardRemovedProfileEditingDrafts()
        XCTAssertTrue(store.profileEditingDrafts.isEmpty)
        let removedAfterDeletion = await secrets.removed
        XCTAssertEqual(removedAfterDeletion, [reference])
    }

    private func remember(
        _ references: Set<EnvironmentSecretReference>,
        in store: LibraryStore,
        application: ManagedApplication,
        profile: LaunchProfile
    ) {
        var draft = profile
        draft.environmentText = references.enumerated().map {
            "TOKEN_\($0.offset)=\($0.element.token)"
        }.joined(separator: "\n")
        store.rememberProfileEditingDraft(
            applicationID: application.id, draft: draft, baseline: profile,
            baselineVersion: .missing, stagedKeychainReferences: references,
            pendingKeychainDeletionReferences: []
        )
    }
}

struct EditorAuditPersistence: LibraryPersisting {
    let applications: [ManagedApplication]
    func load() throws -> [ManagedApplication] { applications }
    func loadResult() throws -> LibraryLoadResult { .current(applications) }
    func save(_ applications: [ManagedApplication]) throws {}
}

actor EditorAuditSecretStore: SecretStoring {
    let failsToStore: Bool
    init(failsToStore: Bool = false) { self.failsToStore = failsToStore }
    var removed: Set<EnvironmentSecretReference> = []
    func resolve(_ reference: EnvironmentSecretReference) async throws -> SecretValue {
        throw SecretStoreError.missing(reference)
    }
    func store(_ value: SecretValue, for reference: EnvironmentSecretReference) async throws {
        if failsToStore { throw CocoaError(.fileWriteUnknown) }
    }
    func remove(_ reference: EnvironmentSecretReference) async throws { removed.insert(reference) }
}
