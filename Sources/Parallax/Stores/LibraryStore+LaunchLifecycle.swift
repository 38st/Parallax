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

    launchHistoryStore.record(
      lifecycle,
      application: application,
      profile: profile,
      fallbackProfileName: profileName
    )

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
      _ = updateLaunchRequestStatus(
        requestID: lifecycle.requestID,
        state: .launching
      )
    case .running:
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
      _ = updateLaunchRequestStatus(
        requestID: lifecycle.requestID,
        state: .running
      )
      errorMessage = String(
        localized:
          "\(profileName) opened, but Parallax could not enable durable process tracking. Managed-data actions remain blocked until the process closes. \(message)"
      )
    case .terminating:
      break
    case .terminated:
      activeTrackedLaunches[lifecycle.requestID] = nil
      if lifecycle.terminationDisposition == .unexpected {
        let message = String(
          localized:
            "\(profileName) ended unexpectedly. Its data remains isolated; review Recent Activity for a crash report or choose Open Again."
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
      _ = updateLaunchRequestStatus(
        requestID: lifecycle.requestID,
        state: .failed(message)
      )
    }
  }

  func scheduleConfirmedCrashRecovery(
    lifecycle: ProfileLaunchLifecycleSnapshot,
    application: ManagedApplication,
    profile: LaunchProfile
  ) {
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

  func launchStatusMessage(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> String? {
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
    switch status.state {
    case .queuedForConfirmation:
      return String(localized: "Waiting to open")
    case .awaitingConfirmation:
      return String(localized: "Waiting for confirmation")
    case .confirmed, .launching:
      return String(localized: "Opening \(profile.name)…")
    case .running:
      return String(
        localized:
          "Opened \(profile.name) in \(application.displayName)."
      )
    case .terminated:
      return String(localized: "\(profile.name) closed")
    case .cancelled:
      return String(localized: "Open cancelled")
    case .failed(let message):
      return String(
        localized:
          "Couldn’t open \(profile.name): \(message)"
      )
    case .invalidated(let reason):
      return reason.message
    case .rejected(let reason):
      return reason.message
    }
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
