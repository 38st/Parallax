import Foundation

@MainActor
protocol ProfileEditorSessionClient: AnyObject {
    var applications: [ManagedApplication] { get }
    var currentLibraryVersion: LibraryVersionToken? { get }

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
