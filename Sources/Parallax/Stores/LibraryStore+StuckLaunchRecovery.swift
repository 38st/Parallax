import Foundation

struct StuckLaunchRecoveryRequest {
  let identity: ProfileActivityIdentity
  let fingerprint: LaunchConfigurationFingerprint
  let records: [StuckLaunchRecord]
}

extension LibraryStore {
  func stuckLaunchRecoveryRequest(
    for application: ManagedApplication,
    profile: LaunchProfile,
    processSnapshotter: any WorkspaceLaunchProcessProvenanceInspecting = WorkspaceProcessSnapshotter()
  ) -> StuckLaunchRecoveryRequest? {
    guard case .loaded = loadState, settings.canProvideVerifiedSettings,
      !isLibraryOperationInProgress, !isProfileDataOperationRunning,
      applications.contains(where: { $0 == application && $0.profiles.contains(profile) })
    else { return nil }
    let identity = ProfileActivityIdentity(
      applicationID: application.id, applicationStorageID: application.storageID,
      profileID: profile.id, profileStorageID: profile.storageID)
    guard let records = try? profileActivityRegistry.stuckLaunchRecords(
      identity: identity,
      expectedApplication: WorkspaceApplicationBundleIdentity(
        bundleURL: URL(fileURLWithPath: application.appPath), bundleIdentifier: application.bundleIdentifier),
      processSnapshotter: processSnapshotter), !records.isEmpty
    else { return nil }
    return StuckLaunchRecoveryRequest(identity: identity,
      fingerprint: recoveryFingerprint(application: application, profile: profile), records: records)
  }

  @discardableResult
  func confirmClearStuckLaunchRecord(
    _ request: StuckLaunchRecoveryRequest,
    processSnapshotter: any WorkspaceLaunchProcessProvenanceInspecting = WorkspaceProcessSnapshotter()
  ) -> Bool {
    guard canMutateLibrary() else { return false }
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
      errorMessage = nil
      libraryOperationStatusMessage = String(localized: "Cleared the stuck launch record. Space data was kept.")
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
