import Foundation
import Observation

enum WorkspaceTab: Hashable {
    case controlCenter
    case localSpaces
}

enum SceneRememberedProfileSelection: Sendable, Equatable {
    case profile(UUID)
    case explicitlyNone
}

enum SceneDialogKind: String, Sendable, Equatable {
    case launchConfirmation
    case launchDiagnosticOverride
    case importedLaunchReview
    case importChoice
    case importConflict
    case destructiveAction
    case error
}

struct SceneDialogPresentation: Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: SceneDialogKind
    let requestID: UUID?

    init(
        id: UUID = UUID(),
        kind: SceneDialogKind,
        requestID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.requestID = requestID
    }
}

enum SceneImporterKind: String, Sendable, Equatable {
    case application
    case library
    case codexHome
}

struct SceneImporterPresentation: Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: SceneImporterKind

    init(id: UUID = UUID(), kind: SceneImporterKind) {
        self.id = id
        self.kind = kind
    }
}

enum ScenePendingRequestKind: String, Sendable, Hashable {
    case launch
    case libraryImport
    case destructive
}

enum SceneTransientStatusKind: String, Sendable, Equatable {
    case progress
    case success
    case failure
}

struct SceneTransientStatus: Sendable, Equatable, Identifiable {
    let id: UUID
    let kind: SceneTransientStatusKind
    let message: String
    let applicationID: UUID?
    let profileID: UUID?
    let requestID: UUID?

    init(
        id: UUID = UUID(),
        kind: SceneTransientStatusKind,
        message: String,
        applicationID: UUID? = nil,
        profileID: UUID? = nil,
        requestID: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.message = message
        self.applicationID = applicationID
        self.profileID = profileID
        self.requestID = requestID
    }
}

/// Window-local observable state. Shared library data is accepted only as an
/// immutable input to selection and sanitation methods and is never retained.
@Observable
@MainActor
final class SceneCoordinator {
    let sceneID: UUID
    @ObservationIgnored var editorDraftRegistry = ProfileEditorDraftRegistry()
    var isClosing = false
    var isShowingApplicationSettings = false
    var isShowingKeychainSecretSheet = false
    var selectedWorkspaceTab: WorkspaceTab = .controlCenter
    var compactProfileListHeight: CGFloat = 220
    var profileListWidth: CGFloat = 260

    var presentsWorkspaceErrors: Bool {
        !isShowingApplicationSettings && !isShowingKeychainSecretSheet
    }

    private(set) var selectedApplicationID: UUID?
    private(set) var selectedProfileID: UUID?
    private(set) var presentedDialog: SceneDialogPresentation?
    private(set) var presentedImporter: SceneImporterPresentation?
    private(set) var transientStatus: SceneTransientStatus?

    @ObservationIgnored
    private var rememberedProfiles:
        [UUID: SceneRememberedProfileSelection] = [:]

    private var pendingRequestIDs:
        [ScenePendingRequestKind: UUID] = [:]

    init(sceneID: UUID = UUID()) {
        self.sceneID = sceneID
    }

    func selectApplication(
        _ applicationID: UUID?,
        in applications: [ManagedApplication]
    ) {
        guard let applicationID else {
            selectedApplicationID = nil
            selectedProfileID = nil
            return
        }
        guard
            let application = applications.first(where: {
                $0.id == applicationID
            })
        else {
            selectedApplicationID = nil
            selectedProfileID = nil
            return
        }

        selectedApplicationID = applicationID
        switch rememberedProfiles[applicationID] {
        case .profile(let profileID):
            if application.profiles.contains(where: { $0.id == profileID }) {
                selectedProfileID = profileID
            } else {
                rememberedProfiles[applicationID] = .explicitlyNone
                selectedProfileID = nil
            }
        case .explicitlyNone, nil:
            selectedProfileID = nil
        }
    }

    func selectProfile(
        _ profileID: UUID?,
        in applications: [ManagedApplication]
    ) {
        guard
            let selectedApplicationID,
            let application = applications.first(where: {
                $0.id == selectedApplicationID
            })
        else {
            selectedProfileID = nil
            return
        }
        guard
            let profileID,
            application.profiles.contains(where: { $0.id == profileID })
        else {
            selectedProfileID = nil
            rememberedProfiles[selectedApplicationID] = .explicitlyNone
            return
        }
        selectedProfileID = profileID
        rememberedProfiles[selectedApplicationID] = .profile(profileID)
    }

    /// Applies shared-library membership changes without changing any valid
    /// scene-local selection or presentation state.
    func synchronize(with applications: [ManagedApplication]) {
        let applicationIDs = Set(applications.map(\.id))
        rememberedProfiles = rememberedProfiles.filter {
            applicationIDs.contains($0.key)
        }
        for application in applications {
            guard
                case .profile(let profileID) =
                    rememberedProfiles[application.id],
                !application.profiles.contains(where: {
                    $0.id == profileID
                })
            else {
                continue
            }
            rememberedProfiles[application.id] = .explicitlyNone
        }

        guard let selectedApplicationID else {
            selectedProfileID = nil
            return
        }
        guard
            let application = applications.first(where: {
                $0.id == selectedApplicationID
            })
        else {
            self.selectedApplicationID = nil
            selectedProfileID = nil
            return
        }
        guard let selectedProfileID else { return }
        guard
            application.profiles.contains(where: {
                $0.id == selectedProfileID
            })
        else {
            self.selectedProfileID = nil
            rememberedProfiles[selectedApplicationID] = .explicitlyNone
            return
        }
    }

    func rememberedProfileSelection(
        for applicationID: UUID
    ) -> SceneRememberedProfileSelection? {
        rememberedProfiles[applicationID]
    }

    func selectedApplication(
        in applications: [ManagedApplication]
    ) -> ManagedApplication? {
        guard let selectedApplicationID else { return nil }
        return applications.first { $0.id == selectedApplicationID }
    }

    func selectedProfile(
        in applications: [ManagedApplication]
    ) -> LaunchProfile? {
        guard
            let application = selectedApplication(in: applications),
            let selectedProfileID
        else {
            return nil
        }
        return application.profiles.first { $0.id == selectedProfileID }
    }

    func presentDialog(_ presentation: SceneDialogPresentation?) {
        presentedDialog = presentation
    }

    func dismissDialog(id: UUID? = nil) {
        guard
            id == nil || presentedDialog?.id == id
        else {
            return
        }
        presentedDialog = nil
    }

    func presentImporter(_ presentation: SceneImporterPresentation?) {
        presentedImporter = presentation
    }

    func dismissImporter(id: UUID? = nil) {
        guard
            id == nil || presentedImporter?.id == id
        else {
            return
        }
        presentedImporter = nil
    }

    func setPendingRequest(
        _ requestID: UUID?,
        for kind: ScenePendingRequestKind
    ) {
        pendingRequestIDs[kind] = requestID
    }

    func pendingRequestID(
        for kind: ScenePendingRequestKind
    ) -> UUID? {
        pendingRequestIDs[kind]
    }

    @discardableResult
    func clearPendingRequest(
        for kind: ScenePendingRequestKind,
        matching requestID: UUID? = nil
    ) -> Bool {
        guard
            let current = pendingRequestIDs[kind],
            requestID == nil || requestID == current
        else {
            return false
        }
        pendingRequestIDs.removeValue(forKey: kind)
        return true
    }

    func setTransientStatus(_ status: SceneTransientStatus?) {
        transientStatus = status
    }

    func clearTransientStatus(matching requestID: UUID? = nil) {
        guard
            requestID == nil || transientStatus?.requestID == requestID
        else {
            return
        }
        transientStatus = nil
    }
}

struct SceneRoutingRequest: Sendable, Equatable {
    let originatingSceneID: UUID?

    init(originatingSceneID: UUID? = nil) {
        self.originatingSceneID = originatingSceneID
    }
}

/// Focus routing stores scene identities, not scene state or view references.
/// Captured origins always take precedence and are never silently retargeted.
@Observable
@MainActor
final class FocusedSceneRouter {
    private(set) var focusedSceneID: UUID?

    @ObservationIgnored
    private var registeredSceneIDs: Set<UUID> = []

    func register(_ sceneID: UUID) {
        registeredSceneIDs.insert(sceneID)
    }

    func register(_ coordinator: SceneCoordinator) {
        register(coordinator.sceneID)
    }

    func unregister(_ sceneID: UUID) {
        registeredSceneIDs.remove(sceneID)
        if focusedSceneID == sceneID {
            focusedSceneID = nil
        }
    }

    func setFocusedScene(_ sceneID: UUID?) {
        guard
            let sceneID,
            registeredSceneIDs.contains(sceneID)
        else {
            focusedSceneID = nil
            return
        }
        focusedSceneID = sceneID
    }

    func targetSceneID(for request: SceneRoutingRequest) -> UUID? {
        if let origin = request.originatingSceneID {
            return registeredSceneIDs.contains(origin) ? origin : nil
        }
        guard
            let focusedSceneID,
            registeredSceneIDs.contains(focusedSceneID)
        else {
            return nil
        }
        return focusedSceneID
    }
}

/// Other windows can retain a staged reference in a draft, even before it is
/// saved. Weak clients keep those references visible without retaining scenes.
@MainActor
final class ProfileEditorDraftRegistry {
    private final class WeakClient {
        weak var value: (any ProfileEditorSessionClient)?
        init(_ value: any ProfileEditorSessionClient) { self.value = value }
    }

    private var clients: [ObjectIdentifier: WeakClient] = [:]
    private var secretTasks:
        [UUID: (clientID: ObjectIdentifier, task: Task<Void, Never>)] = [:]

    func trackSecretTask(
        _ task: Task<Void, Never>,
        id: UUID,
        client: any ProfileEditorSessionClient
    ) {
        secretTasks[id] = (ObjectIdentifier(client), task)
    }

    func finishSecretTask(_ id: UUID) {
        secretTasks[id] = nil
    }

    func cancelSecretTasks(for client: any ProfileEditorSessionClient) async {
        for task in tasks(for: client) { task.cancel() }
        await waitForSecretTasks(for: client)
    }

    func tasks(for client: any ProfileEditorSessionClient) -> [Task<Void, Never>] {
        secretTasks.values.filter {
            $0.clientID == ObjectIdentifier(client)
        }.map(\.task)
    }

    func waitForSecretTasks(for client: any ProfileEditorSessionClient) async {
        while !tasks(for: client).isEmpty {
            for task in tasks(for: client) { await task.value }
        }
    }

    var hasPendingCleanup: Bool {
        !secretTasks.isEmpty || clients.values.contains {
            $0.value?.profileEditingDrafts.isEmpty == false
        }
    }

    func register(_ client: any ProfileEditorSessionClient) {
        clients = clients.filter { $0.value.value != nil }
        clients[ObjectIdentifier(client)] = WeakClient(client)
    }

    static func keychainReferences(
        in profile: LaunchProfile
    ) -> Set<EnvironmentSecretReference> {
        Set(LaunchEnvironmentParser.parse(profile.environmentText).entries.compactMap {
            guard case .set(let value) = $0.operation else { return nil }
            return EnvironmentSecretReference(token: value)
        })
    }

    func isRetained(
        _ reference: EnvironmentSecretReference,
        by client: any ProfileEditorSessionClient
    ) -> Bool {
        let liveClients = clients.values.compactMap(\.value) + [client]
        return client.applications.flatMap(\.profiles).contains {
            $0.environmentText.contains(reference.token)
                || $0.argumentsText.contains(reference.token)
        } || liveClients.contains { client in
            client.profileEditingDrafts.contains {
                $0.draft.environmentText.contains(reference.token)
                    || $0.draft.argumentsText.contains(reference.token)
            }
        }
    }

    func discardAllDrafts() async {
        let liveClients = clients.values.compactMap(\.value)
        for client in liveClients { client.endProfileEditing() }
        for client in liveClients { await cancelSecretTasks(for: client) }
        let draftsByClient = liveClients.map { ($0, $0.profileEditingDrafts) }
        for (client, drafts) in draftsByClient {
            for draft in drafts {
                client.forgetProfileEditingDraft(profileID: draft.draft.id)
            }
        }
        for (client, drafts) in draftsByClient {
            await client.discardProfileEditingDrafts(drafts)
        }
    }
}
