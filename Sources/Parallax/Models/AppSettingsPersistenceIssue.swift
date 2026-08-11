import Foundation

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
    case versionedBootstrapRecovery(SettingsRuntimeBootstrapRecovery)
    case versionedMutationRecovery(SettingsRuntimeMutationFailure)

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
        case .versionedBootstrapRecovery:
            "versioned-settings-bootstrap-recovery"
        case .versionedMutationRecovery:
            "versioned-settings-mutation-recovery"
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
        case .versionedBootstrapRecovery:
            String(
                localized:
                    "Settings require recovery. Existing versioned and legacy data was preserved, and settings changes are disabled."
            )
        case .versionedMutationRecovery:
            String(
                localized:
                    "A settings change could not be safely committed. The last verified settings remain in use and further settings changes are disabled."
            )
        }
    }
}
