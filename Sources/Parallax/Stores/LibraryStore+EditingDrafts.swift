import AppKit
import Foundation
import Observation

extension LibraryStore {
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
}
