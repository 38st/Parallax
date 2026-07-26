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
    case settingWriteFailed(key: String)

    var id: String {
        switch self {
        case let .corruptProfileTemplates(key, _):
            "corrupt-profile-templates:\(key)"
        case .corruptProfileTemplatesQuarantineFailed:
            "corrupt-profile-templates-quarantine-failed"
        case .profileTemplatesEncodingFailed:
            "profile-templates-encoding-failed"
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
        case .settingWriteFailed:
            String(
                localized:
                    "A settings change could not be verified after it was saved."
            )
        }
    }
}

@Observable
@MainActor
final class AppSettings {
    static let defaultProfileTemplateNames = ProfileTemplate.defaultNames

    var profileTemplates: [ProfileTemplate] {
        didSet { persistProfileTemplates() }
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
    var appearance: AppAppearance {
        didSet {
            persist(
                appearance.rawValue,
                forKey: Self.appearanceKey
            )
        }
    }
    private(set) var persistenceIssues: [AppSettingsPersistenceIssue]

    private let userDefaults: UserDefaults
    private var unquarantinedCorruptTemplateData: Data?
    private static let templatesKey = "settings.profileTemplates"
    private static let legacyTemplatesKey = "settings.profileTemplateNames"
    private static let corruptTemplatesKeyPrefix =
        "settings.profileTemplates.corrupt."
    private static let basePathKey = "settings.defaultBaseStoragePath"
    private static let confirmLaunchKey = "settings.confirmBeforeLaunch"
    private static let appearanceKey = "settings.appearance"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        persistenceIssues = []
        unquarantinedCorruptTemplateData = nil

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
        self.defaultBaseStoragePath = userDefaults.string(forKey: Self.basePathKey) ?? ""
        self.confirmBeforeLaunch = userDefaults.bool(forKey: Self.confirmLaunchKey)
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
    }

    var profileTemplateNames: [String] {
        profileTemplates.map(\.name)
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

    private func matchingQuarantineKey(for data: Data) -> String? {
        userDefaults.dictionaryRepresentation().keys
            .filter { $0.hasPrefix(Self.corruptTemplatesKeyPrefix) }
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
