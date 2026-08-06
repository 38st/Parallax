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
    allowActiveDataOverride: Bool
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
            externalDataHandling: .notConfigured
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
    allowActiveDataOverride: Bool
  ) -> Bool {
    guard canMutateLibrary() else { return false }
    guard
      canMutateProfile(
        application,
        profile: source,
        allowActiveDataOverride: allowActiveDataOverride
      )
    else {
      return false
    }
    errorMessage = nil
    launchStatusMessage = nil

    do {
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

  func useCodexHome(_ url: URL, for profile: LaunchProfile) {
    guard canMutateLibrary() else { return }
    guard
      let appIndex = selectedApplicationIndex,
      let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
    else { return }

    var updated = applications[appIndex].profiles[profileIndex]
    updated.environmentText = Self.settingEnvironmentValue(
      "CODEX_HOME",
      to: url.path,
      in: updated.environmentText
    )
    updated.isolationOwnership.codexHome = .explicit
    var candidate = applications
    candidate[appIndex].profiles[profileIndex] = updated
    _ = commit(
      candidate,
      selectedApplicationID: selectedApplicationID,
      selectedProfileID: updated.id
    )
  }

  func profileDraftUsingCodexHome(
    _ url: URL,
    profile: LaunchProfile
  ) -> LaunchProfile {
    var updated = profile
    updated.environmentText = Self.settingEnvironmentValue(
      "CODEX_HOME",
      to: url.path,
      in: updated.environmentText
    )
    updated.isolationOwnership.codexHome = .explicit
    return updated
  }

  func profileDraftApplyingRecommendedSettings(
    _ profile: LaunchProfile,
    for application: ManagedApplication
  ) -> LaunchProfile? {
    do {
      return try applyingRecommendedSettings(
        to: profile,
        for: application,
        replacingExistingIsolation: false
      )
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func stageKeychainSecret(
    _ secret: String,
    environmentKey: String,
    in profile: LaunchProfile
  ) async -> StagedProfileKeychainSecret? {
    let key = environmentKey.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let validation = LaunchEnvironmentParser.parse("\(key)=")
    guard
      validation.diagnostics.isEmpty,
      validation.entries.first?.name == key
    else {
      errorMessage = String(
        localized:
          "Enter a valid environment variable name."
      )
      return nil
    }
    guard !secret.isEmpty else {
      errorMessage = String(
        localized: "The Keychain secret cannot be empty."
      )
      return nil
    }

    let reference = EnvironmentSecretReference()
    do {
      try await secretStore.store(
        SecretValue(secret),
        for: reference
      )
      var updated = profile
      updated.environmentText = Self.settingEnvironmentValue(
        key,
        to: reference.token,
        in: updated.environmentText
      )
      updated.sensitiveEnvironmentKeys = Array(
        Set(
          updated.sensitiveEnvironmentKeys
            + [key.uppercased()]
        )
      ).sorted()
      updated.isolationOwnership.codexHome =
        key == "CODEX_HOME"
        ? .explicit
        : updated.isolationOwnership.codexHome
      return StagedProfileKeychainSecret(
        profile: updated,
        reference: reference
      )
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func profileDraftRemovingKeychainSecret(
    environmentKey: String,
    from profile: LaunchProfile
  ) -> (
    profile: LaunchProfile,
    reference: EnvironmentSecretReference
  )? {
    let key = environmentKey.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard
      let storedText = LaunchEnvironmentParser.parse(
        profile.environmentText
      ).effectiveValues[key],
      case .secretReference(let reference) =
        StoredEnvironmentValue(storedText: storedText)
    else {
      errorMessage = String(
        localized:
          "This environment value is not a Keychain reference."
      )
      return nil
    }
    var updated = profile
    updated.environmentText = Self.settingEnvironmentValue(
      key,
      to: "",
      in: updated.environmentText
    )
    return (updated, reference)
  }

  @discardableResult
  func discardKeychainSecret(
    _ reference: EnvironmentSecretReference
  ) async -> Bool {
    do {
      try await secretStore.remove(reference)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func applyRecommendedSettings(to profile: LaunchProfile) {
    guard canMutateLibrary() else { return }
    guard
      let appIndex = selectedApplicationIndex,
      let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
    else { return }

    do {
      var candidate = applications
      candidate[appIndex].profiles[profileIndex] = try applyingRecommendedSettings(
        to: profile,
        for: applications[appIndex],
        replacingExistingIsolation: false
      )
      _ = commit(
        candidate,
        selectedApplicationID: selectedApplicationID,
        selectedProfileID: selectedProfileID
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func storeKeychainSecret(
    _ secret: String,
    environmentKey: String,
    for profile: LaunchProfile
  ) async -> Bool {
    guard canMutateLibrary() else { return false }
    let key = environmentKey.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let validation = LaunchEnvironmentParser.parse("\(key)=")
    guard
      validation.diagnostics.isEmpty,
      validation.entries.first?.name == key
    else {
      errorMessage = String(
        localized:
          "Enter a valid environment variable name."
      )
      return false
    }
    guard !secret.isEmpty else {
      errorMessage = String(
        localized: "The Keychain secret cannot be empty."
      )
      return false
    }
    let reference = EnvironmentSecretReference()
    do {
      try await secretStore.store(
        SecretValue(secret),
        for: reference
      )
      guard
        let appIndex = applications.firstIndex(where: {
          $0.profiles.contains { $0.id == profile.id }
        }),
        let profileIndex = applications[appIndex].profiles
          .firstIndex(where: { $0.id == profile.id })
      else {
        try? await secretStore.remove(reference)
        return false
      }
      var candidate = applications
      var updated = candidate[appIndex].profiles[profileIndex]
      updated.environmentText = Self.settingEnvironmentValue(
        key,
        to: reference.token,
        in: updated.environmentText
      )
      updated.sensitiveEnvironmentKeys = Array(
        Set(
          updated.sensitiveEnvironmentKeys
            + [key.uppercased()]
        )
      ).sorted()
      updated.isolationOwnership.codexHome =
        key == "CODEX_HOME"
        ? .explicit
        : updated.isolationOwnership.codexHome
      candidate[appIndex].profiles[profileIndex] = updated
      guard
        commit(
          candidate,
          selectedApplicationID: selectedApplicationID,
          selectedProfileID: selectedProfileID
        )
      else {
        try? await secretStore.remove(reference)
        return false
      }
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func removeKeychainSecret(
    environmentKey: String,
    for profile: LaunchProfile
  ) async -> Bool {
    guard canMutateLibrary() else { return false }
    let key = environmentKey.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard
      let storedText = LaunchEnvironmentParser.parse(
        profile.environmentText
      ).effectiveValues[key],
      case .secretReference(let reference) =
        StoredEnvironmentValue(storedText: storedText)
    else {
      errorMessage = String(
        localized:
          "This environment value is not a Keychain reference."
      )
      return false
    }
    do {
      guard
        let appIndex = applications.firstIndex(where: {
          $0.profiles.contains { $0.id == profile.id }
        }),
        let profileIndex = applications[appIndex].profiles
          .firstIndex(where: { $0.id == profile.id })
      else {
        return false
      }
      var candidate = applications
      var updated = candidate[appIndex].profiles[profileIndex]
      updated.environmentText = Self.settingEnvironmentValue(
        key,
        to: "",
        in: updated.environmentText
      )
      candidate[appIndex].profiles[profileIndex] = updated
      guard
        commit(
          candidate,
          selectedApplicationID: selectedApplicationID,
          selectedProfileID: selectedProfileID
        )
      else {
        return false
      }
      try await secretStore.remove(reference)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
