import Foundation
import Observation

struct ProfileTemplateResetReceipt: Identifiable, Equatable, Sendable {
    let id: UUID
    fileprivate let previousTemplates: [ProfileTemplate]
    fileprivate let resetTemplates: [ProfileTemplate]
}

@Observable
@MainActor
final class AppSettings {
    static let defaultProfileTemplateNames = ProfileTemplate.defaultNames

    enum PersistenceAuthority: Equatable, Sendable {
        case memoryOnly
        case legacyCompatibility
        case versionedRepository
        case recoveryOnly
    }

    var profileTemplates: [ProfileTemplate] {
        didSet {
            if rejectChangeInRecovery({ profileTemplates = oldValue }) {
                return
            }
            if let receipt = pendingProfileTemplateReset,
               receipt.resetTemplates != profileTemplates
            {
                pendingProfileTemplateReset = nil
            }
            settingsDidChange(.replaceProfileTemplates(profileTemplates)) {
                record(
                    legacyPersistence?.persistProfileTemplates(
                        profileTemplates
                    ) ?? []
                )
            }
        }
    }
    var defaultBaseStoragePath: String {
        didSet {
            if rejectChangeInRecovery({ defaultBaseStoragePath = oldValue }) {
                return
            }
            settingsDidChange(
                .setDefaultBaseStoragePath(defaultBaseStoragePath)
            ) {
                record(
                    legacyPersistence?.persistDefaultBaseStoragePath(
                        defaultBaseStoragePath
                    ) ?? []
                )
            }
        }
    }
    var confirmBeforeLaunch: Bool {
        didSet {
            if rejectChangeInRecovery({ confirmBeforeLaunch = oldValue }) {
                return
            }
            settingsDidChange(.setConfirmBeforeLaunch(confirmBeforeLaunch)) {
                record(
                    legacyPersistence?.persistConfirmBeforeLaunch(
                        confirmBeforeLaunch
                    ) ?? []
                )
            }
        }
    }
    var automaticallyRecoverCrashedApps: Bool {
        didSet {
            if rejectChangeInRecovery({
                automaticallyRecoverCrashedApps = oldValue
            }) {
                return
            }
            settingsDidChange(
                .setAutomaticallyRecoverCrashedApps(
                    automaticallyRecoverCrashedApps
                )
            ) {
                record(
                    legacyPersistence?
                        .persistAutomaticallyRecoverCrashedApps(
                            automaticallyRecoverCrashedApps
                        ) ?? []
                )
            }
        }
    }
    var appearance: AppAppearance {
        didSet {
            if rejectChangeInRecovery({ appearance = oldValue }) {
                return
            }
            settingsDidChange(.setAppearance(appearance)) {
                record(
                    legacyPersistence?.persistAppearance(appearance) ?? []
                )
            }
        }
    }
    private(set) var profileVisualIdentities:
        [String: ProfileInstanceVisualIdentity]
    private(set) var persistenceIssues: [AppSettingsPersistenceIssue]
    private(set) var pendingProfileTemplateReset:
        ProfileTemplateResetReceipt?

    private(set) var persistenceAuthority: PersistenceAuthority
    private(set) var pendingVersionedMutationCount: Int
    @ObservationIgnored
    private(set) var migrationEvidence: SettingsMigrationEvidence?
    @ObservationIgnored
    private let legacyPersistence: AppSettingsLegacyPersistence?
    @ObservationIgnored
    private let runtimeCoordinator: SettingsMutationCoordinator?
    @ObservationIgnored
    private var pendingRuntimeMutationTask: Task<Void, Never>?
    @ObservationIgnored
    private var runtimeMutationSequence = 0
    @ObservationIgnored
    private var isApplyingRuntimeState = false

    /// Creates a non-persistent facade for previews and isolated model tests.
    /// Production startup must use `init(production:)`.
    init() {
        persistenceAuthority = .memoryOnly
        pendingVersionedMutationCount = 0
        migrationEvidence = nil
        legacyPersistence = nil
        runtimeCoordinator = nil
        pendingRuntimeMutationTask = nil
        persistenceIssues = []
        pendingProfileTemplateReset = nil
        profileTemplates = ProfileTemplate.defaults
        profileVisualIdentities = [:]
        defaultBaseStoragePath = ""
        confirmBeforeLaunch = false
        automaticallyRecoverCrashedApps = true
        appearance = .system
    }

    /// Compatibility authority for existing characterization tests. Runtime
    /// application construction never selects this initializer.
    init(userDefaults: UserDefaults) {
        let legacyPersistence = AppSettingsLegacyPersistence(
            userDefaults: userDefaults
        )
        let loaded = legacyPersistence.load()

        persistenceAuthority = .legacyCompatibility
        pendingVersionedMutationCount = 0
        migrationEvidence = nil
        self.legacyPersistence = legacyPersistence
        runtimeCoordinator = nil
        pendingRuntimeMutationTask = nil
        persistenceIssues = loaded.persistenceIssues
        pendingProfileTemplateReset = nil
        profileTemplates = loaded.profileTemplates
        profileVisualIdentities = loaded.profileVisualIdentities
        defaultBaseStoragePath = loaded.defaultBaseStoragePath
        confirmBeforeLaunch = loaded.confirmBeforeLaunch
        automaticallyRecoverCrashedApps =
            loaded.automaticallyRecoverCrashedApps
        appearance = loaded.appearance
    }

    init(production bootstrap: SettingsRuntimeBootstrapResult) {
        pendingVersionedMutationCount = 0
        legacyPersistence = nil
        pendingRuntimeMutationTask = nil
        persistenceIssues = []
        pendingProfileTemplateReset = nil

        let state: SettingsState
        switch bootstrap {
        case .ready(let runtime):
            persistenceAuthority = .versionedRepository
            migrationEvidence = runtime.migrationEvidence
            runtimeCoordinator = runtime.coordinator
            state = runtime.initialState
        case .recoveryRequired(let recovery):
            persistenceAuthority = .recoveryOnly
            if case .migration(let evidence) = recovery {
                migrationEvidence = evidence.planned
            } else {
                migrationEvidence = nil
            }
            runtimeCoordinator = nil
            state = .defaults
            persistenceIssues = [.versionedBootstrapRecovery(recovery)]
        }

        profileTemplates = state.profileTemplates
        profileVisualIdentities = Dictionary(
            uniqueKeysWithValues: state.profileVisualIdentities.map {
                ($0.key.uuidString.lowercased(), $0.value)
            }
        )
        defaultBaseStoragePath = state.defaultBaseStoragePath
        confirmBeforeLaunch = state.confirmBeforeLaunch
        automaticallyRecoverCrashedApps =
            state.automaticallyRecoverCrashedApps
        appearance = state.appearance
    }

    var profileTemplateNames: [String] {
        profileTemplates.map(\.name)
    }

    var canModifySettings: Bool {
        persistenceAuthority != .recoveryOnly
    }

    var hasPendingVersionedMutations: Bool {
        pendingVersionedMutationCount > 0
    }

    /// Settings-dependent side effects must use this authority rather than
    /// UI editability. Versioned fields are optimistic until every queued
    /// mutation has reached a verified repository result.
    var canProvideVerifiedSettings: Bool {
        switch persistenceAuthority {
        case .memoryOnly, .legacyCompatibility:
            return true
        case .versionedRepository:
            return pendingVersionedMutationCount == 0
        case .recoveryOnly:
            return false
        }
    }

    var canUndoProfileTemplateReset: Bool {
        guard let receipt = pendingProfileTemplateReset else {
            return false
        }
        return receipt.resetTemplates == profileTemplates
    }

    func profileTemplate(id: ProfileTemplate.ID) -> ProfileTemplate? {
        profileTemplates.first { $0.id == id }
    }

    func profileVisualIdentity(
        for profileID: UUID
    ) -> ProfileInstanceVisualIdentity {
        profileVisualIdentities[
            profileID.uuidString.lowercased()
        ] ?? ProfileInstanceVisualIdentity(profileID: profileID)
    }

    func hasProfileVisualIdentity(for profileID: UUID) -> Bool {
        profileVisualIdentities[
            profileID.uuidString.lowercased()
        ] != nil
    }

    func setProfileVisualSymbol(
        _ symbol: ProfileInstanceVisualSymbol,
        for profileID: UUID
    ) {
        guard canModifySettings else { return }
        guard
            ProfileInstanceVisualIdentity
                .selectableSymbols.contains(symbol)
        else { return }
        let current = profileVisualIdentity(for: profileID)
        setProfileVisualIdentity(
            ProfileInstanceVisualIdentity(
                symbol: symbol,
                color: current.color
            ),
            for: profileID
        )
    }

    func setProfileVisualColor(
        _ color: ProfileInstanceVisualColor,
        for profileID: UUID
    ) {
        guard canModifySettings else { return }
        guard
            ProfileInstanceVisualIdentity
                .selectableColors.contains(color)
        else { return }
        let current = profileVisualIdentity(for: profileID)
        setProfileVisualIdentity(
            ProfileInstanceVisualIdentity(
                symbol: current.symbol,
                color: color
            ),
            for: profileID
        )
    }

    func resetProfileVisualIdentity(for profileID: UUID) {
        guard canModifySettings else { return }
        let key = profileID.uuidString.lowercased()
        guard profileVisualIdentities.removeValue(
            forKey: key
        ) != nil else { return }
        settingsDidChange(
            .setProfileVisualIdentity(
                profileID: profileID,
                identity: nil
            )
        ) {
            persistLegacyProfileVisualIdentities()
        }
    }

    func resetAllProfileVisualIdentities() {
        guard canModifySettings else { return }
        profileVisualIdentities = [:]
        settingsDidChange(.resetAllProfileVisualIdentities) {
            persistLegacyProfileVisualIdentities()
        }
    }

    @discardableResult
    func addProfileTemplate(named name: String) -> ProfileTemplate.ID? {
        guard canModifySettings else { return nil }
        guard let normalizedName = DisplayNameValidator.normalized(name) else {
            return nil
        }
        let template = ProfileTemplate(name: normalizedName)
        profileTemplates.append(template)
        return template.id
    }

    @discardableResult
    func replaceProfileTemplate(_ template: ProfileTemplate) -> Bool {
        guard canModifySettings else { return false }
        guard let normalizedName = DisplayNameValidator.normalized(
            template.name
        ) else {
            return false
        }
        guard let index = profileTemplates.firstIndex(where: {
            $0.id == template.id
        }) else {
            return false
        }
        var normalizedTemplate = template
        normalizedTemplate.name = normalizedName
        guard profileTemplates[index] != normalizedTemplate else {
            return true
        }
        profileTemplates[index] = normalizedTemplate
        return true
    }

    @discardableResult
    func removeProfileTemplate(id: ProfileTemplate.ID) -> Bool {
        guard canModifySettings else { return false }
        guard let index = profileTemplates.firstIndex(where: {
            $0.id == id
        }) else {
            return false
        }
        profileTemplates.remove(at: index)
        return true
    }

    @discardableResult
    func resetProfileTemplatesToDefaults() -> Bool {
        guard canModifySettings else { return false }
        let resetTemplates = ProfileTemplate.defaults
        guard profileTemplates != resetTemplates else {
            pendingProfileTemplateReset = nil
            return false
        }
        pendingProfileTemplateReset = ProfileTemplateResetReceipt(
            id: UUID(),
            previousTemplates: profileTemplates,
            resetTemplates: resetTemplates
        )
        profileTemplates = resetTemplates
        return true
    }

    @discardableResult
    func undoProfileTemplateReset() -> Bool {
        guard canModifySettings else { return false }
        guard let receipt = pendingProfileTemplateReset,
              receipt.resetTemplates == profileTemplates
        else {
            pendingProfileTemplateReset = nil
            return false
        }
        pendingProfileTemplateReset = nil
        profileTemplates = receipt.previousTemplates
        return true
    }

    func dismissPersistenceIssue(id: AppSettingsPersistenceIssue.ID) {
        persistenceIssues.removeAll { $0.id == id }
    }

    func quarantinedProfileTemplateData(
        for issue: AppSettingsPersistenceIssue
    ) -> Data? {
        guard case .corruptProfileTemplates = issue else { return nil }
        return legacyPersistence?.quarantinedData(for: issue)
    }

    func quarantinedSettingsData(
        for issue: AppSettingsPersistenceIssue
    ) -> Data? {
        switch issue {
        case .corruptProfileTemplates,
             .corruptProfileVisualIdentities:
            return legacyPersistence?.quarantinedData(for: issue)
        case .versionedBootstrapRecovery(let recovery):
            return recovery.preservedPrimaryBytes
        case .versionedMutationRecovery(let failure):
            return failure.preservedPrimaryBytes
        default:
            return nil
        }
    }

    private func setProfileVisualIdentity(
        _ identity: ProfileInstanceVisualIdentity,
        for profileID: UUID
    ) {
        profileVisualIdentities[
            profileID.uuidString.lowercased()
        ] = identity
        settingsDidChange(
            .setProfileVisualIdentity(
                profileID: profileID,
                identity: identity
            )
        ) {
            persistLegacyProfileVisualIdentities()
        }
    }

    private func persistLegacyProfileVisualIdentities() {
        record(
            legacyPersistence?.persistProfileVisualIdentities(
                profileVisualIdentities
            ) ?? []
        )
    }

    private func record(_ issue: AppSettingsPersistenceIssue) {
        if !persistenceIssues.contains(issue) {
            persistenceIssues.append(issue)
        }
    }

    private func record(_ issues: [AppSettingsPersistenceIssue]) {
        for issue in issues {
            record(issue)
        }
    }

    private func settingsDidChange(
        _ mutation: SettingsMutation,
        legacyWrite: () -> Void
    ) {
        guard !isApplyingRuntimeState else { return }
        switch persistenceAuthority {
        case .memoryOnly:
            break
        case .legacyCompatibility:
            legacyWrite()
        case .versionedRepository:
            enqueueRuntimeMutation(mutation)
        case .recoveryOnly:
            break
        }
    }

    private func rejectChangeInRecovery(
        _ revert: () -> Void
    ) -> Bool {
        guard persistenceAuthority == .recoveryOnly,
              !isApplyingRuntimeState
        else { return false }
        isApplyingRuntimeState = true
        revert()
        isApplyingRuntimeState = false
        return true
    }

    private func enqueueRuntimeMutation(_ mutation: SettingsMutation) {
        guard let runtimeCoordinator else { return }
        pendingVersionedMutationCount += 1
        runtimeMutationSequence += 1
        let sequence = runtimeMutationSequence
        let preceding = pendingRuntimeMutationTask
        pendingRuntimeMutationTask = Task { [weak self] in
            await preceding?.value
            defer { self?.finishPendingRuntimeMutation() }
            guard !Task.isCancelled,
                  let self,
                  persistenceAuthority == .versionedRepository
            else { return }
            let result = await runtimeCoordinator.apply(mutation)
            consumeRuntimeMutation(result, sequence: sequence)
        }
    }

    private func finishPendingRuntimeMutation() {
        precondition(pendingVersionedMutationCount > 0)
        pendingVersionedMutationCount -= 1
    }

    private func consumeRuntimeMutation(
        _ result: SettingsMutationCoordinatorResult,
        sequence: Int
    ) {
        switch result {
        case .committed(let state, _), .unchanged(let state, _):
            guard sequence == runtimeMutationSequence else { return }
            applyRuntimeState(state)
        case .recoveryRequired(let failure, let lastKnownState):
            persistenceAuthority = .recoveryOnly
            runtimeMutationSequence += 1
            record(.versionedMutationRecovery(failure))
            applyRuntimeState(lastKnownState)
        }
    }

    private func applyRuntimeState(_ state: SettingsState) {
        isApplyingRuntimeState = true
        defer { isApplyingRuntimeState = false }
        profileTemplates = state.profileTemplates
        defaultBaseStoragePath = state.defaultBaseStoragePath
        confirmBeforeLaunch = state.confirmBeforeLaunch
        automaticallyRecoverCrashedApps =
            state.automaticallyRecoverCrashedApps
        appearance = state.appearance
        profileVisualIdentities = Dictionary(
            uniqueKeysWithValues: state.profileVisualIdentities.map {
                ($0.key.uuidString.lowercased(), $0.value)
            }
        )
    }

    func waitForPendingPersistence() async {
        await pendingRuntimeMutationTask?.value
    }
}

private extension SettingsRuntimeMutationFailure {
    var preservedPrimaryBytes: Data? {
        switch self {
        case .primaryChanged(let inspection):
            return inspection.preservedPrimaryBytes
        case .invalidMutation,
             .invalidRefreshedState,
             .commit,
             .retryLimitExceeded,
             .unexpected:
            return nil
        }
    }
}
