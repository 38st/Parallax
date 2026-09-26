import Foundation

@MainActor
protocol ProfileEditorSessionClient: AnyObject {
    var editorDraftRegistry: ProfileEditorDraftRegistry { get }
    var canConfirmProfileRemoval: Bool { get }
    var applications: [ManagedApplication] { get }
    var currentLibraryVersion: LibraryVersionToken? { get }
    var profileEditingDrafts: [PendingProfileEditingDraft] { get }
    var acceptsProfileEditingDrafts: Bool { get }
    func endProfileEditing()

    func pendingProfileEditingDraft(
        applicationID: ManagedApplication.ID,
        profileID: LaunchProfile.ID
    ) -> PendingProfileEditingDraft?

    func rememberProfileEditingDraft(
        applicationID: ManagedApplication.ID,
        draft: LaunchProfile,
        baseline: LaunchProfile,
        baselineVersion: LibraryVersionToken,
        stagedKeychainReferences: Set<EnvironmentSecretReference>,
        pendingKeychainDeletionReferences:
            Set<EnvironmentSecretReference>
    )

    func forgetProfileEditingDraft(profileID: LaunchProfile.ID)

    func applyProfileEdit(
        draft: LaunchProfile,
        baseline: LaunchProfile,
        applicationID: UUID,
        baselineVersion: LibraryVersionToken
    ) -> Bool

    func stageKeychainSecret(
        _ secret: String,
        environmentKey: String,
        in profile: LaunchProfile
    ) async -> StagedProfileKeychainSecret?

    func discardKeychainSecret(
        _ reference: EnvironmentSecretReference
    ) async -> Bool

    func profileDraftRemovingKeychainSecret(
        environmentKey: String,
        from profile: LaunchProfile
    ) -> (
        profile: LaunchProfile,
        reference: EnvironmentSecretReference
    )?

    func launch(_ profile: LaunchProfile)
}

extension LibraryStore: ProfileEditorSessionClient {}

struct ProfileEditorTarget: Equatable, Sendable {
    let applicationID: ManagedApplication.ID
    let profileID: LaunchProfile.ID
    let profileStorageID: UUID
}

struct ProfileEditorSecretForm: Equatable, Sendable {
    var environmentKey = ""
    var secretValue = ""
}

enum ProfileEditorSecretPhase: Equatable, Sendable {
    case editing(ProfileEditorSecretForm)
    case saving(
        form: ProfileEditorSecretForm,
        operationID: UUID
    )

    var form: ProfileEditorSecretForm? {
        switch self {
        case .editing(let form), .saving(let form, _):
            form
        }
    }

    var isSaving: Bool {
        if case .saving = self { return true }
        return false
    }
}

enum ProfileEditorPresentationPhase: Equatable, Sendable {
    case idle
    case importingCodexHome
    case keychainSecret(ProfileEditorSecretPhase)
}

@MainActor
extension ProfileEditorSessionClient {
    var profileEditingDrafts: [PendingProfileEditingDraft] {
        applications.flatMap { application in
            application.profiles.compactMap {
                pendingProfileEditingDraft(
                    applicationID: application.id, profileID: $0.id
                )
            }
        }
    }

    var acceptsProfileEditingDrafts: Bool { true }
    var canConfirmProfileRemoval: Bool { true }

    func endProfileEditing() {}

    func discardUnreferencedKeychainSecret(
        _ reference: EnvironmentSecretReference
    ) async -> Bool {
        guard !editorDraftRegistry.isRetained(reference, by: self) else {
            return false
        }
        return await discardKeychainSecret(reference)
    }

    func scheduleKeychainDiscard(
        _ references: Set<EnvironmentSecretReference>
    ) {
        guard !references.isEmpty else { return }
        let operationID = UUID()
        let task = Task {
            defer { editorDraftRegistry.finishSecretTask(operationID) }
            for reference in references {
                _ = await discardUnreferencedKeychainSecret(reference)
            }
        }
        editorDraftRegistry.trackSecretTask(
            task, id: operationID, client: self
        )
    }

    func discardProfileEditingDrafts(
        _ drafts: [PendingProfileEditingDraft]
    ) async {
        let references = drafts.reduce(into: Set<EnvironmentSecretReference>()) {
            $0.formUnion($1.stagedKeychainReferences)
        }
        for pending in drafts {
            forgetProfileEditingDraft(profileID: pending.draft.id)
        }
        for reference in references {
            _ = await discardUnreferencedKeychainSecret(reference)
        }
    }
}
