import AppKit
import Foundation
import Observation

// MARK: - Destructive action execution

extension LibraryStore {
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
      guard let copyName = Self.duplicateProfileName(
        basedOn: profile.name,
        existingProfiles: application.profiles
      ) else {
        throw LibraryEditPersistenceFailure(
          message: String(
            localized:
              "Parallax could not create a unique valid space name."
          )
        )
      }
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
