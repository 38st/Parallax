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

  func pendingProfileEditingDraft(
    applicationID: ManagedApplication.ID,
    profileID: LaunchProfile.ID
  ) -> PendingProfileEditingDraft? {
    guard
      let pending = pendingProfileEditingDrafts[profileID],
      pending.applicationID == applicationID
    else {
      return nil
    }
    return pending
  }

  func rememberProfileEditingDraft(
    applicationID: ManagedApplication.ID,
    draft: LaunchProfile,
    baseline: LaunchProfile,
    baselineVersion: LibraryVersionToken,
    stagedKeychainReferences: Set<EnvironmentSecretReference>,
    pendingKeychainDeletionReferences:
      Set<EnvironmentSecretReference>
  ) {
    guard
      draft != baseline
        || !stagedKeychainReferences.isEmpty
        || !pendingKeychainDeletionReferences.isEmpty
    else {
      pendingProfileEditingDrafts.removeValue(forKey: draft.id)
      return
    }
    pendingProfileEditingDrafts[draft.id] = PendingProfileEditingDraft(
      applicationID: applicationID,
      draft: draft,
      baseline: baseline,
      baselineVersion: baselineVersion,
      stagedKeychainReferences: stagedKeychainReferences,
      pendingKeychainDeletionReferences:
        pendingKeychainDeletionReferences
    )
  }

  func forgetProfileEditingDraft(profileID: LaunchProfile.ID) {
    pendingProfileEditingDrafts.removeValue(forKey: profileID)
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

  func assessImportedLaunch(
    application: ManagedApplication,
    profile: LaunchProfile,
    requireGlobalConfirmation: Bool
  ) {
    let requestID = UUID()
    let source = launchConfigurationSource(
      application: application,
      profile: profile,
      requestID: requestID
    )
    let compiler = launchConfigurationCompiler
    let trust = importedLaunchTrust
    importedLaunchAssessmentTasks[requestID] = Task {
      let analysis = await compiler.analyze(source)
      guard !Task.isCancelled else { return }
      guard
        let currentApplication = applications.first(where: {
          $0.id == application.id
            && $0.storageID == application.storageID
        }),
        let currentProfile =
          currentApplication.profiles.first(where: {
            $0.id == profile.id
              && $0.storageID == profile.storageID
          }),
        currentApplication == application,
        currentProfile == profile
      else {
        errorMessage = String(
          localized:
            "The launch configuration changed while it was being inspected. Try again."
        )
        importedLaunchAssessmentTasks[requestID] = nil
        return
      }
      guard canUseSettingsAuthority() else {
        importedLaunchAssessmentTasks[requestID] = nil
        return
      }
      let trustSource = importedLaunchTrustSource(
        application: application,
        profile: profile,
        analysis: analysis
      )
      switch trust.assessment(
        for: profile,
        source: trustSource
      ) {
      case .trustedLocal:
        beginLaunch(
          profile,
          application: application,
          requireGlobalConfirmation:
            requireGlobalConfirmation
        )
      case .approved:
        if requireGlobalConfirmation
          && settings.confirmBeforeLaunch
        {
          submitLaunchConfirmation(
            application: application,
            profile: profile,
            source: source,
            fingerprint:
              analysis.configurationFingerprint
          )
        } else {
          performLaunch(
            application: application,
            profile: profile,
            preparedSource: source
          )
        }
      case .reviewRequired(let review):
        pendingImportedLaunch = PendingImportedLaunch(
          applicationID: application.id,
          profileID: profile.id,
          review: review
        )
        pendingImportedLaunchReview = review
        isShowingImportedLaunchReview = true
      }
      importedLaunchAssessmentTasks[requestID] = nil
    }
  }

  func confirmImportedLaunchReview(
    expectedFingerprint: ImportedLaunchConfigurationFingerprint? = nil
  ) {
    guard let pending = pendingImportedLaunch else { return }
    if let expectedFingerprint,
      expectedFingerprint != pending.review.fingerprint
    {
      errorMessage = String(
        localized:
          "The imported launch configuration changed after review. Review it again."
      )
      cancelImportedLaunchReview()
      return
    }
    guard
      let application = applications.first(where: {
        $0.id == pending.applicationID
      }),
      let profile = application.profiles.first(where: {
        $0.id == pending.profileID
      })
    else {
      cancelImportedLaunchReview()
      return
    }
    let requestID = UUID()
    let source = launchConfigurationSource(
      application: application,
      profile: profile,
      requestID: requestID
    )
    let compiler = launchConfigurationCompiler
    let trust = importedLaunchTrust
    importedLaunchAssessmentTasks[requestID] = Task {
      let analysis = await compiler.analyze(source)
      guard !Task.isCancelled else { return }
      guard
        let currentApplication = applications.first(where: {
          $0.id == application.id
        }),
        let currentProfile =
          currentApplication.profiles.first(where: {
            $0.id == profile.id
          }),
        currentApplication == application,
        currentProfile == profile,
        pendingImportedLaunch?.review.fingerprint
          == pending.review.fingerprint
      else {
        errorMessage = String(
          localized:
            "The imported launch configuration changed after review. Review it again."
        )
        cancelImportedLaunchReview()
        importedLaunchAssessmentTasks[requestID] = nil
        return
      }
      do {
        let currentTrustSource =
          importedLaunchTrustSource(
            application: application,
            profile: profile,
            analysis: analysis
          )
        let approval = try trust.approval(
          for: pending.review,
          currentSource: currentTrustSource
        )
        guard
          let appIndex = applications.firstIndex(where: {
            $0.id == application.id
          }),
          let profileIndex = applications[appIndex]
            .profiles.firstIndex(where: {
              $0.id == profile.id
            })
        else {
          throw ImportedLaunchTrustError
            .configurationChangedAfterReview
        }
        var candidate = applications
        candidate[appIndex].profiles[profileIndex]
          .approveImportedLaunch(using: approval)
        guard
          commit(
            candidate,
            selectedApplicationID: application.id,
            selectedProfileID: profile.id
          )
        else {
          importedLaunchAssessmentTasks[requestID] = nil
          return
        }
        let approvedApplication = candidate[appIndex]
        let approvedProfile =
          approvedApplication.profiles[profileIndex]
        cancelImportedLaunchReview()
        performLaunch(
          application: approvedApplication,
          profile: approvedProfile,
          preparedSource: source
        )
      } catch {
        errorMessage = error.localizedDescription
        cancelImportedLaunchReview()
      }
      importedLaunchAssessmentTasks[requestID] = nil
    }
  }

  func cancelImportedLaunchReview() {
    pendingImportedLaunch = nil
    pendingImportedLaunchReview = nil
    isShowingImportedLaunchReview = false
  }

  func launchConfigurationSource(
    application: ManagedApplication,
    profile: LaunchProfile,
    requestID: UUID
  ) -> LaunchConfigurationSource {
    LaunchConfigurationSource(
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
      argumentsText: profile.argumentsText,
      environmentText: profile.environmentText,
      isolationOwnership: profile.isolationOwnership,
      childEnvironmentPolicy: profile.childEnvironmentPolicy,
      sensitiveEnvironmentKeys: profile.sensitiveEnvironmentKeys,
      peerProfiles: application.profiles.compactMap { peer in
        guard peer.id != profile.id else { return nil }
        return LaunchPeerProfileSource(
          profileID: peer.id,
          profileStorageID: peer.storageID,
          argumentsText: peer.argumentsText,
          environmentText: peer.environmentText,
          isolationOwnership: peer.isolationOwnership
        )
      }
    )
  }

  func importedLaunchTrustSource(
    application: ManagedApplication,
    profile: LaunchProfile,
    analysis: LaunchAnalysis
  ) -> ImportedLaunchTrustSource {
    var isolationPaths: [ImportedLaunchIsolationPath] = []
    if let userData = analysis.isolation.userData {
      isolationPaths.append(
        ImportedLaunchIsolationPath(
          role: .userData,
          authority:
            userData.isManaged ? .managed : .external,
          canonicalURL: userData.canonicalURL
        )
      )
    }
    if let codexHome = analysis.isolation.codexHome {
      isolationPaths.append(
        ImportedLaunchIsolationPath(
          role: .codexHome,
          authority:
            codexHome.isManaged ? .managed : .external,
          canonicalURL: codexHome.canonicalURL
        )
      )
    }
    return ImportedLaunchTrustSource(
      applicationID: application.id,
      applicationStorageID: application.storageID,
      applicationDisplayName: application.displayName,
      canonicalApplicationURL:
        analysis.applicationHealth.canonicalApplicationURL
        ?? URL(fileURLWithPath: application.appPath)
        .standardizedFileURL,
      expectedBundleIdentifier: application.bundleIdentifier,
      verifiedBundleIdentifier:
        analysis.applicationHealth.bundleIdentifier,
      profileID: profile.id,
      profileStorageID: profile.storageID,
      profileName: profile.name,
      configuredBaseRoot: configuredBaseRoot(for: application),
      argumentsText: profile.argumentsText,
      environmentText: profile.environmentText,
      isolationOwnership: profile.isolationOwnership,
      childEnvironmentPolicy: profile.childEnvironmentPolicy,
      sensitiveEnvironmentKeys:
        profile.sensitiveEnvironmentKeys,
      isolationPaths: isolationPaths
    )
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
