import AppKit
import Foundation
import Observation

extension LibraryStore {
  @discardableResult
  func duplicateSelectedProfile() -> Bool {
    duplicateSelectedProfile(allowActiveDataOverride: false)
  }

  @discardableResult
  func duplicateSelectedProfile(
    allowActiveDataOverride: Bool
  ) -> Bool {
    guard canMutateLibrary() else { return false }
    guard
      let appIndex = selectedApplicationIndex,
      let profile = selectedProfile
    else { return false }
    guard
      canMutateProfile(
        applications[appIndex],
        profile: profile,
        allowActiveDataOverride: allowActiveDataOverride
      )
    else {
      return false
    }
    guard let copyName = Self.duplicateProfileName(
      basedOn: profile.name,
      existingProfiles: applications[appIndex].profiles
    ) else {
      errorMessage = String(
        localized:
          "Parallax could not create a unique valid space name."
      )
      return false
    }
    var copy = profile.duplicatedWithFreshIdentity(name: copyName)
    do {
      copy = try applyingRecommendedSettings(
        to: copy,
        for: applications[appIndex],
        replacingExistingIsolation: true
      )
    } catch {
      errorMessage = error.localizedDescription
      return false
    }

    var candidate = applications
    candidate[appIndex].profiles.append(copy)
    if profileDataTransactions != nil,
      repository != nil,
      libraryVersionToken != nil
    {
      guard
        let outcome = executeProfileDataTransaction(
          operation: .duplicate,
          application: applications[appIndex],
          sourceProfile: profile,
          destinationProfile: copy,
          candidate: candidate,
          selectedProfileID: copy.id,
          externalDataHandling: externalDataHandling(for: profile)
        )
      else {
        return false
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
      return true
    }

    guard
      duplicateProfileData(
        from: profile,
        to: copy,
        application: applications[appIndex],
        allowActiveDataOverride: allowActiveDataOverride
      )
    else { return false }
    guard
      commit(
        candidate,
        selectedApplicationID: selectedApplicationID,
        selectedProfileID: copy.id
      )
    else {
      if let destinationPaths = try? managedPaths(
        for: applications[appIndex],
        profile: copy
      ), fileSystem.fileExists(at: destinationPaths.profileRoot.url) {
        let persistenceError =
          errorMessage
          ?? String(localized: "The library could not be saved.")
        errorMessage = String(
          localized:
            "\(persistenceError) Copied data was preserved because its ownership could not be reverified; recovery is required at \(destinationPaths.profileRoot.url.path)."
        )
        loadState = .recoveryRequired(
          originalBytes: nil,
          message: errorMessage ?? persistenceError
        )
      }
      launchStatusMessage = nil
      return false
    }
    return true
  }
}
