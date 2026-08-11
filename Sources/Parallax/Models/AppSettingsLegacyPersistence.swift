import Foundation

struct AppSettingsLegacyLoadResult {
    let profileTemplates: [ProfileTemplate]
    let profileVisualIdentities: [String: ProfileInstanceVisualIdentity]
    let defaultBaseStoragePath: String
    let confirmBeforeLaunch: Bool
    let automaticallyRecoverCrashedApps: Bool
    let appearance: AppAppearance
    let persistenceIssues: [AppSettingsPersistenceIssue]
}

/// Isolates the synchronous `UserDefaults` behavior retained for source and
/// characterization-test compatibility. Production settings never construct
/// this adapter and instead persist through `SettingsMutationCoordinator`.
final class AppSettingsLegacyPersistence {
    private enum ProfileTemplateLoad {
        case stored([ProfileTemplate])
        case legacy([ProfileTemplate])
        case corrupt(Data)
        case defaults
    }

    private struct WriteResult {
        let succeeded: Bool
        let issues: [AppSettingsPersistenceIssue]
    }

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

    private let userDefaults: UserDefaults
    private var unquarantinedCorruptTemplateData: Data?
    private var unquarantinedCorruptProfileVisualIdentityData: Data?

    init(userDefaults: UserDefaults) {
        self.userDefaults = userDefaults
    }

    func load() -> AppSettingsLegacyLoadResult {
        let templateLoad = loadProfileTemplates()
        let profileTemplates: [ProfileTemplate]
        switch templateLoad {
        case .stored(let templates), .legacy(let templates):
            profileTemplates = templates
        case .corrupt(let data):
            profileTemplates = ProfileTemplate.defaults
            unquarantinedCorruptTemplateData = data
        case .defaults:
            profileTemplates = ProfileTemplate.defaults
        }

        let profileVisualIdentities: [String: ProfileInstanceVisualIdentity]
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
                unquarantinedCorruptProfileVisualIdentityData = data
            }
        } else {
            profileVisualIdentities = [:]
        }

        // Preserve the legacy facade's single read checkpoint: capture every
        // field before migration or quarantine can write to UserDefaults.
        let defaultBaseStoragePath = userDefaults.string(
            forKey: Self.basePathKey
        ) ?? ""
        let confirmBeforeLaunch = userDefaults.bool(
            forKey: Self.confirmLaunchKey
        )
        let automaticallyRecoverCrashedApps = userDefaults.object(
            forKey: Self.automaticCrashRecoveryKey
        ) == nil
            ? true
            : userDefaults.bool(
                forKey: Self.automaticCrashRecoveryKey
            )
        let appearance = AppAppearance(
            rawValue: userDefaults.string(forKey: Self.appearanceKey) ?? ""
        ) ?? .system

        var issues: [AppSettingsPersistenceIssue] = []
        switch templateLoad {
        case .corrupt(let data):
            appendUnique(
                quarantineCorruptProfileTemplates(data),
                to: &issues
            )
        case .legacy:
            let write = persistProfileTemplatesResult(profileTemplates)
            appendUnique(write.issues, to: &issues)
            if write.succeeded {
                appendUnique(
                    removeLegacyTemplatesAfterMigration(),
                    to: &issues
                )
            }
        case .stored, .defaults:
            break
        }

        if let corruptData = unquarantinedCorruptProfileVisualIdentityData {
            appendUnique(
                quarantineCorruptProfileVisualIdentities(corruptData),
                to: &issues
            )
        }

        return AppSettingsLegacyLoadResult(
            profileTemplates: profileTemplates,
            profileVisualIdentities: profileVisualIdentities,
            defaultBaseStoragePath: defaultBaseStoragePath,
            confirmBeforeLaunch: confirmBeforeLaunch,
            automaticallyRecoverCrashedApps:
                automaticallyRecoverCrashedApps,
            appearance: appearance,
            persistenceIssues: issues
        )
    }

    func persistProfileTemplates(
        _ profileTemplates: [ProfileTemplate]
    ) -> [AppSettingsPersistenceIssue] {
        persistProfileTemplatesResult(profileTemplates).issues
    }

    func persistProfileVisualIdentities(
        _ profileVisualIdentities: [String: ProfileInstanceVisualIdentity]
    ) -> [AppSettingsPersistenceIssue] {
        var issues: [AppSettingsPersistenceIssue] = []
        if let corruptData = unquarantinedCorruptProfileVisualIdentityData {
            appendUnique(
                quarantineCorruptProfileVisualIdentities(corruptData),
                to: &issues
            )
            guard unquarantinedCorruptProfileVisualIdentityData == nil else {
                return issues
            }
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(profileVisualIdentities)
        } catch {
            appendUnique(
                [.profileVisualIdentitiesEncodingFailed],
                to: &issues
            )
            return issues
        }

        userDefaults.set(data, forKey: Self.profileVisualIdentitiesKey)
        guard userDefaults.data(forKey: Self.profileVisualIdentitiesKey) == data
        else {
            appendUnique(
                [.settingWriteFailed(key: Self.profileVisualIdentitiesKey)],
                to: &issues
            )
            return issues
        }
        return issues
    }

    func persistDefaultBaseStoragePath(
        _ value: String
    ) -> [AppSettingsPersistenceIssue] {
        persist(value, forKey: Self.basePathKey)
    }

    func persistConfirmBeforeLaunch(
        _ value: Bool
    ) -> [AppSettingsPersistenceIssue] {
        persist(value, forKey: Self.confirmLaunchKey)
    }

    func persistAutomaticallyRecoverCrashedApps(
        _ value: Bool
    ) -> [AppSettingsPersistenceIssue] {
        persist(value, forKey: Self.automaticCrashRecoveryKey)
    }

    func persistAppearance(
        _ value: AppAppearance
    ) -> [AppSettingsPersistenceIssue] {
        persist(value.rawValue, forKey: Self.appearanceKey)
    }

    func quarantinedData(for issue: AppSettingsPersistenceIssue) -> Data? {
        switch issue {
        case .corruptProfileTemplates(let key, _):
            guard key.hasPrefix(Self.corruptTemplatesKeyPrefix) else {
                return nil
            }
            return userDefaults.data(forKey: key)
        case .corruptProfileVisualIdentities(let key, _):
            guard key.hasPrefix(
                Self.corruptProfileVisualIdentitiesKeyPrefix
            ) else {
                return nil
            }
            return userDefaults.data(forKey: key)
        default:
            return nil
        }
    }

    private func loadProfileTemplates() -> ProfileTemplateLoad {
        if let data = userDefaults.data(forKey: Self.templatesKey) {
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

        if let legacyNames = userDefaults.array(
            forKey: Self.legacyTemplatesKey
        ) as? [String], !legacyNames.isEmpty {
            return .legacy(
                legacyNames.map { ProfileTemplate(name: $0) }
            )
        }

        return .defaults
    }

    private func persistProfileTemplatesResult(
        _ profileTemplates: [ProfileTemplate]
    ) -> WriteResult {
        var issues: [AppSettingsPersistenceIssue] = []
        if let corruptData = unquarantinedCorruptTemplateData {
            appendUnique(
                quarantineCorruptProfileTemplates(corruptData),
                to: &issues
            )
            guard unquarantinedCorruptTemplateData == nil else {
                return WriteResult(succeeded: false, issues: issues)
            }
        }

        let data: Data
        do {
            data = try JSONEncoder().encode(profileTemplates)
        } catch {
            appendUnique([.profileTemplatesEncodingFailed], to: &issues)
            return WriteResult(succeeded: false, issues: issues)
        }

        userDefaults.set(data, forKey: Self.templatesKey)
        guard userDefaults.data(forKey: Self.templatesKey) == data else {
            appendUnique(
                [.settingWriteFailed(key: Self.templatesKey)],
                to: &issues
            )
            return WriteResult(succeeded: false, issues: issues)
        }
        return WriteResult(succeeded: true, issues: issues)
    }

    private func quarantineCorruptProfileTemplates(
        _ data: Data
    ) -> [AppSettingsPersistenceIssue] {
        if let existingKey = matchingQuarantineKey(
            for: data,
            prefix: Self.corruptTemplatesKeyPrefix
        ) {
            unquarantinedCorruptTemplateData = nil
            return [
                .corruptProfileTemplates(
                    quarantineKey: existingKey,
                    byteCount: data.count
                )
            ]
        }

        let quarantineKey = Self.corruptTemplatesKeyPrefix
            + UUID().uuidString.lowercased()
        userDefaults.set(data, forKey: quarantineKey)
        guard userDefaults.data(forKey: quarantineKey) == data else {
            return [
                .corruptProfileTemplatesQuarantineFailed(
                    byteCount: data.count
                )
            ]
        }

        unquarantinedCorruptTemplateData = nil
        return [
            .corruptProfileTemplates(
                quarantineKey: quarantineKey,
                byteCount: data.count
            )
        ]
    }

    private func quarantineCorruptProfileVisualIdentities(
        _ data: Data
    ) -> [AppSettingsPersistenceIssue] {
        if let existingKey = matchingQuarantineKey(
            for: data,
            prefix: Self.corruptProfileVisualIdentitiesKeyPrefix
        ) {
            unquarantinedCorruptProfileVisualIdentityData = nil
            return [
                .corruptProfileVisualIdentities(
                    quarantineKey: existingKey,
                    byteCount: data.count
                )
            ]
        }

        let quarantineKey = Self.corruptProfileVisualIdentitiesKeyPrefix
            + UUID().uuidString.lowercased()
        userDefaults.set(data, forKey: quarantineKey)
        guard userDefaults.data(forKey: quarantineKey) == data else {
            return [
                .corruptProfileVisualIdentitiesQuarantineFailed(
                    byteCount: data.count
                )
            ]
        }

        unquarantinedCorruptProfileVisualIdentityData = nil
        return [
            .corruptProfileVisualIdentities(
                quarantineKey: quarantineKey,
                byteCount: data.count
            )
        ]
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

    private func removeLegacyTemplatesAfterMigration()
        -> [AppSettingsPersistenceIssue]
    {
        userDefaults.removeObject(forKey: Self.legacyTemplatesKey)
        guard userDefaults.object(forKey: Self.legacyTemplatesKey) == nil else {
            return [.settingWriteFailed(key: Self.legacyTemplatesKey)]
        }
        return []
    }

    private func persist(
        _ value: String,
        forKey key: String
    ) -> [AppSettingsPersistenceIssue] {
        userDefaults.set(value, forKey: key)
        guard userDefaults.string(forKey: key) == value else {
            return [.settingWriteFailed(key: key)]
        }
        return []
    }

    private func persist(
        _ value: Bool,
        forKey key: String
    ) -> [AppSettingsPersistenceIssue] {
        userDefaults.set(value, forKey: key)
        guard userDefaults.object(forKey: key) != nil,
              userDefaults.bool(forKey: key) == value
        else {
            return [.settingWriteFailed(key: key)]
        }
        return []
    }

    private func appendUnique(
        _ newIssues: [AppSettingsPersistenceIssue],
        to issues: inout [AppSettingsPersistenceIssue]
    ) {
        for issue in newIssues where !issues.contains(issue) {
            issues.append(issue)
        }
    }
}
