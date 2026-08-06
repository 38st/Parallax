import SwiftUI
import UniformTypeIdentifiers

// MARK: - Draft lifecycle

extension ProfileEditorView {
  @discardableResult
  func applyDraft() -> LaunchProfile? {
    guard
      store.applyProfileEdit(
        draft: draft,
        baseline: baseline,
        applicationID: application.id,
        baselineVersion: baselineVersion
      )
    else {
      return nil
    }
    guard
      let persistedApplication =
        store.applications.first(where: {
          $0.id == application.id
        }),
      let persisted = persistedApplication.profiles.first(where: {
        $0.id == profile.id
      })
    else {
      return nil
    }
    draft = persisted
    baseline = persisted
    baselineVersion =
      store.currentLibraryVersion ?? baselineVersion
    let retainedReferences = keychainReferences(in: persisted)
    let obsoleteStaged =
      stagedKeychainReferences.subtracting(retainedReferences)
    let referencesToDelete =
      pendingKeychainDeletionReferences.union(obsoleteStaged)
    stagedKeychainReferences = []
    pendingKeychainDeletionReferences = []
    store.forgetProfileEditingDraft(profileID: persisted.id)
    discardKeychainReferences(referencesToDelete)
    return persisted
  }

  func saveAndOpen() {
    SpaceEditorWorkflow.saveAndOpen(
      draft: draft,
      baseline: baseline,
      save: applyDraft,
      open: store.launch
    )
  }

  func revertDraft() {
    let staged = stagedKeychainReferences
    stagedKeychainReferences = []
    pendingKeychainDeletionReferences = []
    draft = baseline
    store.forgetProfileEditingDraft(profileID: profile.id)
    discardKeychainReferences(staged)
  }

  func rememberDraft() {
    store.rememberProfileEditingDraft(
      applicationID: application.id,
      draft: draft,
      baseline: baseline,
      baselineVersion: baselineVersion,
      stagedKeychainReferences: stagedKeychainReferences,
      pendingKeychainDeletionReferences:
        pendingKeychainDeletionReferences
    )
  }

  func discardKeychainReferences(
    _ references: Set<EnvironmentSecretReference>
  ) {
    guard !references.isEmpty else { return }
    Task {
      for reference in references {
        _ = await store.discardKeychainSecret(reference)
      }
    }
  }

  func keychainReferences(
    in profile: LaunchProfile
  ) -> Set<EnvironmentSecretReference> {
    Set(
      LaunchEnvironmentParser.parse(profile.environmentText)
        .effectiveValues.values.compactMap {
          EnvironmentSecretReference(token: $0)
        }
    )
  }
}
