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
    case invalidSetting(SettingsDocumentCodecIssue)
    case versionedBootstrapRecovery(SettingsRuntimeBootstrapRecovery)
    case versionedMutationRecovery(SettingsRuntimeMutationFailure)
    case legacyFieldDefaulted(SettingsLegacyJSONPayload, originalBytes: Data)
    case committedSettingsCleanupFailed(SettingsRepositoryMutationEvidence)

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
        case .invalidSetting:
            "invalid-settings-edit"
        case let .settingWriteFailed(key):
            "setting-write-failed:\(key)"
        case .legacyFieldDefaulted(let payload, _):
            "legacy-settings-defaulted:\(payload)"
        case .committedSettingsCleanupFailed:
            "committed-settings-cleanup-failed"
        case .versionedBootstrapRecovery:
            "versioned-settings-bootstrap-recovery"
        case .versionedMutationRecovery:
            "versioned-settings-mutation-recovery"
        }
    }

    var presentationTitle: String {
        if case .invalidSetting = self { return String(localized: "Settings Change Not Saved") }
        return String(localized: "Settings Recovery Available")
    }

    var errorDescription: String? {
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
        case .invalidSetting(let issue):
            Self.invalidEditDescription(issue)
        case .settingWriteFailed:
            String(
                localized:
                    "A settings change could not be verified after it was saved."
            )
        case .legacyFieldDefaulted(.profileTemplates, _):
            String(localized: "Unreadable legacy templates were replaced with default templates in the new settings file. The original legacy data remains unchanged and can be exported.")
        case .legacyFieldDefaulted(.profileVisualIdentities, _):
            String(localized: "Unreadable legacy profile pictures were replaced with automatic pictures in the new settings file. The original legacy data remains unchanged and can be exported.")
        case .committedSettingsCleanupFailed:
            String(localized: "Your settings were saved and verified, but closing the settings storage reported an error. The saved values remain in use and you can continue changing settings.")
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

    private static func invalidEditDescription(_ issue: SettingsDocumentCodecIssue) -> String {
        if case .stringTooLong(let path, let maximum) = issue {
            let field: String
            if path == "$.defaultBaseStoragePath" {
                field = String(localized: "Default base storage path")
            } else if path.hasSuffix(".notes") {
                field = String(localized: "Default Notes")
            } else if path.hasSuffix(".argumentsText") {
                field = String(localized: "Default Arguments")
            } else if path.hasSuffix(".environmentText") {
                field = String(localized: "Default Environment")
            } else {
                field = String(localized: "Template name")
            }
            let maximumBytes: Int = maximum
            return String(localized: "The change to \(field) was not saved because it exceeds \(maximumBytes) UTF-8 bytes. The previous value was restored; other settings can still be changed.")
        }
        return String(localized: "This settings change exceeds the supported format or size limits. The previous value was restored; other settings can still be changed.")
    }

}
