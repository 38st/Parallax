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
    let validation = DisplayNameValidator.validate(profile.name)
    guard let normalizedName = validation.normalized else {
      errorMessage = validation.issue?.message(for: .space)
      return
    }
    var normalizedProfile = profile
    normalizedProfile.name = normalizedName
    var updated = normalizedProfile.preservingIdentity(of: persisted)
    if Self.userDataDirectoryConfiguration(
      in: updated.argumentsText
    )
      != Self.userDataDirectoryConfiguration(
        in: persisted.argumentsText
      )
    {
      updated.isolationOwnership.userData = .explicit
    }
    if Self.environmentConfiguration(
      "CODEX_HOME",
      in: updated.environmentText
    )
      != Self.environmentConfiguration(
        "CODEX_HOME",
        in: persisted.environmentText
      )
    {
      updated.isolationOwnership.codexHome = .explicit
    }
    var candidate = applications
    candidate[appIndex].profiles[profileIndex] = updated
    _ = commit(
      candidate,
      selectedApplicationID: selectedApplicationID,
      selectedProfileID: selectedProfileID
    )
  }
}
