import AppKit
import Foundation
import Observation

extension LibraryStore {
  func updateApplication(_ application: ManagedApplication) {
    guard canMutateLibrary() else { return }
    guard let index = applications.firstIndex(where: { $0.id == application.id }) else { return }
    let persisted = applications[index]
    guard application != persisted else { return }
    let validation = DisplayNameValidator.validate(
      application.displayName
    )
    guard let normalizedName = validation.normalized else {
      errorMessage = validation.issue?.message(for: .application)
      return
    }
    var normalizedApplication = application
    normalizedApplication.displayName = normalizedName
    var updated = normalizedApplication.preservingIdentity(of: persisted)
    // Ordinary metadata edits never imply storage relocation.
    updated.baseStoragePath = persisted.baseStoragePath
    let invalidatesImportedApproval =
      updated.appPath != persisted.appPath
      || updated.bundleIdentifier
        != persisted.bundleIdentifier
      || updated.baseStoragePath != persisted.baseStoragePath
    var consumedPersistedProfileIDs = Set<LaunchProfile.ID>()
    var validatedProfiles: [LaunchProfile] = []
    validatedProfiles.reserveCapacity(updated.profiles.count)
    for proposed in updated.profiles {
      let persistedProfile = persisted.profiles.first(where: {
        $0.id == proposed.id
      })
      let isExisting = persistedProfile.map {
        consumedPersistedProfileIDs.insert($0.id).inserted
      } ?? false

      guard isExisting, let persistedProfile else {
        let validation = DisplayNameValidator.validate(proposed.name)
        guard let normalizedName = validation.normalized else {
          errorMessage = validation.issue?.message(for: .space)
          return
        }
        var normalized = proposed
        normalized.name = normalizedName
        validatedProfiles.append(
          normalized.duplicatedWithFreshIdentity()
        )
        continue
      }

      var normalized = proposed
      if proposed != persistedProfile {
        let validation = DisplayNameValidator.validate(proposed.name)
        guard let normalizedName = validation.normalized else {
          errorMessage = validation.issue?.message(for: .space)
          return
        }
        normalized.name = normalizedName
      }
      var preserved = normalized.preservingIdentity(
        of: persistedProfile
      )
      if invalidatesImportedApproval,
        preserved.launchConfigurationTrust.isImported
      {
        preserved.markLaunchConfigurationImported()
      }
      validatedProfiles.append(preserved)
    }
    updated.profiles = validatedProfiles
    var candidate = applications
    candidate[index] = updated
    _ = commit(
      candidate,
      selectedApplicationID: selectedApplicationID,
      selectedProfileID: selectedProfileID
    )
  }

  func updateProfile(_ profile: LaunchProfile) {
    guard canMutateLibrary() else { return }
    guard
      let appIndex = selectedApplicationIndex,
      let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
    else { return }
    let persisted = applications[appIndex].profiles[profileIndex]
    guard profile != persisted else { return }
    var updated = profile.preservingIdentity(of: persisted)
    let validation = DisplayNameValidator.validate(profile.name)
    guard let normalizedName = validation.normalized else {
      errorMessage = validation.issue?.message(for: .space)
      return
    }
    if profile.name != persisted.name {
      updated.name = normalizedName
    }
    updated = profileApplyingEditedIsolationOwnership(
      updated, baseline: persisted, application: applications[appIndex]
    )
    var candidate = applications
    candidate[appIndex].profiles[profileIndex] = updated
    _ = commit(
      candidate,
      selectedApplicationID: selectedApplicationID,
      selectedProfileID: selectedProfileID
    )
  }

  func profileApplyingEditedIsolationOwnership(
    _ draft: LaunchProfile,
    baseline: LaunchProfile,
    application: ManagedApplication
  ) -> LaunchProfile {
    var updated = draft
    let changedUserData =
      draft.isolationOwnership.userData
        == baseline.isolationOwnership.userData
      && Self.userDataDirectoryConfiguration(in: draft.argumentsText)
        != Self.userDataDirectoryConfiguration(in: baseline.argumentsText)
    let changedCodexHome =
      draft.isolationOwnership.codexHome
        == baseline.isolationOwnership.codexHome
      && Self.environmentConfiguration("CODEX_HOME", in: draft.environmentText)
        != Self.environmentConfiguration("CODEX_HOME", in: baseline.environmentText)
    guard changedUserData || changedCodexHome else { return updated }
    let paths = try? managedPaths(for: application, profile: baseline)
    if changedUserData {
      let resolution = Self.userDataDirectoryResolution(in: draft.argumentsText)
      if let value = resolution.resolvedValue {
        updated.isolationOwnership.userData =
          value == paths?.userData.url.path ? .generated : .explicit
      } else if resolution.occurrences.isEmpty
        || (resolution.occurrences.count == 1
          && resolution.occurrences.first?.value
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true)
      {
        updated.isolationOwnership.userData = .generated
      }
    }
    if changedCodexHome {
      if let value = Self.environmentValue("CODEX_HOME", in: draft),
        case .literal = StoredEnvironmentValue(storedText: value)
      {
        updated.isolationOwnership.codexHome =
          value == paths?.codexHome.url.path ? .generated : .explicit
      } else if Self.environmentValue("CODEX_HOME", in: draft) == nil {
        updated.isolationOwnership.codexHome = .generated
      }
    }
    return updated
  }
}
