import XCTest
@testable import Parallax

@MainActor
final class ProfileEditorSessionTests: XCTestCase {
    func testExternalRefreshUpdatesCleanDraftButPreservesDirtyDraft() {
        let profile = LaunchProfile(name: "Original")
        let application = makeApplication(profile: profile)
        let cleanClient = ProfileEditorSessionClientDouble(
            applications: [application]
        )
        let cleanSession = ProfileEditorSession(
            client: cleanClient,
            application: application,
            profile: profile
        )
        var refreshed = profile
        refreshed.notes = "External refresh"

        cleanSession.synchronize(
            application: application,
            profile: refreshed
        )

        XCTAssertEqual(cleanSession.draft, refreshed)
        XCTAssertEqual(cleanSession.baseline, refreshed)

        let dirtyClient = ProfileEditorSessionClientDouble(
            applications: [application]
        )
        let dirtySession = ProfileEditorSession(
            client: dirtyClient,
            application: application,
            profile: profile
        )
        dirtySession.draft.notes = "Local edit"
        dirtySession.draftDidChange()

        dirtySession.synchronize(
            application: application,
            profile: refreshed
        )

        XCTAssertEqual(dirtySession.draft.notes, "Local edit")
        XCTAssertEqual(dirtySession.baseline, profile)
    }

    func testApplyFailureKeepsDraftAndSuccessfulRetryAdvancesBaseline() {
        let profile = LaunchProfile(name: "Original")
        let application = makeApplication(profile: profile)
        let client = ProfileEditorSessionClientDouble(
            applications: [application]
        )
        client.applyResults = [false, true]
        let session = ProfileEditorSession(
            client: client,
            application: application,
            profile: profile
        )
        session.draft.name = "Renamed"
        session.draftDidChange()

        XCTAssertNil(session.applyDraft())
        XCTAssertEqual(session.draft.name, "Renamed")
        XCTAssertEqual(session.baseline.name, "Original")

        let persisted = session.applyDraft()

        XCTAssertEqual(persisted?.name, "Renamed")
        XCTAssertEqual(session.draft, persisted)
        XCTAssertEqual(session.baseline, persisted)
        XCTAssertEqual(client.applyCallCount, 2)
    }

    func testCancellationRejectsAndDiscardsLateSecretCompletion()
        async
    {
        let profile = LaunchProfile(name: "Original")
        let application = makeApplication(profile: profile)
        let client = ProfileEditorSessionClientDouble(
            applications: [application]
        )
        let session = ProfileEditorSession(
            client: client,
            application: application,
            profile: profile
        )
        session.activate()
        session.beginAddingKeychainSecret()
        session.keychainEnvironmentKey = "SERVICE_TOKEN"
        session.keychainSecretValue = "secret"
        session.saveKeychainSecret()
        await waitUntil { client.hasPendingStage(secret: "secret") }

        session.cancelAddingKeychainSecret()
        let staged = stagedSecret(
            profile: profile,
            key: "SERVICE_TOKEN"
        )
        client.completeStage(secret: "secret", with: staged)
        await waitUntil {
            client.discardedReferences.contains(staged.reference)
        }

        XCTAssertEqual(session.presentationPhase, .idle)
        XCTAssertEqual(session.draft, profile)
        XCTAssertTrue(session.stagedKeychainReferences.isEmpty)
    }

    func testTargetReplacementDiscardsStagedReferences() async {
        let profile = LaunchProfile(name: "Original")
        let application = makeApplication(profile: profile)
        let client = ProfileEditorSessionClientDouble(
            applications: [application]
        )
        let session = ProfileEditorSession(
            client: client,
            application: application,
            profile: profile
        )
        session.activate()
        session.beginAddingKeychainSecret()
        session.keychainEnvironmentKey = "SERVICE_TOKEN"
        session.keychainSecretValue = "secret"
        session.saveKeychainSecret()
        await waitUntil { client.hasPendingStage(secret: "secret") }
        let staged = stagedSecret(
            profile: profile,
            key: "SERVICE_TOKEN"
        )
        client.completeStage(secret: "secret", with: staged)
        await waitUntil {
            session.stagedKeychainReferences.contains(
                staged.reference
            )
        }

        let replacement = LaunchProfile(name: "Replacement")
        let replacementApplication = makeApplication(
            profile: replacement,
            id: application.id
        )
        session.synchronize(
            application: replacementApplication,
            profile: replacement
        )
        await waitUntil {
            client.discardedReferences.contains(staged.reference)
        }

        XCTAssertEqual(session.draft, replacement)
        XCTAssertEqual(session.baseline, replacement)
        XCTAssertEqual(session.target.profileID, replacement.id)
        XCTAssertTrue(session.stagedKeychainReferences.isEmpty)
    }

    func testApplicationReplacementCannotRetainDirtyDraftForSameProfileIdentity() {
        let profile = LaunchProfile(name: "Original")
        let application = makeApplication(profile: profile)
        let client = ProfileEditorSessionClientDouble(
            applications: [application]
        )
        let session = ProfileEditorSession(
            client: client,
            application: application,
            profile: profile
        )
        session.draft.notes = "Local edit for the first application"
        session.draftDidChange()
        let replacementApplication = makeApplication(profile: profile)

        session.synchronize(
            application: replacementApplication,
            profile: profile
        )

        XCTAssertEqual(session.target.applicationID, replacementApplication.id)
        XCTAssertEqual(session.draft, profile)
        XCTAssertEqual(session.baseline, profile)
    }

    func testTargetReplacementDuringStagingDiscardsLateSecret() async {
        let profile = LaunchProfile(name: "Original")
        let application = makeApplication(profile: profile)
        let client = ProfileEditorSessionClientDouble(
            applications: [application]
        )
        let session = ProfileEditorSession(
            client: client,
            application: application,
            profile: profile
        )
        session.activate()
        session.isRevealingSensitiveLiterals = true
        session.beginAddingKeychainSecret()
        session.keychainEnvironmentKey = "SERVICE_TOKEN"
        session.keychainSecretValue = "secret"
        session.saveKeychainSecret()
        await waitUntil { client.hasPendingStage(secret: "secret") }

        let replacement = LaunchProfile(name: "Replacement")
        let replacementApplication = makeApplication(
            profile: replacement,
            id: application.id
        )
        session.synchronize(
            application: replacementApplication,
            profile: replacement
        )
        let stale = stagedSecret(
            profile: profile,
            key: "SERVICE_TOKEN"
        )
        client.completeStage(secret: "secret", with: stale)
        await waitUntil {
            client.discardedReferences.contains(stale.reference)
        }

        XCTAssertEqual(session.draft, replacement)
        XCTAssertEqual(session.presentationPhase, .idle)
        XCTAssertFalse(session.isRevealingSensitiveLiterals)
    }

    func testStaleCompletionCannotReplaceNewSecretOperation() async {
        let profile = LaunchProfile(name: "Original")
        let application = makeApplication(profile: profile)
        let client = ProfileEditorSessionClientDouble(
            applications: [application]
        )
        let session = ProfileEditorSession(
            client: client,
            application: application,
            profile: profile
        )
        session.activate()

        session.beginAddingKeychainSecret()
        session.keychainEnvironmentKey = "FIRST_TOKEN"
        session.keychainSecretValue = "first"
        session.saveKeychainSecret()
        await waitUntil { client.hasPendingStage(secret: "first") }

        session.beginAddingKeychainSecret()
        session.keychainEnvironmentKey = "SECOND_TOKEN"
        session.keychainSecretValue = "second"
        session.saveKeychainSecret()
        await waitUntil { client.hasPendingStage(secret: "second") }

        let stale = stagedSecret(
            profile: profile,
            key: "FIRST_TOKEN"
        )
        client.completeStage(secret: "first", with: stale)
        await waitUntil {
            client.discardedReferences.contains(stale.reference)
        }
        XCTAssertEqual(session.draft, profile)

        let current = stagedSecret(
            profile: profile,
            key: "SECOND_TOKEN"
        )
        client.completeStage(secret: "second", with: current)
        await waitUntil { session.presentationPhase == .idle }

        XCTAssertEqual(session.draft, current.profile)
        XCTAssertEqual(
            session.stagedKeychainReferences,
            [current.reference]
        )
    }

    private func makeApplication(
        profile: LaunchProfile,
        id: UUID = UUID()
    ) -> ManagedApplication {
        ManagedApplication(
            id: id,
            displayName: "Example",
            appPath: "/Applications/Example.app",
            profiles: [profile]
        )
    }

    private func stagedSecret(
        profile: LaunchProfile,
        key: String
    ) -> StagedProfileKeychainSecret {
        let reference = EnvironmentSecretReference()
        var updated = profile
        updated.environmentText = "\(key)=\(reference.token)"
        return StagedProfileKeychainSecret(
            profile: updated,
            reference: reference
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}

@MainActor
private final class ProfileEditorSessionClientDouble:
    ProfileEditorSessionClient
{
    var applications: [ManagedApplication]
    var currentLibraryVersion: LibraryVersionToken? = .missing
    var pendingDraft: PendingProfileEditingDraft?
    var applyResults: [Bool] = []
    private(set) var applyCallCount = 0
    private(set) var rememberedDraft: PendingProfileEditingDraft?
    private(set) var forgottenProfileIDs: [LaunchProfile.ID] = []
    private(set) var launchedProfiles: [LaunchProfile] = []
    private(set) var discardedReferences:
        Set<EnvironmentSecretReference> = []
    private var stageContinuations:
        [
            String:
                CheckedContinuation<
                    StagedProfileKeychainSecret?,
                    Never
                >
        ] = [:]

    init(applications: [ManagedApplication]) {
        self.applications = applications
    }

    func pendingProfileEditingDraft(
        applicationID: ManagedApplication.ID,
        profileID: LaunchProfile.ID
    ) -> PendingProfileEditingDraft? {
        guard pendingDraft?.applicationID == applicationID,
              pendingDraft?.draft.id == profileID
        else { return nil }
        return pendingDraft
    }

    func rememberProfileEditingDraft(
        applicationID: ManagedApplication.ID,
        draft: LaunchProfile,
        baseline: LaunchProfile,
        baselineVersion: LibraryVersionToken,
        stagedKeychainReferences: Set<EnvironmentSecretReference>,
        pendingKeychainDeletionReferences:
            Set<EnvironmentSecretReference>
    ) {
        rememberedDraft = PendingProfileEditingDraft(
            applicationID: applicationID,
            draft: draft,
            baseline: baseline,
            baselineVersion: baselineVersion,
            stagedKeychainReferences: stagedKeychainReferences,
            pendingKeychainDeletionReferences:
                pendingKeychainDeletionReferences
        )
    }

    func forgetProfileEditingDraft(profileID: LaunchProfile.ID) {
        forgottenProfileIDs.append(profileID)
    }

    func applyProfileEdit(
        draft: LaunchProfile,
        baseline: LaunchProfile,
        applicationID: UUID,
        baselineVersion: LibraryVersionToken
    ) -> Bool {
        applyCallCount += 1
        let result = applyResults.isEmpty
            ? true
            : applyResults.removeFirst()
        guard result,
              let applicationIndex = applications.firstIndex(where: {
                $0.id == applicationID
              }),
              let profileIndex = applications[applicationIndex]
                .profiles.firstIndex(where: { $0.id == baseline.id })
        else { return result }
        applications[applicationIndex].profiles[profileIndex] = draft
        return true
    }

    func stageKeychainSecret(
        _ secret: String,
        environmentKey: String,
        in profile: LaunchProfile
    ) async -> StagedProfileKeychainSecret? {
        await withCheckedContinuation { continuation in
            stageContinuations[secret] = continuation
        }
    }

    func discardKeychainSecret(
        _ reference: EnvironmentSecretReference
    ) async -> Bool {
        discardedReferences.insert(reference)
        return true
    }

    func profileDraftRemovingKeychainSecret(
        environmentKey: String,
        from profile: LaunchProfile
    ) -> (
        profile: LaunchProfile,
        reference: EnvironmentSecretReference
    )? {
        nil
    }

    func launch(_ profile: LaunchProfile) {
        launchedProfiles.append(profile)
    }

    func hasPendingStage(secret: String) -> Bool {
        stageContinuations[secret] != nil
    }

    func completeStage(
        secret: String,
        with result: StagedProfileKeychainSecret?
    ) {
        stageContinuations.removeValue(forKey: secret)?
            .resume(returning: result)
    }
}
