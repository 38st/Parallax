import Foundation

struct ApplicationRemovalRequestError: LocalizedError {
    enum Code: String, Equatable, Sendable {
        case invalidRequest
        case targetRemoved
        case targetRetargeted
        case applicationChanged
        case profileTargetsChanged
        case staleRepositoryVersion
        case activitySnapshotMismatch
        case activeProfileData
        case invalidExpertOverride
        case priorBackupRequired
        case invalidPriorBackup
        case dataPhaseResultMismatch
        case managedDataActionFailed
    }

    let code: Code

    init(_ code: Code) {
        self.code = code
    }

    var errorDescription: String? {
        switch code {
        case .invalidRequest:
            String(
                localized:
                    "The application removal request contains duplicate or ambiguous profile identities."
            )
        case .targetRemoved:
            String(
                localized:
                    "The application no longer exists. Removal was cancelled."
            )
        case .targetRetargeted:
            String(
                localized:
                    "The application removal target changed after confirmation was presented."
            )
        case .applicationChanged:
            String(
                localized:
                    "The application changed after confirmation was presented."
            )
        case .profileTargetsChanged:
            String(
                localized:
                    "The application’s profiles or storage targets changed after confirmation was presented."
            )
        case .staleRepositoryVersion:
            String(
                localized:
                    "The library changed after application removal was confirmed. Review the removal again."
            )
        case .activitySnapshotMismatch:
            String(
                localized:
                    "Profile activity was not checked for every exact application removal target."
            )
        case .activeProfileData:
            String(
                localized:
                    "One or more profiles may still be active. Application removal stopped to protect their data."
            )
        case .invalidExpertOverride:
            String(
                localized:
                    "The expert override does not authorize this exact application removal request."
            )
        case .priorBackupRequired:
            String(
                localized:
                    "A verified backup of the current library is required before application removal."
            )
        case .invalidPriorBackup:
            String(
                localized:
                    "The selected backup does not preserve the exact library version being removed."
            )
        case .dataPhaseResultMismatch:
            String(
                localized:
                    "The managed-data result belongs to a different application removal request."
            )
        case .managedDataActionFailed:
            String(
                localized:
                    "Managed profile data could not be handled. The application record must remain unchanged."
            )
        }
    }
}
