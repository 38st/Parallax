import AppKit
import Foundation
import Observation

// MARK: - Launch lifecycle

extension LibraryStore {
  func launchSelectedProfile() {
    guard
      let application = selectedApplication,
      let profile = selectedProfile
    else { return }
    launch(profile, application: application)
  }

  func launch(_ profile: LaunchProfile) {
    guard let application = applicationForLaunch(profile) else { return }
    if let pendingDraft = pendingProfileEditingDraft(
      applicationID: application.id,
      profileID: profile.id
    ), pendingDraft.draft != pendingDraft.baseline {
      selectedApplicationID = application.id
      selectedProfileID = profile.id
      errorMessage = String(
        localized:
          "This space has unsaved changes. Review them, then use Save & Open so Parallax never opens stale settings."
      )
      return
    }
    launch(profile, application: application)
  }

  func launch(_ profile: LaunchProfile, application: ManagedApplication) {
    beginLaunch(
      profile,
      application: application,
      requireGlobalConfirmation: true
    )
  }

  func beginLaunch(
    _ profile: LaunchProfile,
    application: ManagedApplication,
    requireGlobalConfirmation: Bool
  ) {
    guard canUseSettingsAuthority() else { return }
    if profile.launchConfigurationTrust.isImported {
      assessImportedLaunch(
        application: application,
        profile: profile,
        requireGlobalConfirmation:
          requireGlobalConfirmation
      )
      return
    }
    if requireGlobalConfirmation && settings.confirmBeforeLaunch {
      let source = launchConfigurationSource(
        application: application,
        profile: profile,
        requestID: UUID()
      )
      submitLaunchConfirmation(
        application: application,
        profile: profile,
        source: source,
        fingerprint:
          LaunchConfigurationCompiler
          .configurationFingerprint(for: source)
      )
      return
    }
    performLaunch(application: application, profile: profile)
  }

  func confirmLaunch() {
    guard
      let request =
        launchRequests.pendingConfirmation(in: sceneID)
    else { return }
    isShowingLaunchConfirmation = false
    let target = currentLaunchTarget(for: request)
    switch launchRequests.confirm(
      sceneID: sceneID,
      requestID: request.requestID,
      currentTarget: target
    ) {
    case .confirmed(let confirmed):
      guard
        let application = applications.first(where: {
          $0.id == confirmed.applicationID
        }),
        let profile = application.profiles.first(where: {
          $0.id == confirmed.profileID
        })
      else {
        errorMessage = String(
          localized:
            "The confirmed open target was removed. Choose a space and try again."
        )
        return
      }
      performLaunch(
        application: application,
        profile: profile,
        preparedSource:
          confirmed.configurationSnapshot
      )
    case .invalidated(_, let reason):
      errorMessage = reason.message
    case .notPending:
      errorMessage = String(
        localized:
          "This open confirmation is no longer pending."
      )
    }
  }

  func cancelLaunch() {
    if let request =
      launchRequests.pendingConfirmation(in: sceneID)
    {
      _ = launchRequests.cancelConfirmation(
        sceneID: sceneID,
        requestID: request.requestID
      )
    }
    isShowingLaunchConfirmation = false
  }

  func launchConfigurationSource(
    application: ManagedApplication,
    profile: LaunchProfile,
    requestID: UUID
  ) -> LaunchConfigurationSource {
    let launchProfile = profileApplyingImplicitClaudeIsolation(
      profile,
      for: application
    )
    return LaunchConfigurationSource(
      requestID: requestID,
      applicationID: application.id,
      applicationStorageID: application.storageID,
      profileID: profile.id,
      profileStorageID: profile.storageID,
      configurationRevision:
        libraryVersionToken?.revision.rawValue ?? 0,
      applicationURL: URL(fileURLWithPath: application.appPath),
      expectedBundleIdentifier: application.bundleIdentifier,
      configuredBaseRoot: configuredBaseRoot(for: application),
      argumentsText: launchProfile.argumentsText,
      environmentText: launchProfile.environmentText,
      isolationOwnership: launchProfile.isolationOwnership,
      childEnvironmentPolicy: launchProfile.childEnvironmentPolicy,
      sensitiveEnvironmentKeys: launchProfile.sensitiveEnvironmentKeys,
      requiresClaudeConfigIsolation:
        Self.resolvedPreset(for: application).needsClaudeConfig,
      peerProfiles: application.profiles.compactMap { peer in
        guard peer.id != profile.id else { return nil }
        let launchPeer = profileApplyingImplicitClaudeIsolation(
          peer,
          for: application
        )
        return LaunchPeerProfileSource(
          profileID: peer.id,
          profileStorageID: peer.storageID,
          argumentsText: launchPeer.argumentsText,
          environmentText: launchPeer.environmentText,
          isolationOwnership: launchPeer.isolationOwnership
        )
      }
    )
  }

  private func profileApplyingImplicitClaudeIsolation(
    _ profile: LaunchProfile,
    for application: ManagedApplication
  ) -> LaunchProfile {
    guard Self.resolvedPreset(for: application).needsClaudeConfig,
      let paths = try? managedPaths(
        for: application,
        profile: profile
      )
    else {
      return profile
    }

    var isolated = profile
    let userData = Self.userDataDirectoryResolution(
      in: isolated.argumentsText
    )
    let hasBlankUserData =
      userData.occurrences.count == 1
      && userData.occurrences.first?.form == .equals
      && userData.occurrences.first?.value
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
    if userData.occurrences.isEmpty || hasBlankUserData {
      isolated.argumentsText = Self.settingArgument(
        named: "--user-data-dir",
        to: paths.userData.url.path,
        in: isolated.argumentsText
      )
      isolated.isolationOwnership.userData = .generated
    }
    if Self.environmentValue("CLAUDE_CONFIG_DIR", in: isolated) == nil
    {
      let configDirectory = paths.userData.url
        .appendingPathComponent(
          "ClaudeConfig",
          isDirectory: true
        )
      isolated.environmentText = Self.settingEnvironmentValue(
        "CLAUDE_CONFIG_DIR",
        to: configDirectory.path,
        in: isolated.environmentText
      )
    }
    return isolated
  }

  func performLaunch(
    application: ManagedApplication,
    profile: LaunchProfile,
    preparedSource: LaunchConfigurationSource? = nil
  ) {
    guard canUseSettingsAuthority() else { return }
    let applicationID = application.id
    let profileID = profile.id
    let profileName = profile.name
    let requestID = preparedSource?.requestID ?? UUID()
    let source =
      preparedSource
      ?? launchConfigurationSource(
        application: application,
        profile: profile,
        requestID: requestID
      )
    guard
      registerDirectLaunchIfNeeded(
        application: application,
        profile: profile,
        source: source
      )
    else { return }
    _ = updateLaunchRequestStatus(
      requestID: requestID,
      state: .launching
    )
    selectedApplicationID = applicationID
    selectedProfileID = profile.id
    launchStatusMessage = nil
    AppLog.launch.info("Launching profile \(profileName) for \(application.displayName)")

    if profile.launchConfigurationTrust.isImported,
      !(launcher is any PreparedApplicationLaunching)
    {
      let message = String(
        localized:
          "Imported launch configurations require validated launch preparation."
      )
      _ = updateLaunchRequestStatus(
        requestID: requestID,
        state: .failed(message)
      )
      return
    }

    if launcher is any PreparedApplicationLaunching {
      schedulePreparedLaunch(
        source,
        profileName: profileName,
        override: nil,
        concurrentLaunchPolicy: .deny
      )
      return
    }

    do {
      if let trackedLauncher = launcher as? any TrackedApplicationLaunching {
        let tracked = try trackedLauncher.launchTracked(
          application: application,
          profile: profile,
          requestID: requestID,
          activityRegistry: profileActivityRegistry,
          concurrentLaunchPolicy: .deny,
          lifecycleHandler: { [weak self] lifecycle in
            Task { @MainActor in
              self?.handleLaunchLifecycle(
                lifecycle,
                profileName: profileName
              )
            }
          }
        ) { event in
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
        retainTrackedLaunch(
          tracked,
          requestID: requestID
        )
        return
      }
      try launcher.launch(application: application, profile: profile) { [weak self] result in
        Task { @MainActor in
          switch result {
          case .success:
            _ = self?.updateLaunchRequestStatus(
              requestID: requestID,
              state: .running
            )
            self?.recordAcceptedLaunch(
              applicationID: applicationID,
              profileID: profileID,
              profileName: profileName
            )
          case .failure(let error):
            _ = self?.updateLaunchRequestStatus(
              requestID: requestID,
              state: .failed(error.localizedDescription)
            )
            AppLog.launch.error("Failed to launch \(profileName): \(error.localizedDescription)")
          }
        }
      }
    } catch {
      AppLog.launch.error("Launch threw for \(profileName): \(error.localizedDescription)")
      _ = updateLaunchRequestStatus(
        requestID: requestID,
        state: .failed(error.localizedDescription)
      )
    }
  }

  func confirmLaunchDiagnosticOverride() {
    guard canUseSettingsAuthority() else { return }
    guard let pending = pendingLaunchDiagnosticRequest else {
      isShowingLaunchDiagnosticOverride = false
      return
    }
    pendingLaunchDiagnosticRequest = nil
    isShowingLaunchDiagnosticOverride = false
    schedulePreparedLaunch(
      pending.source,
      profileName: pending.profileName,
      override: LaunchDiagnosticOverride(
        requestID: pending.source.requestID,
        configurationFingerprint: pending.fingerprint
      ),
      concurrentLaunchPolicy: .deny
    )
  }

  func cancelLaunchDiagnosticOverride() {
    if let requestID =
      pendingLaunchDiagnosticRequest?.source.requestID
    {
      _ = updateLaunchRequestStatus(
        requestID: requestID,
        state: .cancelled
      )
    }
    pendingLaunchDiagnosticRequest = nil
    isShowingLaunchDiagnosticOverride = false
  }

  func confirmConcurrentLaunchOverride() {
    guard canUseSettingsAuthority() else { return }
    guard let pending = pendingConcurrentLaunchRequest else {
      isShowingConcurrentLaunchOverride = false
      return
    }
    pendingConcurrentLaunchRequest = nil
    isShowingConcurrentLaunchOverride = false
    schedulePreparedLaunch(
      pending.source,
      profileName: pending.profileName,
      override: LaunchDiagnosticOverride(
        requestID: pending.source.requestID,
        configurationFingerprint: pending.fingerprint,
        allowsActiveProfileRisk: true
      ),
      concurrentLaunchPolicy: .expertOverride(
        ConcurrentProfileLaunchRiskAcknowledgement(
          acknowledgesProfileDataCorruptionRisk: true
        )
      )
    )
  }

  func cancelConcurrentLaunchOverride() {
    if let requestID =
      pendingConcurrentLaunchRequest?.source.requestID
    {
      _ = updateLaunchRequestStatus(
        requestID: requestID,
        state: .cancelled
      )
    }
    pendingConcurrentLaunchRequest = nil
    isShowingConcurrentLaunchOverride = false
  }

}
