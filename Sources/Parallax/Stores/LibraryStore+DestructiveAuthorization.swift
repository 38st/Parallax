import AppKit
import Foundation
import Observation

// MARK: - Destructive action authorization

extension LibraryStore {
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
}
