import Foundation
import Observation

enum AppAppearance: String, CaseIterable, Codable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: String(localized: "Match System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

enum AppSettingsPersistenceIssue:
    LocalizedError,
    Equatable,
    Identifiable,
    Sendable
{
    case corruptProfileTemplates(quarantineKey: String, byteCount: Int)
    case corruptProfileTemplatesQuarantineFailed(byteCount: Int)
    case profileTemplatesEncodingFailed
    case corruptProfileVisualIdentities(
        quarantineKey: String,
        byteCount: Int
    )
    case corruptProfileVisualIdentitiesQuarantineFailed(byteCount: Int)
    case profileVisualIdentitiesEncodingFailed
    case settingWriteFailed(key: String)

    var id: String {
        switch self {
        case let .corruptProfileTemplates(key, _):
            "corrupt-profile-templates:\(key)"
        case .corruptProfileTemplatesQuarantineFailed:
            "corrupt-profile-templates-quarantine-failed"
        case .profileTemplatesEncodingFailed:
            "profile-templates-encoding-failed"
        case let .corruptProfileVisualIdentities(key, _):
            "corrupt-profile-visual-identities:\(key)"
        case .corruptProfileVisualIdentitiesQuarantineFailed:
            "corrupt-profile-visual-identities-quarantine-failed"
        case .profileVisualIdentitiesEncodingFailed:
            "profile-visual-identities-encoding-failed"
        case let .settingWriteFailed(key):
            "setting-write-failed:\(key)"
        }
    }

    var errorDescription: String {
        switch self {
        case .corruptProfileTemplates:
            String(
                localized:
                    "Profile template settings could not be read. The original data was preserved for recovery."
            )
        case .corruptProfileTemplatesQuarantineFailed:
            String(
                localized:
                    "Profile template settings could not be read or copied to recovery storage. The original data was not replaced."
            )
        case .profileTemplatesEncodingFailed:
            String(
                localized:
                    "Profile template settings could not be encoded and were not saved."
            )
        case .corruptProfileVisualIdentities:
            String(
                localized:
                    "Saved profile pictures could not be read. The original data was preserved for recovery."
            )
        case .corruptProfileVisualIdentitiesQuarantineFailed:
            String(
                localized:
                    "Saved profile pictures could not be read or copied to recovery storage. The original data was not replaced."
            )
        case .profileVisualIdentitiesEncodingFailed:
            String(
                localized:
                    "Profile picture settings could not be encoded and were not saved."
            )
        case .settingWriteFailed:
            String(
                localized:
                    "A settings change could not be verified after it was saved."
            )
        }
    }
}

struct ProfileTemplateResetReceipt: Identifiable, Equatable, Sendable {
    let id: UUID
    fileprivate let previousTemplates: [ProfileTemplate]
    fileprivate let resetTemplates: [ProfileTemplate]
}

@Observable
@MainActor
final class AppSettings {
    static let defaultProfileTemplateNames = ProfileTemplate.defaultNames

    var profileTemplates: [ProfileTemplate] {
        didSet {
            if let receipt = pendingProfileTemplateReset,
               receipt.resetTemplates != profileTemplates
            {
                pendingProfileTemplateReset = nil
            }
            persistProfileTemplates()
        }
    }
    var defaultBaseStoragePath: String {
        didSet {
            persist(
                defaultBaseStoragePath,
                forKey: Self.basePathKey
            )
        }
    }
    var confirmBeforeLaunch: Bool {
        didSet {
            persist(
                confirmBeforeLaunch,
                forKey: Self.confirmLaunchKey
            )
        }
    }
    var automaticallyRecoverCrashedApps: Bool {
        didSet {
            persist(
                automaticallyRecoverCrashedApps,
                forKey: Self.automaticCrashRecoveryKey
            )
        }
    }
    var appearance: AppAppearance {
        didSet {
            persist(
                appearance.rawValue,
                forKey: Self.appearanceKey
            )
        }
    }
    private(set) var profileVisualIdentities:
        [String: ProfileInstanceVisualIdentity]
    private(set) var persistenceIssues: [AppSettingsPersistenceIssue]
    private(set) var pendingProfileTemplateReset:
        ProfileTemplateResetReceipt?

    private let userDefaults: UserDefaults
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

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
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

    var profileTemplateNames: [String] {
        profileTemplates.map(\.name)
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
        let key = profileID.uuidString.lowercased()
        guard profileVisualIdentities.removeValue(
            forKey: key
        ) != nil else { return }
        persistProfileVisualIdentities()
    }

    func resetAllProfileVisualIdentities() {
        profileVisualIdentities = [:]
        persistProfileVisualIdentities()
    }

    @discardableResult
    func addProfileTemplate(named name: String) -> ProfileTemplate.ID? {
        guard let normalizedName = DisplayNameValidator.normalized(name) else {
            return nil
        }
        let template = ProfileTemplate(name: normalizedName)
        profileTemplates.append(template)
        return template.id
    }

    @discardableResult
    func replaceProfileTemplate(_ template: ProfileTemplate) -> Bool {
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
              key.hasPrefix(Self.corruptTemplatesKeyPrefix)
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
            ) else { return nil }
            return userDefaults.data(forKey: key)
        case let .corruptProfileVisualIdentities(key, _):
            guard key.hasPrefix(
                Self.corruptProfileVisualIdentitiesKeyPrefix
            ) else { return nil }
            return userDefaults.data(forKey: key)
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
        persistProfileVisualIdentities()
    }

    @discardableResult
    private func persistProfileVisualIdentities() -> Bool {
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
        userDefaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(prefix) }
            .sorted()
            .first { userDefaults.data(forKey: $0) == data }
    }

    private func removeLegacyTemplatesAfterMigration() {
        userDefaults.removeObject(forKey: Self.legacyTemplatesKey)
        if userDefaults.object(forKey: Self.legacyTemplatesKey) != nil {
            record(.settingWriteFailed(key: Self.legacyTemplatesKey))
        }
    }

    private func persist(_ value: String, forKey key: String) {
        userDefaults.set(value, forKey: key)
        if userDefaults.string(forKey: key) != value {
            record(.settingWriteFailed(key: key))
        }
    }

    private func persist(_ value: Bool, forKey key: String) {
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
}
