import Foundation
import Observation

@MainActor
@Observable
final class ProfileEditorSession {
    private(set) var target: ProfileEditorTarget
    var draft: LaunchProfile
    private(set) var baseline: LaunchProfile
    private(set) var baselineVersion: LibraryVersionToken
    var isRevealingSensitiveLiterals = false
    var isAdvancedSettingsExpanded: Bool
    private(set) var presentationPhase:
        ProfileEditorPresentationPhase = .idle
    private(set) var stagedKeychainReferences:
        Set<EnvironmentSecretReference>
    private(set) var pendingKeychainDeletionReferences:
        Set<EnvironmentSecretReference>

    @ObservationIgnored
    private let client: any ProfileEditorSessionClient
    @ObservationIgnored
    private var isActive = false
    @ObservationIgnored
    private var secretTask: Task<Void, Never>?

    init(
        client: any ProfileEditorSessionClient,
        application: ManagedApplication,
        profile: LaunchProfile
    ) {
        self.client = client
        target = ProfileEditorTarget(
            applicationID: application.id,
            profileID: profile.id,
            profileStorageID: profile.storageID
        )
        let pending = client.pendingProfileEditingDraft(
            applicationID: application.id,
            profileID: profile.id
        )
        let initialDraft = pending?.draft ?? profile
        draft = initialDraft
        baseline = pending?.baseline ?? profile
        baselineVersion =
            pending?.baselineVersion
            ?? client.currentLibraryVersion ?? .missing
        stagedKeychainReferences =
            pending?.stagedKeychainReferences ?? []
        pendingKeychainDeletionReferences =
            pending?.pendingKeychainDeletionReferences ?? []
        isAdvancedSettingsExpanded = Self.requiresAdvancedSettings(
            initialDraft
        )
    }

    var isSecretSheetPresented: Bool {
        get {
            if case .keychainSecret = presentationPhase {
                return true
            }
            return false
        }
        set {
            if newValue {
                if !isSecretSheetPresented {
                    beginAddingKeychainSecret()
                }
            } else {
                cancelAddingKeychainSecret()
            }
        }
    }

    var isImportingCodexHome: Bool {
        get { presentationPhase == .importingCodexHome }
        set {
            if newValue {
                cancelSecretTask()
                presentationPhase = .importingCodexHome
            } else if presentationPhase == .importingCodexHome {
                presentationPhase = .idle
            }
        }
    }

    var keychainEnvironmentKey: String {
        get { presentedSecretPhase?.form?.environmentKey ?? "" }
        set { updateSecretForm { $0.environmentKey = newValue } }
    }

    var keychainSecretValue: String {
        get { presentedSecretPhase?.form?.secretValue ?? "" }
        set { updateSecretForm { $0.secretValue = newValue } }
    }

    var isSavingKeychainSecret: Bool {
        presentedSecretPhase?.isSaving == true
    }

    func activate() {
        isActive = true
    }

    func deactivate() {
        isActive = false
        rememberDraft()
        cancelPresentedOperation()
    }

    func draftDidChange() {
        rememberDraft()
        if Self.requiresAdvancedSettings(draft) {
            isAdvancedSettingsExpanded = true
        }
    }

    func synchronize(
        application: ManagedApplication,
        profile newValue: LaunchProfile
    ) {
        let isTargetReplacement =
            application.id != target.applicationID
            || newValue.id != target.profileID
            || newValue.storageID != target.profileStorageID
        let shouldReplace =
            isTargetReplacement
            || draft == baseline

        if shouldReplace {
            if isTargetReplacement {
                cancelPresentedOperation()
            }
            let abandonedReferences = stagedKeychainReferences
            stagedKeychainReferences = []
            pendingKeychainDeletionReferences = []
            target = ProfileEditorTarget(
                applicationID: application.id,
                profileID: newValue.id,
                profileStorageID: newValue.storageID
            )
            draft = newValue
            baseline = newValue
            baselineVersion =
                client.currentLibraryVersion ?? baselineVersion
            discardKeychainReferences(abandonedReferences)
        }

        if isTargetReplacement {
            isRevealingSensitiveLiterals = false
        }
    }

    @discardableResult
    func applyDraft() -> LaunchProfile? {
        guard
            client.applyProfileEdit(
                draft: draft,
                baseline: baseline,
                applicationID: target.applicationID,
                baselineVersion: baselineVersion
            )
        else {
            return nil
        }
        guard
            let persistedApplication = client.applications.first(where: {
                $0.id == target.applicationID
            }),
            let persisted = persistedApplication.profiles.first(where: {
                $0.id == target.profileID
            })
        else {
            return nil
        }

        draft = persisted
        baseline = persisted
        baselineVersion =
            client.currentLibraryVersion ?? baselineVersion
        let retainedReferences = keychainReferences(in: persisted)
        let obsoleteStaged =
            stagedKeychainReferences.subtracting(retainedReferences)
        let referencesToDelete =
            pendingKeychainDeletionReferences.union(obsoleteStaged)
        stagedKeychainReferences = []
        pendingKeychainDeletionReferences = []
        client.forgetProfileEditingDraft(profileID: persisted.id)
        discardKeychainReferences(referencesToDelete)
        return persisted
    }

    func saveAndOpen() {
        SpaceEditorWorkflow.saveAndOpen(
            draft: draft,
            baseline: baseline,
            save: applyDraft,
            open: client.launch
        )
    }

    func revertDraft() {
        cancelAddingKeychainSecret()
        let staged = stagedKeychainReferences
        stagedKeychainReferences = []
        pendingKeychainDeletionReferences = []
        draft = baseline
        client.forgetProfileEditingDraft(profileID: target.profileID)
        discardKeychainReferences(staged)
    }

    func rememberDraft() {
        client.rememberProfileEditingDraft(
            applicationID: target.applicationID,
            draft: draft,
            baseline: baseline,
            baselineVersion: baselineVersion,
            stagedKeychainReferences: stagedKeychainReferences,
            pendingKeychainDeletionReferences:
                pendingKeychainDeletionReferences
        )
    }

    func beginAddingKeychainSecret() {
        cancelSecretTask()
        presentationPhase = .keychainSecret(
            .editing(ProfileEditorSecretForm())
        )
    }

    func cancelAddingKeychainSecret() {
        guard case .keychainSecret = presentationPhase else {
            return
        }
        cancelSecretTask()
        presentationPhase = .idle
    }

    func saveKeychainSecret() {
        guard
            case .keychainSecret(.editing(let form)) =
                presentationPhase
        else { return }
        let key = form.environmentKey
        let secret = form.secretValue
        let sourceDraft = draft
        let sourceTarget = target
        let operationID = UUID()
        var displayForm = form
        displayForm.secretValue = ""
        presentationPhase = .keychainSecret(
            .saving(
                form: displayForm,
                operationID: operationID
            )
        )

        secretTask = Task { [weak self, client] in
            let staged = await client.stageKeychainSecret(
                secret,
                environmentKey: key,
                in: sourceDraft
            )
            guard let self else {
                if let staged {
                    _ = await client.discardKeychainSecret(
                        staged.reference
                    )
                }
                return
            }
            await self.completeKeychainStaging(
                staged,
                operationID: operationID,
                sourceDraft: sourceDraft,
                sourceTarget: sourceTarget
            )
        }
    }

    func removeKeychainSecret(for key: String) {
        guard
            let removal = client.profileDraftRemovingKeychainSecret(
                environmentKey: key,
                from: draft
            )
        else { return }

        draft = removal.profile
        if stagedKeychainReferences.remove(removal.reference) != nil {
            discardKeychainReferences([removal.reference])
        } else {
            pendingKeychainDeletionReferences.insert(removal.reference)
        }
        rememberDraft()
    }

    private func completeKeychainStaging(
        _ staged: StagedProfileKeychainSecret?,
        operationID: UUID,
        sourceDraft: LaunchProfile,
        sourceTarget: ProfileEditorTarget
    ) async {
        let isCurrentOperation: Bool
        if case .keychainSecret(
            .saving(_, let currentOperationID)
        ) = presentationPhase {
            isCurrentOperation = currentOperationID == operationID
        } else {
            isCurrentOperation = false
        }

        guard let staged else {
            if isCurrentOperation,
               case .keychainSecret(.saving(let form, _)) =
                presentationPhase
            {
                presentationPhase = .keychainSecret(.editing(form))
                secretTask = nil
            }
            return
        }

        guard
            isCurrentOperation,
            !Task.isCancelled,
            isActive,
            target == sourceTarget,
            draft == sourceDraft
        else {
            _ = await client.discardKeychainSecret(staged.reference)
            if isCurrentOperation,
               case .keychainSecret(.saving(let form, _)) =
                presentationPhase
            {
                presentationPhase = .keychainSecret(.editing(form))
                secretTask = nil
            }
            return
        }

        draft = staged.profile
        stagedKeychainReferences.insert(staged.reference)
        rememberDraft()
        presentationPhase = .idle
        secretTask = nil
    }

    private func updateSecretForm(
        _ update: (inout ProfileEditorSecretForm) -> Void
    ) {
        switch presentationPhase {
        case .idle, .importingCodexHome:
            return
        case .keychainSecret(.editing(var form)):
            update(&form)
            presentationPhase = .keychainSecret(.editing(form))
        case .keychainSecret(
            .saving(var form, let operationID)
        ):
            update(&form)
            presentationPhase = .keychainSecret(
                .saving(
                    form: form,
                    operationID: operationID
                )
            )
        }
    }

    private var presentedSecretPhase: ProfileEditorSecretPhase? {
        guard case .keychainSecret(let phase) = presentationPhase else {
            return nil
        }
        return phase
    }

    private func cancelPresentedOperation() {
        cancelSecretTask()
        presentationPhase = .idle
    }

    private func cancelSecretTask() {
        secretTask?.cancel()
        secretTask = nil
    }

    private func discardKeychainReferences(
        _ references: Set<EnvironmentSecretReference>
    ) {
        guard !references.isEmpty else { return }
        let client = client
        Task {
            for reference in references {
                _ = await client.discardKeychainSecret(reference)
            }
        }
    }

    private func keychainReferences(
        in profile: LaunchProfile
    ) -> Set<EnvironmentSecretReference> {
        Set(
            LaunchEnvironmentParser.parse(profile.environmentText)
                .effectiveValues.values.compactMap {
                    EnvironmentSecretReference(token: $0)
                }
        )
    }

    private static func requiresAdvancedSettings(
        _ profile: LaunchProfile
    ) -> Bool {
        LaunchArgumentParser.parse(profile.argumentsText).hasErrors
            || LaunchEnvironmentParser.parse(
                profile.environmentText
            ).hasErrors
            || profile.launchConfigurationTrust
                == .importedPendingReview
    }
}
