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
    guard canUseSettingsAuthority() else { return }
    let compiler = launchConfigurationCompiler
    launchPreparationTasks[source.requestID]?.cancel()
    launchPreparationTasks[source.requestID] = Task { [weak self] in
      do {
        let prepared = try await compiler.prepare(
          source,
          override: override
        )
        try Task.checkCancellation()
        guard let self else { return }
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
        guard !Task.isCancelled else { return }
        guard self?.canUseSettingsAuthority() == true else { return }
        self?.pendingConcurrentLaunchRequest =
          PendingConcurrentLaunchRequest(
            source: source,
            profileName: profileName,
            fingerprint:
              analysis.configurationFingerprint
          )
        self?.isShowingConcurrentLaunchOverride = true
      } catch let LaunchPreparationError.blocked(diagnostics)
        where override == nil
        && diagnostics.allSatisfy(\.isOverridable)
      {
        let analysis = await compiler.analyze(source)
        guard !Task.isCancelled else { return }
        guard self?.canUseSettingsAuthority() == true else { return }
        self?.pendingLaunchDiagnosticRequest =
          PendingLaunchDiagnosticRequest(
            source: source,
            profileName: profileName,
            fingerprint:
              analysis.configurationFingerprint,
            diagnostics: diagnostics
          )
        self?.isShowingLaunchDiagnosticOverride = true
      } catch {
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
    guard canUseSettingsAuthority() else { return }
    let applicationID = prepared.applicationID
    let profileID = prepared.profileID
    if let trackedLauncher =
      launcher as? any PreparedTrackedApplicationLaunching
    {
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
          case .requested, .running, .terminated:
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
      retainTrackedLaunch(
        tracked,
        requestID: prepared.requestID
      )
      if tracked.currentLifecycle.state.isTerminal {
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
    case .rejected:
      return false
    }
  }

  func handleLaunchLifecycle(
    _ lifecycle: ProfileLaunchLifecycleSnapshot,
    profileName: String
  ) {
    guard lifecycleIsAuthoritative(lifecycle) else {
      return
    }
    let application = applications.first(where: {
      $0.id == lifecycle.identity.applicationID
        && $0.storageID
          == lifecycle.identity.applicationStorageID
    })
    let profile = application?.profiles.first(where: {
      $0.id == lifecycle.identity.profileID
        && $0.storageID
          == lifecycle.identity.profileStorageID
    })

    guard
      let application,
      let profile,
      lifecycle.matches(
        application: application,
        profile: profile
      )
    else {
      return
    }

    switch lifecycle.state {
    case .requested, .launching:
      switch lifecycle.openingDisposition {
      case .pending:
        _ = updateLaunchRequestStatus(
          requestID: lifecycle.requestID,
          state: .launching
        )
      case .outcomeUnknownAfterError(let detail):
        let message = LaunchStatusPresenter.unknownOpenOutcomeMessage(
          applicationName: application.displayName,
          profileName: profileName,
          detail: detail
        )
        errorMessage = message
        launchPresentationRevision &+= 1
      case .provenanceIndeterminate:
        errorMessage = LaunchStatusPresenter.indeterminateProvenanceMessage(
          applicationName: application.displayName,
          profileName: profileName
        )
        launchPresentationRevision &+= 1
      case .preExistingSingletonRefused:
        break
      }
    case .running:
      recordLaunchHistory(
        lifecycle,
        application: application,
        profile: profile,
        fallbackProfileName: profileName
      )
      let changed = updateLaunchRequestStatus(
        requestID: lifecycle.requestID,
        state: .running
      )
      if changed {
        recordAcceptedLaunch(
          applicationID: application.id,
          profileID: profile.id,
          profileName: profileName
        )
      }
    case .runningDegraded(_, let message):
      recordLaunchHistory(
        lifecycle,
        application: application,
        profile: profile,
        fallbackProfileName: profileName
      )
      _ = updateLaunchRequestStatus(
        requestID: lifecycle.requestID,
        state: .running
      )
      errorMessage = LaunchStatusPresenter.degradedTrackingMessage(
        profileName: profileName,
        detail: message
      )
    case .terminating:
      recordLaunchHistory(
        lifecycle,
        application: application,
        profile: profile,
        fallbackProfileName: profileName
      )
      launchPresentationRevision &+= 1
    case .terminated:
      activeTrackedLaunches[lifecycle.requestID] = nil
      if case .provenanceIndeterminate = lifecycle.openingDisposition {
        let message = LaunchStatusPresenter.indeterminateProcessEndedMessage(
          profileName: profileName
        )
        _ = updateLaunchRequestStatus(
          requestID: lifecycle.requestID,
          state: .failed(message)
        )
        return
      }
      recordLaunchHistory(
        lifecycle,
        application: application,
        profile: profile,
        fallbackProfileName: profileName
      )
      if lifecycle.terminationDisposition == .unexpected {
        let message = LaunchStatusPresenter.unexpectedTerminationMessage(
          profileName: profileName
        )
        _ = updateLaunchRequestStatus(
          requestID: lifecycle.requestID,
          state: .failed(message)
        )
        errorMessage = message
        scheduleConfirmedCrashRecovery(
          lifecycle: lifecycle,
          application: application,
          profile: profile
        )
      } else {
        _ = updateLaunchRequestStatus(
          requestID: lifecycle.requestID,
          state: .terminated
        )
      }
    case .failed(let message):
      if case .preExistingSingletonRefused =
        lifecycle.openingDisposition
      {
        activeTrackedLaunches[lifecycle.requestID] = nil
        let refusal = LaunchStatusPresenter
          .preExistingSingletonRefusalMessage(
          applicationName: application.displayName,
          profileName: profileName
        )
        _ = updateLaunchRequestStatus(
          requestID: lifecycle.requestID,
          state: .failed(refusal)
        )
        errorMessage = refusal
        return
      }
      if case .provenanceIndeterminate =
        lifecycle.openingDisposition
      {
        activeTrackedLaunches[lifecycle.requestID] = nil
        let failure = LaunchStatusPresenter.indeterminateProcessEndedMessage(
          profileName: profileName
        )
        _ = updateLaunchRequestStatus(
          requestID: lifecycle.requestID,
          state: .failed(failure)
        )
        errorMessage = failure
        return
      }
      recordLaunchHistory(
        lifecycle,
        application: application,
        profile: profile,
        fallbackProfileName: profileName
      )
      _ = updateLaunchRequestStatus(
        requestID: lifecycle.requestID,
        state: .failed(message)
      )
    }
  }

  private func recordLaunchHistory(
    _ lifecycle: ProfileLaunchLifecycleSnapshot,
    application: ManagedApplication,
    profile: LaunchProfile,
    fallbackProfileName: String
  ) {
    launchHistoryStore.record(
      lifecycle,
      application: application,
      profile: profile,
      fallbackProfileName: fallbackProfileName
    )
  }

  private func lifecycleIsAuthoritative(
    _ lifecycle: ProfileLaunchLifecycleSnapshot
  ) -> Bool {
    guard let launch = activeTrackedLaunches[lifecycle.requestID] else {
      guard
        lifecycle.processIdentity == nil,
        let status = launchRequests.status(
          for: lifecycle.requestID
        ),
        status.applicationID == lifecycle.identity.applicationID,
        status.profileID == lifecycle.identity.profileID,
        let application = applications.first(where: {
          $0.id == lifecycle.identity.applicationID
            && $0.storageID
              == lifecycle.identity.applicationStorageID
        }),
        application.profiles.contains(where: {
          $0.id == lifecycle.identity.profileID
            && $0.storageID
              == lifecycle.identity.profileStorageID
        })
      else {
        return false
      }
      switch lifecycle.state {
      case .requested, .launching, .failed:
        return true
      case .running, .runningDegraded, .terminating, .terminated:
        return false
      }
    }
    guard launch.currentLifecycle == lifecycle else {
      return false
    }
    switch lifecycle.state {
    case .running, .runningDegraded, .terminating, .terminated:
      if lifecycle.processIdentity == nil,
        case .provenanceIndeterminate = lifecycle.openingDisposition,
        case .terminated = lifecycle.state
      {
        return true
      }
      guard let processIdentity = lifecycle.processIdentity else {
        return false
      }
      return launch.isSupervising(processIdentity)
    case .requested, .launching, .failed:
      guard let processIdentity = lifecycle.processIdentity else {
        return true
      }
      return launch.isSupervising(processIdentity)
    }
  }

  func scheduleConfirmedCrashRecovery(
    lifecycle: ProfileLaunchLifecycleSnapshot,
    application: ManagedApplication,
    profile: LaunchProfile
  ) {
    guard canUseSettingsAuthority() else { return }
    guard settings.automaticallyRecoverCrashedApps else {
      return
    }
    guard
      let entry = launchHistoryStore.entries(
        for: application
      ).first(where: {
        $0.requestID == lifecycle.requestID
      })
    else {
      return
    }
    let locator = ApplicationCrashReportLocator()
    let requestID = lifecycle.requestID

    Task { [weak self] in
      // DiagnosticReports is written after process termination. A
      // bounded grace period avoids treating a normal quit as a crash.
      try? await Task.sleep(nanoseconds: 2_000_000_000)
      guard !Task.isCancelled else { return }
      let report = await Task.detached {
        locator.reports(matching: [entry])[requestID]
      }.value
      guard report != nil, let self else { return }

      guard
        let currentApplication =
          self.applications.first(where: {
            $0.id == application.id
              && $0.storageID
                == application.storageID
          }),
        let currentProfile =
          currentApplication.profiles.first(where: {
            $0.id == profile.id
              && $0.storageID == profile.storageID
          })
      else {
        return
      }

      let key = ManagedAppRecoveryKey(
        applicationStorageID:
          currentApplication.storageID,
        profileStorageID: currentProfile.storageID
      )
      let decision: ManagedAppRecoveryDecision
      do {
        decision = try self.managedAppRecoveryLedger
          .decision(
            for: key,
            confirmedCrashAt:
              report?.capturedAt ?? Date()
          )
      } catch {
        self.errorMessage = String(
          localized:
            "\(currentProfile.name) crashed, but automatic recovery is paused because its persistent retry history is unavailable. Review Recent Activity and choose Open Again. \(error.localizedDescription)"
        )
        return
      }
      switch decision {
      case .retry(let delay, let attempt, let maximumAttempts):
        self.libraryOperationStatusMessage = String(
          localized:
            "Confirmed crash for \(currentProfile.name). Automatic recovery attempt \(attempt) of \(maximumAttempts) will start shortly."
        )
        if delay > 0 {
          try? await Task.sleep(
            nanoseconds:
              UInt64(delay * 1_000_000_000)
          )
        }
        guard
          !Task.isCancelled,
          !self.isSpaceRunning(
            application: currentApplication,
            profile: currentProfile
          )
        else {
          return
        }
        self.beginLaunch(
          currentProfile,
          application: currentApplication,
          requireGlobalConfirmation: false
        )

      case .circuitOpen(let retryAfter):
        self.errorMessage = String(
          localized:
            "\(currentProfile.name) crashed repeatedly, so automatic recovery stopped until \(retryAfter.formatted(date: .omitted, time: .shortened)). Review Recent Activity, apply any verified workaround, then choose Open Again."
        )
      }
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
    return LaunchStatusPresenter.presentation(
      applicationName: application.displayName,
      profileName: profile.name,
      state: status.state,
      openingDisposition:
        activeTrackedLaunches[status.requestID]?
          .currentLifecycle.openingDisposition
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
