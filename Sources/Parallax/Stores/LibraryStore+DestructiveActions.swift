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
}
