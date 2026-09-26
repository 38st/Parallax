import XCTest
@testable import Parallax

@MainActor
final class EditorSessionAuditRegressionTests: XCTestCase {
    func testSavingRemovalRetainsSecretUsedByDuplicate() async {
        let client = EditorAuditClient()
        let reference = EnvironmentSecretReference()
        client.applications[0].profiles[0].environmentText = "TOKEN=\(reference.token)"
        var duplicate = LaunchProfile(name: "Duplicate")
        duplicate.environmentText = "TOKEN=\(reference.token)"
        client.applications[0].profiles.append(duplicate)
        let session = client.session()
        session.removeKeychainSecret(for: "TOKEN")
        XCTAssertNotNil(session.applyDraft())
        await client.editorDraftRegistry.waitForSecretTasks(for: client)
        XCTAssertFalse(client.deleted.contains(reference))
    }

    func testSavingRemovalRetainsSecretReinsertedInSameProfile() async {
        let client = EditorAuditClient()
        let reference = EnvironmentSecretReference()
        client.applications[0].profiles[0].environmentText = "TOKEN=\(reference.token)"
        let session = client.session()
        session.removeKeychainSecret(for: "TOKEN")
        session.draft.environmentText = "OTHER_TOKEN=\(reference.token)"
        XCTAssertNotNil(session.applyDraft())
        await client.editorDraftRegistry.waitForSecretTasks(for: client)
        XCTAssertFalse(client.deleted.contains(reference))
    }

    func testSavingRemovalRetainsSecretInAnotherPendingDraft() async {
        let client = EditorAuditClient()
        let reference = EnvironmentSecretReference()
        client.applications[0].profiles[0].environmentText = "TOKEN=\(reference.token)"
        let other = LaunchProfile(name: "Other")
        client.applications[0].profiles.append(other)
        var pending = other
        pending.environmentText = "TOKEN=\(reference.token)"
        client.rememberProfileEditingDraft(
            applicationID: client.applications[0].id, draft: pending,
            baseline: other, baselineVersion: .missing,
            stagedKeychainReferences: [], pendingKeychainDeletionReferences: []
        )
        let session = client.session()
        session.removeKeychainSecret(for: "TOKEN")
        XCTAssertNotNil(session.applyDraft())
        await client.editorDraftRegistry.waitForSecretTasks(for: client)
        XCTAssertFalse(client.deleted.contains(reference))
    }

    func testDiscardAndCleanOpenResolveCurrentPersistedProfile() {
        let client = EditorAuditClient()
        let session = client.session()
        session.draft.notes = "Local change"
        client.applications[0].profiles[0].argumentsText = "--peer-saved"
        client.currentLibraryVersion = LibraryVersionToken(
            revision: .initial, primarySHA256: "peer-version"
        )
        session.revertDraft()
        XCTAssertEqual(session.baselineVersion, client.currentLibraryVersion)
        XCTAssertEqual(session.draft, client.applications[0].profiles[0])
        XCTAssertEqual(session.baseline, client.applications[0].profiles[0])
        client.applications[0].profiles[0].argumentsText = "--peer-saved-again"
        session.saveAndOpen()
        XCTAssertEqual(client.opened, [client.applications[0].profiles[0]])
        XCTAssertEqual(client.saveCount, 0)
    }

    func testCleanOpenDoesNotLaunchRemovedOrReplacedStorageIdentity() {
        let client = EditorAuditClient()
        let session = client.session()
        let originalID = client.applications[0].profiles[0].id
        client.applications[0].profiles = [LaunchProfile(id: originalID, name: "Replacement")]
        session.saveAndOpen()
        XCTAssertTrue(client.opened.isEmpty)
        client.applications[0].profiles = []
        session.saveAndOpen()
        XCTAssertTrue(client.opened.isEmpty)
    }

    func testReplacingKeychainTokenSchedulesOldSecretForDeletion() async {
        let client = EditorAuditClient()
        let reference = EnvironmentSecretReference()
        client.applications[0].profiles[0].environmentText = "TOKEN=\(reference.token)"
        let session = client.session()
        session.activate()
        session.beginAddingKeychainSecret()
        session.keychainEnvironmentKey = "TOKEN"
        session.keychainSecretValue = "synthetic"
        session.saveKeychainSecret()
        await client.editorDraftRegistry.waitForSecretTasks(for: client)
        XCTAssertTrue(session.pendingKeychainDeletionReferences.contains(reference))
        XCTAssertNotNil(session.applyDraft())
        await client.editorDraftRegistry.waitForSecretTasks(for: client)
        XCTAssertTrue(client.deleted.contains(reference))
    }

    func testStaleDiscardCompletionCannotResetNewSavingOperation() async {
        let client = EditorAuditClient()
        client.suspendStaging = true
        client.suspendDiscard = true
        let session = client.session()
        session.activate()
        session.beginAddingKeychainSecret()
        session.keychainSecretValue = "first"
        session.saveKeychainSecret()
        await waitUntil { client.stageContinuation != nil }
        session.draft.notes = "Changed during staging"
        client.finishStage()
        await waitUntil { client.discardContinuation != nil }
        let firstTasks = client.editorDraftRegistry.tasks(for: client)
        session.beginAddingKeychainSecret()
        session.keychainSecretValue = "second"
        session.saveKeychainSecret()
        await waitUntil { client.stageContinuation != nil }
        client.discardContinuation?.resume()
        client.discardContinuation = nil
        for task in firstTasks { await task.value }
        XCTAssertTrue(session.isSavingKeychainSecret)
        client.suspendDiscard = false
        client.finishStage()
        await client.editorDraftRegistry.waitForSecretTasks(for: client)
    }

}

@MainActor
final class EditorAuditClient: ProfileEditorSessionClient {
    let editorDraftRegistry: ProfileEditorDraftRegistry

    init(editorDraftRegistry: ProfileEditorDraftRegistry = ProfileEditorDraftRegistry()) {
        self.editorDraftRegistry = editorDraftRegistry
    }

    var applications = [ManagedApplication(
        displayName: "Synthetic", appPath: "/tmp/Synthetic.app",
        profiles: [LaunchProfile(name: "Work")]
    )]
    var currentLibraryVersion: LibraryVersionToken? = .missing
    var pending: [UUID: PendingProfileEditingDraft] = [:]
    var deleted: Set<EnvironmentSecretReference> = []
    var opened: [LaunchProfile] = []
    var saveCount = 0
    var acceptsProfileEditingDrafts = true
    func endProfileEditing() { acceptsProfileEditingDrafts = false }
    var suspendStaging = false
    var suspendDiscard = false
    var stageContinuation: CheckedContinuation<Void, Never>?
    var discardContinuation: CheckedContinuation<Void, Never>?

    func finishStage() {
        stageContinuation?.resume()
        stageContinuation = nil
    }

    func session() -> ProfileEditorSession {
        ProfileEditorSession(client: self, application: applications[0], profile: applications[0].profiles[0])
    }

    func pendingProfileEditingDraft(applicationID: UUID, profileID: UUID) -> PendingProfileEditingDraft? {
        pending[profileID]
    }

    func rememberProfileEditingDraft(
        applicationID: UUID, draft: LaunchProfile, baseline: LaunchProfile,
        baselineVersion: LibraryVersionToken,
        stagedKeychainReferences: Set<EnvironmentSecretReference>,
        pendingKeychainDeletionReferences: Set<EnvironmentSecretReference>
    ) {
        pending[draft.id] = PendingProfileEditingDraft(
            applicationID: applicationID, draft: draft, baseline: baseline,
            baselineVersion: baselineVersion, stagedKeychainReferences: stagedKeychainReferences,
            pendingKeychainDeletionReferences: pendingKeychainDeletionReferences
        )
    }

    func forgetProfileEditingDraft(profileID: UUID) { pending[profileID] = nil }

    func applyProfileEdit(draft: LaunchProfile, baseline: LaunchProfile, applicationID: UUID, baselineVersion: LibraryVersionToken) -> Bool {
        saveCount += 1
        applications[0].profiles[0] = draft
        return true
    }

    func stageKeychainSecret(_ secret: String, environmentKey: String, in profile: LaunchProfile) async -> StagedProfileKeychainSecret? {
        if suspendStaging {
            await withCheckedContinuation { stageContinuation = $0 }
        }
        let reference = EnvironmentSecretReference()
        var updated = profile
        updated.environmentText = "\(environmentKey)=\(reference.token)"
        return StagedProfileKeychainSecret(profile: updated, reference: reference)
    }

    func discardKeychainSecret(_ reference: EnvironmentSecretReference) async -> Bool {
        if suspendDiscard {
            await withCheckedContinuation { discardContinuation = $0 }
        }
        deleted.insert(reference)
        return true
    }

    func profileDraftRemovingKeychainSecret(environmentKey: String, from profile: LaunchProfile) -> (profile: LaunchProfile, reference: EnvironmentSecretReference)? {
        guard let token = LaunchEnvironmentParser.parse(profile.environmentText).effectiveValues[environmentKey],
              let reference = EnvironmentSecretReference(token: token) else { return nil }
        var updated = profile
        updated.environmentText = ""
        return (updated, reference)
    }

    func launch(_ profile: LaunchProfile) { opened.append(profile) }
}
