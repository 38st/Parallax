import Foundation
import Observation

extension AppSettings {
    @discardableResult
    func exportPreservedSettings(
        for issue: AppSettingsPersistenceIssue,
        to url: URL
    ) throws -> Bool {
        guard let data = quarantinedSettingsData(for: issue) else { return false }
        try data.write(to: url, options: .atomic)
        dismissPersistenceIssue(id: issue.id)
        return true
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
