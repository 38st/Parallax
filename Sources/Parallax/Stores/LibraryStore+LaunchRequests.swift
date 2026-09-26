import AppKit
import Foundation
import Observation

// MARK: - Launch request state

extension LibraryStore {
  func applicationForLaunch(_ profile: LaunchProfile) -> ManagedApplication? {
    if let selectedApplication,
      selectedApplication.profiles.contains(where: { $0.id == profile.id })
    {
      return selectedApplication
    }

    return applications.first { application in
      application.profiles.contains { $0.id == profile.id }
    }
  }

  func submitLaunchConfirmation(
    application: ManagedApplication,
    profile: LaunchProfile,
    source: LaunchConfigurationSource,
    fingerprint: LaunchConfigurationFingerprint
  ) {
    let request = ImmutableLaunchRequest(
      sceneID: sceneID,
      applicationName: application.displayName,
      profileName: profile.name,
      configurationSnapshot: source,
      configurationFingerprint: fingerprint
    )
    switch launchRequests.submit(request, policy: .rejectNew) {
    case .awaitingConfirmation:
      isShowingLaunchConfirmation = true
    case .queued:
      isShowingLaunchConfirmation = true
    case .rejected(_, let reason):
      errorMessage = reason.message
    }
  }

  func currentLaunchTarget(
    for request: ImmutableLaunchRequest
  ) -> LaunchRequestCurrentTarget {
    guard
      let application = applications.first(where: {
        $0.id == request.applicationID
      })
    else {
      return .applicationRemoved
    }
    guard
      let profile = application.profiles.first(where: {
        $0.id == request.profileID
      })
    else {
      return .profileRemoved
    }
    let current = launchConfigurationSource(
      application: application,
      profile: profile,
      requestID: request.requestID
    )
    // Bookkeeping commits advance the library revision without changing any
    // launch input. Compare all current inputs using the captured revision.
    let source = LaunchConfigurationSource(
      requestID: current.requestID,
      applicationID: current.applicationID,
      applicationStorageID: current.applicationStorageID,
      profileID: current.profileID,
      profileStorageID: current.profileStorageID,
      configurationRevision: request.configurationRevision,
      applicationURL: current.applicationURL,
      expectedBundleIdentifier: current.expectedBundleIdentifier,
      configuredBaseRoot: current.configuredBaseRoot,
      argumentsText: current.argumentsText,
      environmentText: current.environmentText,
      isolationOwnership: current.isolationOwnership,
      childEnvironmentPolicy: current.childEnvironmentPolicy,
      sensitiveEnvironmentKeys: current.sensitiveEnvironmentKeys,
      peerProfiles: current.peerProfiles
    )
    return .available(
      applicationID: application.id,
      profileID: profile.id,
      configurationRevision: source.configurationRevision,
      configurationFingerprint:
        LaunchConfigurationCompiler
        .configurationFingerprint(for: source)
    )
  }
}
