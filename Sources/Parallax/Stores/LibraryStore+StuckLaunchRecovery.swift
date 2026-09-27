import Foundation

struct StuckLaunchRecoveryRequest {
  let identity: ProfileActivityIdentity
  let profileName: String
  let fingerprint: LaunchConfigurationFingerprint
  let records: [StuckLaunchRecord]

  var confirmationTitle: String {
    String(localized: "Clear Stuck Launch Record for \(profileName)?")
  }
}

extension LibraryStore {
  func canRequestStuckLaunchRecovery(for application: ManagedApplication, profile: LaunchProfile) -> Bool {
    guard case .loaded = loadState, settings.canProvideVerifiedSettings,
      !isLibraryOperationInProgress, !isProfileDataOperationRunning
    else { return false }
    return profileActivityRegistry.hasCachedStuckLaunchRecord(identity: ProfileActivityIdentity(
      applicationID: application.id, applicationStorageID: application.storageID,
      profileID: profile.id, profileStorageID: profile.storageID))
  }

  func stuckLaunchRecoveryRequest(
    for application: ManagedApplication,
    profile: LaunchProfile,
    processSnapshotter: any WorkspaceLaunchProcessProvenanceInspecting = WorkspaceProcessSnapshotter()
  ) -> StuckLaunchRecoveryRequest? {
    guard case .loaded = loadState, settings.canProvideVerifiedSettings,
      !isLibraryOperationInProgress, !isProfileDataOperationRunning,
      applications.contains(where: { $0 == application && $0.profiles.contains(profile) })
    else {
      errorMessage = String(localized: "The launch record changed or is no longer eligible to be cleared. Review the space and try again.")
      return nil
    }
    let identity = ProfileActivityIdentity(
      applicationID: application.id, applicationStorageID: application.storageID,
      profileID: profile.id, profileStorageID: profile.storageID)
    do {
      let records = try profileActivityRegistry.stuckLaunchRecords(
        identity: identity,
        expectedApplication: WorkspaceApplicationBundleIdentity(
          bundleURL: URL(fileURLWithPath: application.appPath), bundleIdentifier: application.bundleIdentifier),
        processSnapshotter: processSnapshotter)
      guard !records.isEmpty else { throw StuckLaunchRecoveryError.changedOrActive }
      return StuckLaunchRecoveryRequest(identity: identity, profileName: profile.name,
        fingerprint: recoveryFingerprint(application: application, profile: profile), records: records)
    } catch {
      errorMessage = stuckLaunchRecoveryMessage(for: error)
      return nil
    }
  }

  @discardableResult
  func confirmClearStuckLaunchRecord(
    _ request: StuckLaunchRecoveryRequest,
    processSnapshotter: any WorkspaceLaunchProcessProvenanceInspecting = WorkspaceProcessSnapshotter(),
    reconcileActivity: (() throws -> Void)? = nil
  ) -> Bool {
    guard canMutateLibrary() else { return false }
    libraryOperationStatusMessage = nil
    do {
      guard let application = applications.first(where: {
        $0.id == request.identity.applicationID && $0.storageID == request.identity.applicationStorageID
      }), let profile = application.profiles.first(where: {
        $0.id == request.identity.profileID && $0.storageID == request.identity.profileStorageID
      }), recoveryFingerprint(application: application, profile: profile) == request.fingerprint
      else { throw StuckLaunchRecoveryError.changedOrActive }
      try profileActivityRegistry.clearStuckLaunchRecords(request.records, identity: request.identity,
        expectedApplication: WorkspaceApplicationBundleIdentity(
          bundleURL: URL(fileURLWithPath: application.appPath), bundleIdentifier: application.bundleIdentifier),
        processSnapshotter: processSnapshotter)
      launchPresentationRevision &+= 1
      healthItemsCache.removeAll()
      let didRecheckActivity: Bool
      do {
        if let reconcileActivity {
          try reconcileActivity()
        } else {
          _ = try profileActivityRegistry.reconcileDurableActivity()
        }
        didRecheckActivity = true
      } catch {
        // The confirmed records have already been retired. A failed refresh
        // cannot undo that success or justify retrying the same confirmation.
        didRecheckActivity = false
      }
      if let reason = profileActivityRegistry.cachedLaunchBlocker(identity: request.identity) {
        let blockerDescription: String = reason
        errorMessage = didRecheckActivity
          ? String(localized: "The stuck launch record was cleared, but this space is still blocked: \(blockerDescription)")
          : String(localized: "The stuck launch record was cleared. The remaining state could not be re-checked yet. The last known blocker is: \(blockerDescription)")
        return true
      }
      errorMessage = nil
      libraryOperationStatusMessage = didRecheckActivity
        ? String(localized: "Cleared the stuck launch record. Space data was kept.")
        : String(localized: "The stuck launch record was cleared, but the remaining state could not be re-checked yet. Space data was kept.")
      return true
    } catch {
      errorMessage = stuckLaunchRecoveryMessage(for: error)
      return false
    }
  }

  private func stuckLaunchRecoveryMessage(for error: Error) -> String {
    guard let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty else {
      return StuckLaunchRecoveryError.changedOrActive.localizedDescription
    }
    return description
  }
}
