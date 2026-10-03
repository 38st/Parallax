import AppKit
import Foundation
import Observation

extension LibraryStore {
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
        analysis: analysis,
        source: source
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
    // A repeated click or Return while approval runs must not start a
    // second approval that then reports a change after the space opened.
    guard let pending = pendingImportedLaunch, !pending.isConfirming else { return }
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
    pendingImportedLaunch?.isConfirming = true
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
            analysis: analysis,
            source: source
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
          pendingImportedLaunch?.isConfirming = false
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

  func importedLaunchTrustSource(
    application: ManagedApplication,
    profile: LaunchProfile,
    analysis: LaunchAnalysis,
    source: LaunchConfigurationSource
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
    if let claudeConfig = analysis.isolation.claudeConfig {
      isolationPaths.append(
        ImportedLaunchIsolationPath(
          role: .claudeConfig,
          authority:
            claudeConfig.isManaged ? .managed : .external,
          canonicalURL: claudeConfig.canonicalURL
        )
      )
    }
    for folder in PresetIsolationFolder.allCases {
      if let path = analysis.isolation.presetFolders[folder] {
        let role: ImportedLaunchIsolationRole = switch folder {
        case .firefoxProfile: .firefoxProfile
        case .extensions: .extensions
        }
        isolationPaths.append(ImportedLaunchIsolationPath(
          role: role,
          authority: path.isManaged ? .managed : .external,
          canonicalURL: path.canonicalURL
        ))
      }
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
      argumentsText: source.argumentsText,
      environmentText: source.environmentText,
      isolationOwnership: source.isolationOwnership,
      childEnvironmentPolicy: profile.childEnvironmentPolicy,
      sensitiveEnvironmentKeys:
        profile.sensitiveEnvironmentKeys,
      isolationPaths: isolationPaths
    )
  }
}
