import Foundation

extension LibraryStore {
    /// Opens the existing native space so its live account can be checked even
    /// when its history binding is stale. No handoff, capture, or import runs.
    func openConversationAccountForReview(application: ManagedApplication, profile: LaunchProfile) async {
        guard requireCommittedProfileDraft(application: application, profile: profile) else { return }
        var source = launchConfigurationSource(application: application, profile: profile, requestID: UUID())
        source.reviewsConversationAccount = true
        do {
            try await validateConversationAccountReview(source)
            errorMessage = nil
            if settings.confirmBeforeLaunch {
                submitLaunchConfirmation(application: application, profile: profile, source: source,
                    fingerprint: LaunchConfigurationCompiler.configurationFingerprint(for: source))
            } else {
                performLaunch(application: application, profile: profile, preparedSource: source)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    func validateConversationAccountReview(_ source: LaunchConfigurationSource) async throws {
        guard source.reviewsConversationAccount, canUseSettingsAuthority(), !isProfileDataOperationRunning,
              let application = applications.first(where: { $0.id == source.applicationID }),
              Self.resolvedPreset(for: application) == .claude,
              let profile = application.profiles.first(where: { $0.id == source.profileID }),
              launchInputsMatch(source, application: application, profile: profile),
              requireCommittedProfileDraft(application: application, profile: profile),
              canLaunchDuringRecovery(identity: ProfileActivityIdentity(applicationID: application.id,
                applicationStorageID: application.storageID, profileID: profile.id, profileStorageID: profile.storageID),
                profileName: profile.name) else { throw ConversationLibraryError.changed }
        guard !sharedHistoryApplicationIsRunning(application) else { throw ConversationLibraryError.waitingForQuit }
        guard try conversationLibrary(application: application, profile: profile)?.handoff == nil else {
            throw ConversationLibraryError.busy
        }
        if profile.launchConfigurationTrust.isImported {
            let analysis = await launchConfigurationCompiler.analyze(source)
            let trustSource = importedLaunchTrustSource(application: application, profile: profile,
                analysis: analysis, source: source)
            switch importedLaunchTrust.assessment(for: profile, source: trustSource) {
            case .trustedLocal, .approved: break
            case .reviewRequired: throw ImportedLaunchTrustError.configurationChangedAfterReview
            }
            guard applications.contains(application), !sharedHistoryApplicationIsRunning(application) else {
                throw ConversationLibraryError.changed
            }
        }
    }
}
