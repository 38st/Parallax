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
    guard acceptsProfileEditingDrafts,
      (!canConfirmProfileRemoval || applications.contains(where: { application in
        application.id == applicationID && application.profiles.contains {
          $0.id == draft.id && $0.storageID == draft.storageID
        }
      }))
    else {
      forgetProfileEditingDraft(profileID: draft.id)
      scheduleKeychainDiscard(stagedKeychainReferences)
      return
    }
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

extension LibraryStore {
  var editorDraftRegistry: ProfileEditorDraftRegistry {
    sceneCoordinator.editorDraftRegistry
  }

  var canConfirmProfileRemoval: Bool {
    guard case .loaded = loadState else { return false }
    // A replacement can temporarily hide rows that Undo will restore.
    if let replacement = lastImportReplacement,
      replacement.snapshot.versionToken == currentLibraryVersion,
      replacement.snapshot.applications == applications
    {
      return false
    }
    return true
  }

  var profileEditingDrafts: [PendingProfileEditingDraft] {
    Array(pendingProfileEditingDrafts.values)
  }

  var acceptsProfileEditingDrafts: Bool {
    !sceneCoordinator.isClosing
  }

  func endProfileEditing() {
    sceneCoordinator.isClosing = true
  }

  func closeProfileEditing() async {
    endProfileEditing()
    await editorDraftRegistry.cancelSecretTasks(for: self)
    await discardProfileEditingDrafts(profileEditingDrafts)
  }

  func discardRemovedProfileEditingDrafts() async {
    guard canConfirmProfileRemoval else { return }
    let removed = profileEditingDrafts.filter { pending in
      !applications.contains { application in
        application.id == pending.applicationID && application.profiles.contains {
          $0.id == pending.draft.id && $0.storageID == pending.draft.storageID
        }
      }
    }
    await discardProfileEditingDrafts(removed)
  }
}
