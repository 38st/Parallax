import Foundation

private enum ExactProcessControlAuthority {
  case supervised(TrackedApplicationLaunch)
  case recoveredDurableLaunch
}

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
    let recoveredProcesses =
      profileActivityRegistry.runningProcesses(
        applicationStorageID: application.storageID
      )
    return applicationInstanceController.instances(
      for: application,
      trackedProcesses: recoveredProcesses
    ).map { instance in
      guard instance.hasTrackedAttribution else {
        return instance.presenting(.outsideParallax)
      }
      guard
        exactProcessControlAuthority(
          for: instance,
          application: application,
          recoveredProcesses: recoveredProcesses
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
    let authority = exactProcessControlAuthority(
      for: instance,
      application: application
    )
    do {
      guard instance.isActionable, let authority else {
        throw ApplicationInstanceControllerError.unmanagedInstance(
          instance.processIdentifier
        )
      }
      let request = {
        try self.applicationInstanceController.requestQuit(
          instance,
          from: application
        )
      }
      switch authority {
      case .supervised(let trackedLaunch):
        try trackedLaunch.performTerminationRequest(request)
      case .recoveredDurableLaunch:
        try request()
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

  private func exactProcessControlAuthority(
    for instance: ManagedApplicationInstance,
    application: ManagedApplication,
    recoveredProcesses: [ProfileRunningProcess]? = nil
  ) -> ExactProcessControlAuthority? {
    guard
      let requestID = instance.requestID,
      let profileID = instance.profileID,
      let profileStorageID = instance.profileStorageID,
      let profile = application.profiles.first(where: {
        $0.id == profileID && $0.storageID == profileStorageID
      })
    else {
      return nil
    }

    if activeTrackedLaunches[requestID] != nil {
      guard let trackedLaunch = exactRunningTrackedLaunch(
        for: instance,
        application: application
      ) else {
        return nil
      }
      return .supervised(trackedLaunch)
    }

    let candidates = recoveredProcesses
      ?? profileActivityRegistry.runningProcesses(
        applicationStorageID: application.storageID
      )
    let expectedIdentity = ProfileActivityIdentity(
      applicationID: application.id,
      applicationStorageID: application.storageID,
      profileID: profile.id,
      profileStorageID: profile.storageID
    )
    guard candidates.contains(where: {
      $0.requestID == requestID
        && $0.identity == expectedIdentity
        && $0.process == instance.process
    }) else {
      return nil
    }
    return .recoveredDurableLaunch
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
        instance.isActionable,
        exactProcessControlAuthority(
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
