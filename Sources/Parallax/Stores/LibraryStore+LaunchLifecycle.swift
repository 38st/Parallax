import AppKit
import Foundation
import Observation

// MARK: - Scheduled launch lifecycle

extension LibraryStore {
  func schedulePreparedLaunch(
    _ source: LaunchConfigurationSource,
    profileName: String,
    override: LaunchDiagnosticOverride?,
    concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy
  ) {
    guard canUseSettingsAuthority(), canLaunchDuringRecovery(
      identity: ProfileActivityIdentity(applicationID: source.applicationID, applicationStorageID: source.applicationStorageID,
        profileID: source.profileID, profileStorageID: source.profileStorageID), profileName: profileName) else {
      releaseWaitingConversationSwitch(source)
      _ = updateLaunchRequestStatus(requestID: source.requestID, state: .cancelled)
      return
    }
    let compiler = launchConfigurationCompiler
    launchPreparationTasks[source.requestID]?.cancel()
    launchPreparationTasks[source.requestID] = Task { [weak self] in
      // An override prompt keeps the waiting handoff for its retry. Every
      // other early exit releases it; an opened launch has moved past waiting.
      var retainsWaitingHandoff = false
      defer {
        if !retainsWaitingHandoff { self?.releaseWaitingConversationSwitch(source) }
      }
      do {
        try await self?.includeAllAccountHistoryForLaunch(source)
        try await self?.beginConversationSwitch(source)
        var prepared = try await compiler.prepare(
          source,
          override: override
        )
        try Task.checkCancellation()
        guard let self else { return }
        try await self.prepareSharedHistoryForLaunch(source)
        prepared.continuationURL = try self.conversationContinuationURL(source)
        try self.openPreparedLaunch(
          prepared,
          profileName: profileName,
          concurrentLaunchPolicy:
            concurrentLaunchPolicy
        )
      } catch is CancellationError {
        _ = self?.updateLaunchRequestStatus(
          requestID: source.requestID,
          state: .cancelled
        )
      } catch let LaunchPreparationError.blocked(diagnostics)
        where override == nil
        && diagnostics.allSatisfy({
          $0.code == .profileHealth(.profileActive)
        })
      {
        let analysis = await compiler.analyze(source)
        guard !Task.isCancelled, let self, self.canUseSettingsAuthority() else {
          _ = self?.updateLaunchRequestStatus(requestID: source.requestID, state: .cancelled)
          return
        }
        self.cancelLaunchDiagnosticOverride()
        self.cancelConcurrentLaunchOverride()
        self.pendingConcurrentLaunchRequest =
          PendingConcurrentLaunchRequest(
            source: source,
            profileName: profileName,
            fingerprint:
              analysis.configurationFingerprint
          )
        self.isShowingConcurrentLaunchOverride = true
        retainsWaitingHandoff = true
      } catch let LaunchPreparationError.blocked(diagnostics)
        where override == nil
        && diagnostics.allSatisfy(\.isOverridable)
      {
        let analysis = await compiler.analyze(source)
        guard !Task.isCancelled, let self, self.canUseSettingsAuthority() else {
          _ = self?.updateLaunchRequestStatus(requestID: source.requestID, state: .cancelled)
          return
        }
        self.cancelLaunchDiagnosticOverride()
        self.cancelConcurrentLaunchOverride()
        self.pendingLaunchDiagnosticRequest =
          PendingLaunchDiagnosticRequest(
            source: source,
            profileName: profileName,
            fingerprint:
              analysis.configurationFingerprint,
            diagnostics: diagnostics
          )
        self.isShowingLaunchDiagnosticOverride = true
        retainsWaitingHandoff = true
      } catch let LaunchPreparationError.blocked(diagnostics)
        where diagnostics.contains(where: {
          $0.code == .profileHealth(.storageReservedForDataOperation)
        })
      {
        let message = ProfileActivityRegistryError.storageReservedForDataOperation
          .localizedDescription
        self?.errorMessage = message
        _ = self?.updateLaunchRequestStatus(requestID: source.requestID, state: .failed(message))
      } catch {
        if let self, let application = self.applications.first(where: { $0.id == source.applicationID }),
          let profile = application.profiles.first(where: { $0.id == source.profileID }),
          let library = try? self.conversationLibrary(application: application, profile: profile),
          library.handoff?.id == source.requestID {
          self.conversationSwitchMessage = error.localizedDescription
          self.sharedHistoryRevision &+= 1
        }
        _ = self?.updateLaunchRequestStatus(
          requestID: source.requestID,
          state: .failed(error.localizedDescription)
        )
        AppLog.launch.error(
          "Launch preparation failed for \(profileName): \(error.localizedDescription)"
        )
      }
      self?.launchPreparationTasks[source.requestID] = nil
    }
  }

  func openPreparedLaunch(
    _ prepared: PreparedLaunch,
    profileName: String,
    concurrentLaunchPolicy: ConcurrentProfileLaunchPolicy
  ) throws {
    guard canUseSettingsAuthority(), canLaunchDuringRecovery(
      identity: ProfileActivityIdentity(applicationID: prepared.applicationID, applicationStorageID: prepared.applicationStorageID,
        profileID: prepared.profileID, profileStorageID: prepared.profileStorageID), profileName: profileName) else {
      _ = updateLaunchRequestStatus(requestID: prepared.requestID, state: .cancelled)
      return
    }
    let applicationID = prepared.applicationID
    let profileID = prepared.profileID
    if let trackedLauncher =
      launcher as? any PreparedTrackedApplicationLaunching
    {
      let verification = isolationVerification
      verification.register(requestID: prepared.requestID, paths: prepared.isolation.managedVerificationPaths)
      var accepted = false
      defer {
        if !accepted { verification.remove(requestID: prepared.requestID) }
      }
      let tracked = try trackedLauncher.launchTracked(
        prepared: prepared,
        activityRegistry: profileActivityRegistry,
        concurrentLaunchPolicy: concurrentLaunchPolicy,
        lifecycleHandler: { [weak self] lifecycle in
          Task { @MainActor in
            self?.handleLaunchLifecycle(
              lifecycle,
              profileName: profileName
            )
          }
        }
      ) { event in
        Task { @MainActor in
          switch event {
          case .requested, .running, .terminated, .cancelled, .mainHistoryActivated:
            break
          case .trackingDegraded(_, _, let message):
            AppLog.launch.error(
              "Launch tracking degraded for \(profileName): \(message)"
            )
          case .failed(_, let message):
            AppLog.launch.error(
              "Failed to launch \(profileName): \(message)"
            )
          }
        }
      }
      accepted = true
      retainTrackedLaunch(
        tracked,
        requestID: prepared.requestID
      )
      if tracked.currentLifecycle.state.isTerminal {
        verification.remove(requestID: prepared.requestID)
        handleLaunchLifecycle(
          tracked.currentLifecycle,
          profileName: profileName
        )
      }
      return
    }
    guard
      let preparedLauncher =
        launcher as? any PreparedApplicationLaunching
    else {
      throw LaunchError.preparationRequired
    }
    try preparedLauncher.launch(prepared: prepared) { [weak self] result in
      Task { @MainActor in
        switch result {
        case .success:
          _ = self?.updateLaunchRequestStatus(
            requestID: prepared.requestID,
            state: .running
          )
          self?.recordAcceptedLaunch(
            applicationID: applicationID,
            profileID: profileID,
            profileName: profileName
          )
        case .failure(let error):
          _ = self?.updateLaunchRequestStatus(
            requestID: prepared.requestID,
            state: .failed(error.localizedDescription)
          )
          AppLog.launch.error(
            "Failed to launch \(profileName): \(error.localizedDescription)"
          )
        }
      }
    }
  }

  func registerDirectLaunchIfNeeded(
    application: ManagedApplication,
    profile: LaunchProfile,
    source: LaunchConfigurationSource
  ) -> Bool {
    if launchRequests.status(for: source.requestID) != nil {
      return true
    }
    let fingerprint =
      LaunchConfigurationCompiler.configurationFingerprint(
        for: source
      )
    let request = ImmutableLaunchRequest(
      sceneID: sceneID,
      applicationName: application.displayName,
      profileName: profile.name,
      configurationSnapshot: source,
      configurationFingerprint: fingerprint
    )
    switch launchRequests.submit(request, policy: .rejectNew) {
    case .awaitingConfirmation:
      let resolution = launchRequests.confirm(
        sceneID: sceneID,
        requestID: request.requestID,
        currentTarget: .available(
          applicationID: application.id,
          profileID: profile.id,
          configurationRevision:
            source.configurationRevision,
          configurationFingerprint: fingerprint
        )
      )
      if case .confirmed = resolution {
        return true
      }
      return false
    case .queued:
      return false
    case .rejected(_, let reason):
      errorMessage = reason.message
      return false
    }
  }

  func retainTrackedLaunch(
    _ launch: TrackedApplicationLaunch,
    requestID: UUID
  ) {
    guard !launch.currentLifecycle.state.isTerminal else {
      return
    }
    activeTrackedLaunches[requestID] = launch
    launchPresentationRevision &+= 1
  }

  @discardableResult
  func updateLaunchRequestStatus(
    requestID: UUID,
    state: LaunchRequestStatusState
  ) -> Bool {
    let changed = launchRequests.updateStatus(
      requestID: requestID,
      state: state
    )
    if changed {
      launchPresentationRevision &+= 1
    }
    return changed
  }

  func launchStatusPresentation(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> SpaceLaunchStatusPresentation? {
    _ = launchPresentationRevision
    guard
      let status = launchRequests.visibleStatus(
        sceneID: sceneID,
        profileID: profile.id
      ),
      status.applicationID == application.id
    else {
      return nil
    }
    let disposition = activeTrackedLaunches[status.requestID]?.currentLifecycle.openingDisposition
    let blockingProfileName: String?
    if case .waitingForEarlierOpen(_, let requestID) = disposition,
      let requestID, let identity = ProcessWideLaunchSupervision.shared.launch(requestID: requestID)?.currentLifecycle.identity {
      blockingProfileName = applications.first { $0.storageID == identity.applicationStorageID }?
        .profiles.first { $0.storageID == identity.profileStorageID }?.name
    } else {
      blockingProfileName = nil
    }
    return LaunchStatusPresenter.presentation(
      applicationName: application.displayName,
      profileName: profile.name,
      state: status.state,
      openingDisposition: disposition,
      blockingProfileName: blockingProfileName,
      isolationActivityUnobserved: isolationVerification.notices.contains(status.requestID)
    )
  }

  func launchStatusMessage(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> String? {
    launchStatusPresentation(
      for: application,
      profile: profile
    )?.message
  }

  func recordAcceptedLaunch(
    applicationID: ManagedApplication.ID,
    profileID: LaunchProfile.ID,
    profileName: String
  ) {
    guard settings.canProvideVerifiedSettings,
      !isProfileDataOperationRunning,
      case .loaded = loadState,
      migrationRequiredLibrary == nil
    else { return }
    let now = Date()
    if let appIndex = applications.firstIndex(where: {
      $0.id == applicationID
    }),
      let profileIndex = applications[appIndex].profiles.firstIndex(where: {
        $0.id == profileID
      })
    {
      var candidate = applications
      candidate[appIndex].profiles[profileIndex].lastLaunchedAt = now
      guard
        commit(
          candidate,
          selectedApplicationID: selectedApplicationID,
          selectedProfileID: selectedProfileID
        )
      else {
        return
      }
    }
    AppLog.launch.info("Successfully launched \(profileName)")
  }
}
