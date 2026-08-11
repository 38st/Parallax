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
                persistProfileTemplates()
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
                persist(
                    defaultBaseStoragePath,
                    forKey: Self.basePathKey
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
                persist(
                    confirmBeforeLaunch,
                    forKey: Self.confirmLaunchKey
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
                persist(
                    automaticallyRecoverCrashedApps,
                    forKey: Self.automaticCrashRecoveryKey
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
                persist(
                    appearance.rawValue,
                    forKey: Self.appearanceKey
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
    private let userDefaults: UserDefaults?
    @ObservationIgnored
    private let runtimeCoordinator: SettingsMutationCoordinator?
    @ObservationIgnored
    private var pendingRuntimeMutationTask: Task<Void, Never>?
    @ObservationIgnored
    private var runtimeMutationSequence = 0
    @ObservationIgnored
    private var isApplyingRuntimeState = false
    private var unquarantinedCorruptTemplateData: Data?
    private var unquarantinedCorruptProfileVisualIdentityData:
        Data?
    private static let templatesKey =
        SettingsLegacyKey.profileTemplates.rawValue
    private static let legacyTemplatesKey =
        SettingsLegacyKey.legacyProfileTemplateNames.rawValue
    private static let corruptTemplatesKeyPrefix =
        "settings.profileTemplates.corrupt."
    private static let basePathKey =
        SettingsLegacyKey.defaultBaseStoragePath.rawValue
    private static let confirmLaunchKey =
        SettingsLegacyKey.confirmBeforeLaunch.rawValue
    private static let automaticCrashRecoveryKey =
        SettingsLegacyKey.automaticallyRecoverCrashedApps.rawValue
    private static let appearanceKey =
        SettingsLegacyKey.appearance.rawValue
    private static let profileVisualIdentitiesKey =
        SettingsLegacyKey.profileVisualIdentities.rawValue
    private static let corruptProfileVisualIdentitiesKeyPrefix =
        "settings.profileVisualIdentities.corrupt."

    /// Creates a non-persistent facade for previews and isolated model tests.
    /// Production startup must use `init(production:)`.
    init() {
        persistenceAuthority = .memoryOnly
        pendingVersionedMutationCount = 0
        migrationEvidence = nil
        userDefaults = nil
        runtimeCoordinator = nil
        pendingRuntimeMutationTask = nil
        persistenceIssues = []
        pendingProfileTemplateReset = nil
        unquarantinedCorruptTemplateData = nil
        unquarantinedCorruptProfileVisualIdentityData = nil
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
        persistenceAuthority = .legacyCompatibility
        pendingVersionedMutationCount = 0
        migrationEvidence = nil
        self.userDefaults = userDefaults
        runtimeCoordinator = nil
        pendingRuntimeMutationTask = nil
        persistenceIssues = []
        pendingProfileTemplateReset = nil
        unquarantinedCorruptTemplateData = nil
        unquarantinedCorruptProfileVisualIdentityData = nil

        let templateLoad = Self.loadProfileTemplates(from: userDefaults)
        switch templateLoad {
        case let .stored(templates):
            profileTemplates = templates
        case let .legacy(templates):
            profileTemplates = templates
        case let .corrupt(data):
            profileTemplates = ProfileTemplate.defaults
            unquarantinedCorruptTemplateData = data
        case .defaults:
            profileTemplates = ProfileTemplate.defaults
        }
        if let data = userDefaults.data(
            forKey: Self.profileVisualIdentitiesKey
        ) {
            do {
                profileVisualIdentities = try JSONDecoder().decode(
                    [String: ProfileInstanceVisualIdentity].self,
                    from: data
                )
            } catch {
                profileVisualIdentities = [:]
                unquarantinedCorruptProfileVisualIdentityData =
                    data
            }
        } else {
            profileVisualIdentities = [:]
        }
        self.defaultBaseStoragePath = userDefaults.string(forKey: Self.basePathKey) ?? ""
        self.confirmBeforeLaunch = userDefaults.bool(forKey: Self.confirmLaunchKey)
        self.automaticallyRecoverCrashedApps =
            userDefaults.object(
                forKey: Self.automaticCrashRecoveryKey
            ) == nil
            ? true
            : userDefaults.bool(
                forKey: Self.automaticCrashRecoveryKey
            )
        self.appearance = AppAppearance(rawValue: userDefaults.string(forKey: Self.appearanceKey) ?? "") ?? .system

        switch templateLoad {
        case let .corrupt(data):
            quarantineCorruptProfileTemplates(data)
        case .legacy:
            if persistProfileTemplates() {
                removeLegacyTemplatesAfterMigration()
            }
        case .stored, .defaults:
            break
        }
        if let corruptData =
            unquarantinedCorruptProfileVisualIdentityData
        {
            quarantineCorruptProfileVisualIdentities(
                corruptData
            )
        }
    }

    init(production bootstrap: SettingsRuntimeBootstrapResult) {
        pendingVersionedMutationCount = 0
        userDefaults = nil
        pendingRuntimeMutationTask = nil
        persistenceIssues = []
        pendingProfileTemplateReset = nil
        unquarantinedCorruptTemplateData = nil
        unquarantinedCorruptProfileVisualIdentityData = nil

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
            persistProfileVisualIdentities()
        }
    }

    func resetAllProfileVisualIdentities() {
        guard canModifySettings else { return }
        profileVisualIdentities = [:]
        settingsDidChange(.resetAllProfileVisualIdentities) {
            persistProfileVisualIdentities()
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
        guard case let .corruptProfileTemplates(key, _) = issue,
              key.hasPrefix(Self.corruptTemplatesKeyPrefix),
              let userDefaults
        else {
            return nil
        }
        return userDefaults.data(forKey: key)
    }

    func quarantinedSettingsData(
        for issue: AppSettingsPersistenceIssue
    ) -> Data? {
        switch issue {
        case let .corruptProfileTemplates(key, _):
            guard key.hasPrefix(
                Self.corruptTemplatesKeyPrefix
            ), let userDefaults else { return nil }
            return userDefaults.data(forKey: key)
        case let .corruptProfileVisualIdentities(key, _):
            guard key.hasPrefix(
                Self.corruptProfileVisualIdentitiesKeyPrefix
            ), let userDefaults else { return nil }
            return userDefaults.data(forKey: key)
        case .versionedBootstrapRecovery(let recovery):
            return recovery.preservedPrimaryBytes
        case .versionedMutationRecovery(let failure):
            return failure.preservedPrimaryBytes
        default:
            return nil
        }
    }

    private enum ProfileTemplateLoad {
        case stored([ProfileTemplate])
        case legacy([ProfileTemplate])
        case corrupt(Data)
        case defaults
    }

    private static func loadProfileTemplates(
        from userDefaults: UserDefaults
    ) -> ProfileTemplateLoad {
        if let data = userDefaults.data(forKey: templatesKey) {
            do {
                return .stored(
                    try JSONDecoder().decode(
                        [ProfileTemplate].self,
                        from: data
                    )
                )
            } catch {
                return .corrupt(data)
            }
        }

        if let legacyNames =
            userDefaults.array(forKey: legacyTemplatesKey) as? [String],
           !legacyNames.isEmpty
        {
            return .legacy(
                legacyNames.map { ProfileTemplate(name: $0) }
            )
        }

        return .defaults
    }

    @discardableResult
    private func persistProfileTemplates() -> Bool {
        guard let userDefaults else { return false }
        if let corruptData = unquarantinedCorruptTemplateData {
            quarantineCorruptProfileTemplates(corruptData)
            guard unquarantinedCorruptTemplateData == nil else {
                return false
            }
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(profileTemplates)
        } catch {
            record(.profileTemplatesEncodingFailed)
            return false
        }

        userDefaults.set(data, forKey: Self.templatesKey)
        guard userDefaults.data(forKey: Self.templatesKey) == data else {
            record(.settingWriteFailed(key: Self.templatesKey))
            return false
        }
        return true
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
            persistProfileVisualIdentities()
        }
    }

    @discardableResult
    private func persistProfileVisualIdentities() -> Bool {
        guard let userDefaults else { return false }
        if let corruptData =
            unquarantinedCorruptProfileVisualIdentityData
        {
            quarantineCorruptProfileVisualIdentities(
                corruptData
            )
            guard
                unquarantinedCorruptProfileVisualIdentityData
                    == nil
            else {
                return false
            }
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(
                profileVisualIdentities
            )
        } catch {
            record(.profileVisualIdentitiesEncodingFailed)
            return false
        }

        userDefaults.set(
            data,
            forKey: Self.profileVisualIdentitiesKey
        )
        guard
            userDefaults.data(
                forKey: Self.profileVisualIdentitiesKey
            ) == data
        else {
            record(
                .settingWriteFailed(
                    key: Self.profileVisualIdentitiesKey
                )
            )
            return false
        }
        return true
    }

    private func quarantineCorruptProfileTemplates(_ data: Data) {
        guard let userDefaults else { return }
        if let existingKey = matchingQuarantineKey(for: data) {
            unquarantinedCorruptTemplateData = nil
            record(
                .corruptProfileTemplates(
                    quarantineKey: existingKey,
                    byteCount: data.count
                )
            )
            return
        }

        let quarantineKey =
            Self.corruptTemplatesKeyPrefix + UUID().uuidString.lowercased()
        userDefaults.set(data, forKey: quarantineKey)
        guard userDefaults.data(forKey: quarantineKey) == data else {
            record(
                .corruptProfileTemplatesQuarantineFailed(
                    byteCount: data.count
                )
            )
            return
        }

        unquarantinedCorruptTemplateData = nil
        record(
            .corruptProfileTemplates(
                quarantineKey: quarantineKey,
                byteCount: data.count
            )
        )
    }

    private func quarantineCorruptProfileVisualIdentities(
        _ data: Data
    ) {
        guard let userDefaults else { return }
        if let existingKey = matchingQuarantineKey(
            for: data,
            prefix: Self.corruptProfileVisualIdentitiesKeyPrefix
        ) {
            unquarantinedCorruptProfileVisualIdentityData = nil
            record(
                .corruptProfileVisualIdentities(
                    quarantineKey: existingKey,
                    byteCount: data.count
                )
            )
            return
        }

        let quarantineKey =
            Self.corruptProfileVisualIdentitiesKeyPrefix
            + UUID().uuidString.lowercased()
        userDefaults.set(data, forKey: quarantineKey)
        guard userDefaults.data(forKey: quarantineKey) == data else {
            record(
                .corruptProfileVisualIdentitiesQuarantineFailed(
                    byteCount: data.count
                )
            )
            return
        }

        unquarantinedCorruptProfileVisualIdentityData = nil
        record(
            .corruptProfileVisualIdentities(
                quarantineKey: quarantineKey,
                byteCount: data.count
            )
        )
    }

    private func matchingQuarantineKey(for data: Data) -> String? {
        matchingQuarantineKey(
            for: data,
            prefix: Self.corruptTemplatesKeyPrefix
        )
    }

    private func matchingQuarantineKey(
        for data: Data,
        prefix: String
    ) -> String? {
        guard let userDefaults else { return nil }
        return userDefaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .first { userDefaults.data(forKey: $0) == data }
    }

    private func removeLegacyTemplatesAfterMigration() {
        guard let userDefaults else { return }
        userDefaults.removeObject(forKey: Self.legacyTemplatesKey)
        if userDefaults.object(forKey: Self.legacyTemplatesKey) != nil {
            record(.settingWriteFailed(key: Self.legacyTemplatesKey))
        }
    }

    private func persist(_ value: String, forKey key: String) {
        guard let userDefaults else { return }
        userDefaults.set(value, forKey: key)
        if userDefaults.string(forKey: key) != value {
            record(.settingWriteFailed(key: key))
        }
    }

    private func persist(_ value: Bool, forKey key: String) {
        guard let userDefaults else { return }
        userDefaults.set(value, forKey: key)
        if userDefaults.object(forKey: key) == nil
            || userDefaults.bool(forKey: key) != value
        {
            record(.settingWriteFailed(key: key))
        }
    }

    private func record(_ issue: AppSettingsPersistenceIssue) {
        if !persistenceIssues.contains(issue) {
            persistenceIssues.append(issue)
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
