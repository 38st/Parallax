import AppKit
import Foundation
import Observation

extension LibraryStore {
    var libraryImportFlowPhase: LibraryImportFlowPhase {
        switch libraryImportFlowState {
        case .idle:
            .idle
        case .choosing:
            .choosing
        case .resolving:
            .resolving
        }
    }
    var isShowingImportChoice: Bool {
        libraryImportFlowPhase == .choosing
    }
    var isShowingImportConflictResolution: Bool {
        libraryImportFlowPhase == .resolving
    }
    var pendingImportSummary: LibraryImportSummary? {
        libraryImportFlowState.preparedImport?.summary
    }
    var pendingImportConflict: LibraryImportConflict? {
        guard case .resolving(let session) = libraryImportFlowState else {
            return nil
        }
        return session.conflict
    }
    var pendingLibraryImport: PreparedLibraryImport? {
        libraryImportFlowState.preparedImport
    }
    var pendingImportResolutions:
        [LibraryImportConflictID: LibraryImportConflictResolution]
    {
        guard case .resolving(let session) = libraryImportFlowState else {
            return [:]
        }
        return session.resolutions
    }
    var pendingDestructiveActionPresentation:
        DestructiveActionConfirmationPresentation?
    {
        pendingDestructiveActionRequest?.confirmationPresentation
    }

    var destructiveExpertOverrideWarning: String {
        DestructiveActionExpertRiskAcknowledgment
            .profileDataCorruptionAndProcessInstability
            .warningMessage
    }

    var pendingLaunchDiagnosticMessage: String? {
        pendingLaunchDiagnosticRequest?.diagnostics
            .map(\.message)
            .joined(separator: "\n")
    }

    var pendingLaunchProfileName: String? {
        launchRequests.pendingConfirmation(in: sceneID)?.profileName
    }

    var pendingLaunchApplicationName: String? {
        launchRequests.pendingConfirmation(in: sceneID)?
            .applicationName
    }

    var pendingApplicationRelinkMessage: String? {
        guard let proposal = pendingApplicationRelink?.proposal else {
            return nil
        }
        return String(
            localized:
                "Update \(proposal.originalApplication.displayName) from \(proposal.originalApplication.appPath) to \(proposal.canonicalCandidateURL.path)? All profiles and managed storage identities will be preserved."
        )
    }

    var pendingApplicationRemovalPresentation:
        ApplicationRemovalConfirmationPresentation?
    {
        pendingApplicationRemoval?.confirmationPresentation
    }

}
