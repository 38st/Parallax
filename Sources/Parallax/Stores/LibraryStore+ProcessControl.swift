import Foundation

// MARK: - Exact process control

extension LibraryStore {
  @discardableResult
  func reopen(
    _ entry: LaunchHistoryEntry,
    from application: ManagedApplication
  ) -> Bool {
    guard
      entry.applicationID == application.id,
      entry.applicationStorageID == application.storageID,
      let profile = application.profiles.first(where: {
        $0.id == entry.profileID
          && $0.storageID == entry.profileStorageID
      })
    else {
      errorMessage = String(
        localized:
          "This space is no longer available in \(application.displayName)."
      )
      return false
    }
    launch(profile)
    return true
  }

  func runningApplicationInstances(
    for application: ManagedApplication
  ) -> [ManagedApplicationInstance] {
    _ = launchPresentationRevision
    return applicationInstanceController.instances(
      for: application,
      trackedProcesses:
        profileActivityRegistry.runningProcesses(
          applicationStorageID: application.storageID
        )
    ).map { instance in
      guard instance.hasTrackedAttribution else {
        return instance.presenting(.outsideParallax)
      }
      guard
        exactRunningTrackedLaunch(
          for: instance,
          application: application
        ) != nil
      else {
        return instance.presenting(.verificationUnavailable)
      }
      return instance.presenting(.verifiedParallaxInstance)
    }
  }

  @discardableResult
  func requestQuit(
    _ instance: ManagedApplicationInstance,
    from application: ManagedApplication
  ) -> Bool {
    let trackedLaunch = authoritativeTrackedLaunch(
      for: instance,
      application: application
    )
    do {
      guard let trackedLaunch else {
        throw ApplicationInstanceControllerError.unmanagedInstance(
          instance.processIdentifier
        )
      }
      try trackedLaunch.performTerminationRequest {
        try applicationInstanceController.requestQuit(
          instance,
          from: application
        )
      }
      libraryOperationStatusMessage = String(
        localized:
          "Asked \(instance.displayName) to quit."
      )
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func authoritativeTrackedLaunch(
    for instance: ManagedApplicationInstance,
    application: ManagedApplication
  ) -> TrackedApplicationLaunch? {
    guard instance.isActionable else { return nil }
    return exactRunningTrackedLaunch(
      for: instance,
      application: application
    )
  }

  private func exactRunningTrackedLaunch(
    for instance: ManagedApplicationInstance,
    application: ManagedApplication
  ) -> TrackedApplicationLaunch? {
    guard
      instance.hasTrackedAttribution,
      let requestID = instance.requestID,
      let profileID = instance.profileID,
      let profileStorageID = instance.profileStorageID,
      let launch = activeTrackedLaunches[requestID],
      let profile = application.profiles.first(where: {
        $0.id == profileID && $0.storageID == profileStorageID
      })
    else {
      return nil
    }
    let lifecycle = launch.currentLifecycle
    let expectedActivity = ProfileActivityIdentity(
      applicationID: application.id,
      applicationStorageID: application.storageID,
      profileID: profile.id,
      profileStorageID: profile.storageID
    )
    guard
      lifecycle.requestID == requestID,
      lifecycle.identity == expectedActivity,
      lifecycle.processIdentity == instance.processIdentity,
      launch.isSupervising(instance.processIdentity)
    else {
      return nil
    }
    switch lifecycle.state {
    case .running(let processIdentifier),
      .runningDegraded(let processIdentifier, _):
      return processIdentifier == instance.processIdentifier
        ? launch
        : nil
    case .requested, .launching, .terminating, .terminated, .failed:
      return nil
    }
  }

  @discardableResult
  func requestActivate(
    _ instance: ManagedApplicationInstance,
    from application: ManagedApplication
  ) -> Bool {
    do {
      guard
        authoritativeTrackedLaunch(
          for: instance,
          application: application
        ) != nil
      else {
        throw ApplicationInstanceControllerError.unmanagedInstance(
          instance.processIdentifier
        )
      }
      try applicationInstanceController.requestActivate(
        instance,
        from: application
      )
      errorMessage = nil
      libraryOperationStatusMessage = String(
        localized:
          "Brought \(instance.displayName) forward."
      )
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
