import AppKit
import Foundation
import Observation

extension LibraryStore {
  func handleLaunchLifecycle(
    _ lifecycle: ProfileLaunchLifecycleSnapshot,
    profileName: String
  ) {
    guard lifecycleIsAuthoritative(lifecycle) else {
      return
    }
    if lifecycle.state.isTerminal {
      isolationVerification.remove(requestID: lifecycle.requestID)
      activeTrackedLaunches[lifecycle.requestID] = nil
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
      case .waitingForEarlierOpen:
        _ = updateLaunchRequestStatus(requestID: lifecycle.requestID, state: .launching)
        launchPresentationRevision &+= 1
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
      finishConversationSwitch(lifecycle, application: application, profile: profile)
      _ = isolationVerification.running(requestID: lifecycle.requestID)
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
      // The process opened and is supervised; only durable tracking failed.
      finishConversationSwitch(lifecycle, application: application, profile: profile)
      _ = isolationVerification.running(requestID: lifecycle.requestID)
      recordLaunchHistory(
        lifecycle,
        application: application,
        profile: profile,
        fallbackProfileName: profileName
      )
      if updateLaunchRequestStatus(
        requestID: lifecycle.requestID,
        state: .running
      ) {
        recordAcceptedLaunch(
          applicationID: application.id,
          profileID: profile.id,
          profileName: profileName
        )
      }
      errorMessage = LaunchStatusPresenter.degradedTrackingMessage(
        profileName: profileName,
        detail: message
      )
    case .terminating:
      isolationVerification.remove(requestID: lifecycle.requestID)
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
        _ = updateLaunchRequestStatus(
          requestID: lifecycle.requestID,
          state: .terminated
        )
        scheduleCrashConfirmation(
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
    case .cancelled:
      recordLaunchHistory(lifecycle, application: application, profile: profile, fallbackProfileName: profileName)
      _ = updateLaunchRequestStatus(requestID: lifecycle.requestID, state: .cancelled)
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
      case .requested, .launching, .failed, .cancelled:
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
    case .requested, .launching, .failed, .cancelled:
      guard let processIdentity = lifecycle.processIdentity else {
        return true
      }
      return launch.isSupervising(processIdentity)
    }
  }

  func recoveryTarget(
    application: ManagedApplication,
    profile: LaunchProfile
  ) -> (application: ManagedApplication, profile: LaunchProfile)? {
    guard
      let currentApplication = applications.first(where: {
        $0.id == application.id && $0.storageID == application.storageID
      }),
      let currentProfile = currentApplication.profiles.first(where: {
        $0.id == profile.id && $0.storageID == profile.storageID
      }),
      recoveryFingerprint(application: currentApplication, profile: currentProfile)
        == recoveryFingerprint(application: application, profile: profile)
    else { return nil }
    return (currentApplication, currentProfile)
  }

  func recoveryFingerprint(application: ManagedApplication, profile: LaunchProfile)
    -> LaunchConfigurationFingerprint
  {
    var source = launchConfigurationSource(
      application: application, profile: profile, requestID: profile.id)
    source.configurationRevision = 0
    return LaunchConfigurationCompiler.configurationFingerprint(for: source)
  }

  func scheduleCrashConfirmation(
    lifecycle: ProfileLaunchLifecycleSnapshot,
    application: ManagedApplication,
    profile: LaunchProfile
  ) {
    guard canUseSettingsAuthority() else { return }
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
      guard let report, let self else { return }

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

      self.errorMessage = LaunchStatusPresenter.confirmedCrashMessage(
        profileName: currentProfile.name
      )
      guard self.settings.automaticallyRecoverCrashedApps else {
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
            confirmedCrashAt: report.capturedAt
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
        let fingerprint = self.recoveryFingerprint(
          application: currentApplication, profile: currentProfile)
        if delay > 0 {
          try? await Task.sleep(
            nanoseconds:
              UInt64(delay * 1_000_000_000)
          )
        }
        guard
          !Task.isCancelled,
          self.settings.automaticallyRecoverCrashedApps,
          let target = self.recoveryTarget(
            application: currentApplication, profile: currentProfile),
          self.recoveryFingerprint(application: target.application, profile: target.profile)
            == fingerprint,
          !self.isSpaceRunning(
            application: target.application,
            profile: target.profile
          )
        else {
          self.libraryOperationStatusMessage = String(
            localized:
              "Automatic recovery was cancelled because the space or its launch settings changed, recovery was disabled, or the space is already running."
          )
          return
        }
        self.beginLaunch(
          target.profile,
          application: target.application,
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
}
