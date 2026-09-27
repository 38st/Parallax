import AppKit
import Foundation
import Observation

// MARK: - Profile data and secrets

extension LibraryStore {
  @discardableResult
  func clearProfileData(for application: ManagedApplication, profile: LaunchProfile) -> Bool {
    clearProfileData(
      for: application,
      profile: profile,
      allowActiveDataOverride: false
    )
  }

  @discardableResult
  func clearProfileData(
    for application: ManagedApplication,
    profile: LaunchProfile,
    allowActiveDataOverride: Bool,
    activityPolicy: DataOperationActivityPolicy = .requireInactive
  ) -> Bool {
    guard canMutateLibrary() else { return false }
    guard
      canMutateProfile(
        application,
        profile: profile,
        allowActiveDataOverride: allowActiveDataOverride
      )
    else {
      return false
    }
    errorMessage = nil
    launchStatusMessage = nil

    do {
      if profileDataTransactions != nil,
        repository != nil,
        libraryVersionToken != nil
      {
        guard
          let outcome = executeProfileDataTransaction(
            operation: .clear,
            application: application,
            sourceProfile: profile,
            destinationProfile: nil,
            candidate: applications,
            selectedProfileID: selectedProfileID,
            externalDataHandling: externalDataHandling(for: profile),
            activityPolicy: activityPolicy
          )
        else {
          return false
        }
        launchStatusMessage =
          outcome.dataMutation == .archivedManagedData
          ? String(localized: "Archived and cleared data for \(profile.name)")
          : String(localized: "No data exists to clear for \(profile.name)")
        return true
      }

      let reservation = try reserveProfileData(application: application, profiles: [profile], activityPolicy: activityPolicy)
      defer { reservation.release() }
      let paths = try managedPaths(for: application, profile: profile)
      guard fileSystem.fileExists(at: paths.profileRoot.url) else {
        launchStatusMessage = String(
          localized: "No data exists to clear for \(profile.name)"
        )
        return true
      }
      _ = try moveToArchive(
        source: paths.profileRoot,
        archiveRoot: paths.archiveRoot
      )
      launchStatusMessage = String(localized: "Archived and cleared data for \(profile.name)")
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func duplicateProfileData(
    from source: LaunchProfile,
    to destination: LaunchProfile,
    application: ManagedApplication
  ) -> Bool {
    duplicateProfileData(
      from: source,
      to: destination,
      application: application,
      allowActiveDataOverride: false
    )
  }

  @discardableResult
  func duplicateProfileData(
    from source: LaunchProfile,
    to destination: LaunchProfile,
    application: ManagedApplication,
    allowActiveDataOverride: Bool,
    activityPolicy: DataOperationActivityPolicy = .requireInactive,
    reservation existingReservation: ProfileActivityReservation? = nil
  ) -> Bool {
    guard canMutateLibrary() else { return false }
    guard
      canMutateProfile(
        application,
        profile: source,
        allowActiveDataOverride: allowActiveDataOverride,
        excluding: existingReservation
      )
    else {
      return false
    }
    errorMessage = nil
    launchStatusMessage = nil

    do {
      let reservation = try existingReservation == nil
        ? reserveProfileData(application: application, profiles: [source, destination], activityPolicy: activityPolicy) : nil
      defer { reservation?.release() }
      let sourcePaths = try managedPaths(for: application, profile: source)
      let destinationPaths = try managedPaths(for: application, profile: destination)
      guard !fileSystem.fileExists(at: destinationPaths.profileRoot.url) else {
        throw ProfileDataTransactionError(
          .unexpectedDestination,
          operation: .duplicate,
          path: destinationPaths.profileRoot.url.path
        )
      }
      if fileSystem.fileExists(at: sourcePaths.profileRoot.url) {
        try copyManagedItem(
          at: sourcePaths.profileRoot,
          to: destinationPaths.profileRoot
        )
      } else {
        let destinationURL = try pathResolver.revalidateForMutation(
          destinationPaths.profileRoot
        )
        try fileSystem.createDirectory(
          at: destinationURL,
          withIntermediateDirectories: true
        )
      }
      launchStatusMessage = String(localized: "Copied profile data to \(destination.name)")
      return true
    } catch {
      errorMessage = error.localizedDescription
      if let destinationPaths = try? managedPaths(
        for: application,
        profile: destination
      ), fileSystem.fileExists(at: destinationPaths.profileRoot.url) {
        let copyError =
          errorMessage
          ?? String(localized: "The profile data could not be copied.")
        errorMessage = String(
          localized:
            "\(copyError) Partial data was preserved because its ownership could not be reverified; recovery is required at \(destinationPaths.profileRoot.url.path)."
        )
        loadState = .recoveryRequired(
          originalBytes: nil,
          message: errorMessage ?? copyError
        )
      }
      return false
    }
  }

}
