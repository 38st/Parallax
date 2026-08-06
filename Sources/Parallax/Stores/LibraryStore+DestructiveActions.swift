import AppKit
import Foundation
import Observation

// MARK: - Destructive actions

extension LibraryStore {
  func isProfileActive(
    _ application: ManagedApplication,
    profile: LaunchProfile
  ) -> Bool {
    profileActivityRegistry.isStorageActive(
      applicationStorageID: application.storageID,
      profileStorageID: profile.storageID
    )
  }

  func canMutateProfile(
    _ application: ManagedApplication,
    profile: LaunchProfile,
    allowActiveDataOverride: Bool
  ) -> Bool {
    guard
      allowActiveDataOverride
        || !isProfileActive(application, profile: profile)
    else {
      errorMessage = String(
        localized:
          "This profile is launching or running. Close it before changing its data, or use the exact expert override and accept the corruption risk."
      )
      return false
    }
    return true
  }

  func requestClearProfileData(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) {
    guard
      requireCommittedProfileDraft(
        application: application,
        profile: profile
      )
    else { return }
    requestDestructiveAction(
      .clearProfileData,
      application: application,
      profile: profile
    )
  }

  func requestProfileRemoval(
    for application: ManagedApplication,
    profile: LaunchProfile,
    dataRemoval: ProfileDataRemoval
  ) {
    guard
      requireCommittedProfileDraft(
        application: application,
        profile: profile
      )
    else { return }
    let operation: DestructiveActionOperation =
      switch dataRemoval {
      case .keep:
        .removeProfile
      case .archive:
        .archiveProfileData
      case .delete:
        .deleteProfileData
      }
    requestDestructiveAction(
      operation,
      application: application,
      profile: profile
    )
  }

  func requestProfileDuplication(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) {
    guard
      requireCommittedProfileDraft(
        application: application,
        profile: profile
      )
    else { return }
    requestDestructiveAction(
      .duplicateProfileData,
      application: application,
      profile: profile
    )
  }

  func requireCommittedProfileDraft(
    application: ManagedApplication,
    profile: LaunchProfile
  ) -> Bool {
    guard
      let pending = pendingProfileEditingDraft(
        applicationID: application.id,
        profileID: profile.id
      ),
      pending.draft != pending.baseline
    else {
      return true
    }
    selectedApplicationID = application.id
    selectedProfileID = profile.id
    errorMessage = String(
      localized:
        "This space has unsaved changes. Save or discard them before duplicating, removing, or changing its stored data."
    )
    return false
  }

  func confirmDestructiveAction() {
    authorizeAndExecutePendingDestructiveAction(
      expertOverride: nil
    )
  }

  func confirmDestructiveActionAsync() async {
    await authorizeAndExecutePendingDestructiveActionAsync(
      expertOverride: nil
    )
  }

  func confirmDestructiveExpertOverride() {
    guard let request = pendingDestructiveActionRequest else {
      isShowingDestructiveExpertOverride = false
      return
    }
    let override = request.makeExpertOverrideAuthorization(
      acknowledging:
        .profileDataCorruptionAndProcessInstability
    )
    authorizeAndExecutePendingDestructiveAction(
      expertOverride: override
    )
  }

  func confirmDestructiveExpertOverrideAsync() async {
    guard let request = pendingDestructiveActionRequest else {
      isShowingDestructiveExpertOverride = false
      return
    }
    let override = request.makeExpertOverrideAuthorization(
      acknowledging:
        .profileDataCorruptionAndProcessInstability
    )
    await authorizeAndExecutePendingDestructiveActionAsync(
      expertOverride: override
    )
  }

  func cancelDestructiveAction() {
    pendingDestructiveActionRequest = nil
    isShowingDestructiveActionConfirmation = false
    isShowingDestructiveExpertOverride = false
  }

  func requestDestructiveAction(
    _ operation: DestructiveActionOperation,
    application: ManagedApplication,
    profile: LaunchProfile
  ) {
    guard canMutateLibrary() else { return }
    guard
      let libraryVersionToken,
      let currentApplication = applications.first(where: {
        $0.id == application.id
          && $0.storageID == application.storageID
      }),
      let currentProfile =
        currentApplication.profiles.first(where: {
          $0.id == profile.id
            && $0.storageID == profile.storageID
        })
    else {
      errorMessage = String(
        localized:
          "The destructive action target no longer exists."
      )
      return
    }
    do {
      let root = try managedPaths(
        for: currentApplication,
        profile: currentProfile
      ).profileRoot.url
      let canonical = try fileSystem.canonicalURL(for: root)
      let identity = try? fileSystem.attributesOfItem(
        at: canonical
      ).identity
      let request = DestructiveActionRequest(
        requestID: UUID(),
        sceneID: sceneID,
        operation: operation,
        applicationID: currentApplication.id,
        applicationStorageID:
          currentApplication.storageID,
        profileID: currentProfile.id,
        profileStorageID: currentProfile.storageID,
        applicationName:
          currentApplication.displayName,
        profileName: currentProfile.name,
        path: DestructiveActionPathSnapshot(
          canonicalURL: canonical,
          fileIdentity: identity
        ),
        configurationRevision:
          libraryVersionToken.revision.rawValue,
        libraryVersion: libraryVersionToken
      )
      pendingDestructiveActionRequest = request
      isShowingDestructiveActionConfirmation = true
      isShowingDestructiveExpertOverride = false
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func authorizeAndExecutePendingDestructiveAction(
    expertOverride:
      DestructiveActionExpertOverrideAuthorization?
  ) {
    guard let request = pendingDestructiveActionRequest else {
      cancelDestructiveAction()
      return
    }
    do {
      let current = try currentDestructiveTarget(for: request)
      let active = profileActivityRegistry.isStorageActive(
        applicationStorageID: request.applicationStorageID,
        profileStorageID: request.profileStorageID
      )
      let authorization = try request.authorizeExecution(
        currentTarget: current,
        activity: DestructiveActionActivitySnapshot(
          identity: request.activityIdentity,
          state: active ? .active : .inactive
        ),
        expertOverride: expertOverride
      )
      isShowingDestructiveActionConfirmation = false
      isShowingDestructiveExpertOverride = false
      try executeDestructiveAction(authorization)
      pendingDestructiveActionRequest = nil
    } catch let error as DestructiveActionRequestError
      where error.code == .activeProfileData
      && expertOverride == nil
    {
      isShowingDestructiveActionConfirmation = false
      isShowingDestructiveExpertOverride = true
    } catch {
      cancelDestructiveAction()
      errorMessage = error.localizedDescription
    }
  }

  func authorizeAndExecutePendingDestructiveActionAsync(
    expertOverride:
      DestructiveActionExpertOverrideAuthorization?
  ) async {
    guard !isProfileDataOperationRunning else {
      errorMessage = String(
        localized:
          "Wait for the current profile data operation to finish."
      )
      return
    }
    guard let request = pendingDestructiveActionRequest else {
      cancelDestructiveAction()
      return
    }
    do {
      let current = try currentDestructiveTarget(for: request)
      let active = profileActivityRegistry.isStorageActive(
        applicationStorageID: request.applicationStorageID,
        profileStorageID: request.profileStorageID
      )
      let authorization = try request.authorizeExecution(
        currentTarget: current,
        activity: DestructiveActionActivitySnapshot(
          identity: request.activityIdentity,
          state: active ? .active : .inactive
        ),
        expertOverride: expertOverride
      )
      isShowingDestructiveActionConfirmation = false
      isShowingDestructiveExpertOverride = false
      isProfileDataOperationRunning = true
      defer { isProfileDataOperationRunning = false }
      try await executeDestructiveActionAsync(authorization)
      pendingDestructiveActionRequest = nil
      errorMessage = nil
    } catch let error as DestructiveActionRequestError
      where error.code == .activeProfileData
      && expertOverride == nil
    {
      isShowingDestructiveActionConfirmation = false
      isShowingDestructiveExpertOverride = true
    } catch {
      cancelDestructiveAction()
      errorMessage = error.localizedDescription
    }
  }

  func currentDestructiveTarget(
    for request: DestructiveActionRequest
  ) throws -> DestructiveActionCurrentTarget? {
    guard
      let libraryVersionToken,
      let application = applications.first(where: {
        $0.id == request.applicationID
          && $0.storageID
            == request.applicationStorageID
      }),
      let profile = application.profiles.first(where: {
        $0.id == request.profileID
          && $0.storageID == request.profileStorageID
      })
    else {
      return nil
    }
    let root = try managedPaths(
      for: application,
      profile: profile
    ).profileRoot.url
    let canonical = try fileSystem.canonicalURL(for: root)
    let identity = try? fileSystem.attributesOfItem(
      at: canonical
    ).identity
    return DestructiveActionCurrentTarget(
      applicationID: application.id,
      applicationStorageID: application.storageID,
      profileID: profile.id,
      profileStorageID: profile.storageID,
      path: DestructiveActionPathSnapshot(
        canonicalURL: canonical,
        fileIdentity: identity
      ),
      configurationRevision:
        libraryVersionToken.revision.rawValue,
      libraryVersion: libraryVersionToken
    )
  }

  func executeDestructiveAction(
    _ authorization: DestructiveActionExecutionAuthorization
  ) throws {
    guard
      let application = applications.first(where: {
        $0.id == authorization.applicationID
          && $0.storageID
            == authorization.applicationStorageID
      }),
      let profile = application.profiles.first(where: {
        $0.id == authorization.profileID
          && $0.storageID
            == authorization.profileStorageID
      })
    else {
      throw DestructiveActionRequestError(.targetRemoved)
    }
    selectedApplicationID = application.id
    selectedProfileID = profile.id
    let allowOverride = authorization.usedExpertOverride
    let succeeded: Bool =
      switch authorization.operation {
      case .clearProfileData:
        clearProfileData(
          for: application,
          profile: profile,
          allowActiveDataOverride: allowOverride
        )
      case .duplicateProfileData:
        duplicateSelectedProfile(
          allowActiveDataOverride: allowOverride
        )
      case .removeProfile:
        remove(
          profile: profile,
          dataRemoval: .keep,
          allowActiveDataOverride: allowOverride
        )
      case .archiveProfileData:
        remove(
          profile: profile,
          dataRemoval: .archive,
          allowActiveDataOverride: allowOverride
        )
      case .deleteProfileData:
        remove(
          profile: profile,
          dataRemoval: .delete,
          allowActiveDataOverride: allowOverride
        )
      case .relocateProfileData:
        false
      }
    if !succeeded {
      throw LibraryEditPersistenceFailure(
        message: errorMessage
          ?? String(
            localized:
              "The destructive action did not complete."
          )
      )
    }
  }

  func executeDestructiveActionAsync(
    _ authorization: DestructiveActionExecutionAuthorization
  ) async throws {
    guard
      let appIndex = applications.firstIndex(where: {
        $0.id == authorization.applicationID
          && $0.storageID
            == authorization.applicationStorageID
      }),
      let profileIndex =
        applications[appIndex].profiles.firstIndex(where: {
          $0.id == authorization.profileID
            && $0.storageID
              == authorization.profileStorageID
        })
    else {
      throw DestructiveActionRequestError(.targetRemoved)
    }
    let application = applications[appIndex]
    let profile = application.profiles[profileIndex]
    selectedApplicationID = application.id
    selectedProfileID = profile.id
    let allowOverride = authorization.usedExpertOverride

    guard
      canMutateProfile(
        application,
        profile: profile,
        allowActiveDataOverride: allowOverride
      )
    else {
      throw LibraryEditPersistenceFailure(
        message: errorMessage
          ?? String(localized: "The profile cannot be changed.")
      )
    }

    switch authorization.operation {
    case .clearProfileData:
      guard
        profileDataTransactions != nil,
        repository != nil,
        libraryVersionToken != nil
      else {
        guard
          clearProfileData(
            for: application,
            profile: profile,
            allowActiveDataOverride: allowOverride
          )
        else {
          throw LibraryEditPersistenceFailure(
            message: errorMessage
              ?? String(localized: "The profile data could not be cleared.")
          )
        }
        return
      }
      guard
        let outcome = await executeProfileDataTransactionAsync(
          operation: .clear,
          application: application,
          sourceProfile: profile,
          destinationProfile: nil,
          candidate: applications,
          selectedProfileID: selectedProfileID,
          externalDataHandling: .notConfigured
        )
      else {
        throw LibraryEditPersistenceFailure(
          message: errorMessage
            ?? String(localized: "The profile data could not be cleared.")
        )
      }
      launchStatusMessage =
        outcome.dataMutation == .archivedManagedData
        ? String(localized: "Archived and cleared data for \(profile.name)")
        : String(localized: "No data exists to clear for \(profile.name)")

    case .duplicateProfileData:
      let copyName = Self.uniqueProfileName(
        basedOn: String(localized: "\(profile.name) Copy"),
        existingProfiles: application.profiles
      )
      var copy = profile.duplicatedWithFreshIdentity(name: copyName)
      copy = try applyingRecommendedSettings(
        to: copy,
        for: application,
        replacingExistingIsolation: true
      )
      var candidate = applications
      candidate[appIndex].profiles.append(copy)
      guard
        let outcome = await executeProfileDataTransactionAsync(
          operation: .duplicate,
          application: application,
          sourceProfile: profile,
          destinationProfile: copy,
          candidate: candidate,
          selectedProfileID: copy.id,
          externalDataHandling: externalDataHandling(for: profile)
        )
      else {
        throw LibraryEditPersistenceFailure(
          message: errorMessage
            ?? String(localized: "The profile could not be duplicated.")
        )
      }
      let hasExternalConfiguration: Bool
      if case .configurationOnly = outcome.externalDataHandling {
        hasExternalConfiguration = true
      } else {
        hasExternalConfiguration = false
      }
      switch (outcome.dataMutation, hasExternalConfiguration) {
      case (.copiedManagedData, true):
        launchStatusMessage = String(
          localized:
            "Copied managed profile data to \(copy.name). Explicit external data locations were not copied."
        )
      case (.copiedManagedData, false):
        launchStatusMessage = String(
          localized: "Copied managed profile data to \(copy.name)."
        )
      case (.noManagedData, true):
        launchStatusMessage = String(
          localized:
            "Duplicated the configuration as \(copy.name). No managed data existed to copy, and explicit external data locations were not copied."
        )
      case (.noManagedData, false):
        launchStatusMessage = String(
          localized:
            "Duplicated the configuration as \(copy.name). No managed data existed to copy."
        )
      default:
        launchStatusMessage = String(
          localized: "Duplicated the profile configuration as \(copy.name)."
        )
      }

    case .archiveProfileData, .deleteProfileData:
      var candidate = applications
      candidate[appIndex].profiles.remove(at: profileIndex)
      let candidateProfileID = candidate[appIndex].profiles.first?.id
      let operation: ProfileDataTransactionOperation =
        authorization.operation == .archiveProfileData
        ? .archive : .delete
      guard
        await executeProfileDataTransactionAsync(
          operation: operation,
          application: application,
          sourceProfile: profile,
          destinationProfile: nil,
          candidate: candidate,
          selectedProfileID: candidateProfileID,
          externalDataHandling: .notConfigured
        ) != nil
      else {
        recoverProfileDataTransactionsAfterRemovalFailure()
        prepareRemoveEntryAnywayRecovery(
          application: application,
          profile: profile
        )
        throw LibraryEditPersistenceFailure(
          message: errorMessage
            ?? String(localized: "The profile could not be removed.")
        )
      }
      launchStatusMessage =
        operation == .archive
        ? String(localized: "Archived data for \(profile.name)")
        : String(localized: "Deleted data for \(profile.name)")

    case .removeProfile:
      guard
        remove(
          profile: profile,
          dataRemoval: .keep,
          allowActiveDataOverride: allowOverride
        )
      else {
        throw LibraryEditPersistenceFailure(
          message: errorMessage
            ?? String(localized: "The profile could not be removed.")
        )
      }

    case .relocateProfileData:
      throw LibraryEditPersistenceFailure(
        message: String(localized: "The relocation request is no longer valid.")
      )
    }
  }
}
