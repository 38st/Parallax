import AppKit
import Foundation
import Observation

// MARK: - Profile lifecycle

extension LibraryStore {
  func addProfile() {
    addProfile(
      named: Self.nextProfileName(for: selectedApplication, templates: profileTemplateNames))
  }

  func addProfile(named name: String) {
    guard canMutateLibrary() else { return }
    guard let index = selectedApplicationIndex else { return }
    let template = profileTemplates.first { $0.name == name }
    _ = addProfile(
      named: name,
      template: template,
      applicationIndex: index
    )
  }

  func addProfile(templateID: ProfileTemplate.ID) {
    guard canMutateLibrary() else { return }
    guard
      let index = selectedApplicationIndex,
      let template = profileTemplates.first(where: {
        $0.id == templateID
      })
    else {
      errorMessage = String(
        localized:
          "The selected space template no longer exists."
      )
      return
    }
    _ = addProfile(
      named: template.name,
      template: template,
      applicationIndex: index
    )
  }

  @discardableResult
  func createSpace(
    named name: String,
    templateID: ProfileTemplate.ID?,
    applicationID: ManagedApplication.ID
  ) -> LaunchProfile? {
    guard canMutateLibrary() else { return nil }
    guard
      let index = applications.firstIndex(where: {
        $0.id == applicationID
      })
    else {
      errorMessage = String(
        localized:
          "The selected app no longer exists. Your space was not created."
      )
      return nil
    }
    let trimmedName = name.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !trimmedName.isEmpty else {
      errorMessage = String(
        localized: "Enter a name for this space."
      )
      return nil
    }
    let template: ProfileTemplate?
    if let templateID {
      guard
        let resolved = profileTemplates.first(where: {
          $0.id == templateID
        })
      else {
        errorMessage = String(
          localized:
            "The selected space template no longer exists. Choose another option."
        )
        return nil
      }
      template = resolved
    } else {
      template = nil
    }
    return addProfile(
      named: trimmedName,
      template: template,
      applicationIndex: index
    )
  }

  @discardableResult
  func addProfile(
    named name: String,
    template: ProfileTemplate?,
    applicationIndex index: Int
  ) -> LaunchProfile? {
    let profileName = Self.uniqueProfileName(
      basedOn: name,
      existingProfiles: applications[index].profiles
    )
    let profile: LaunchProfile
    do {
      profile = try self.profile(
        named: profileName,
        template: template,
        for: applications[index]
      )
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
    var candidate = applications
    candidate[index].profiles.append(profile)
    guard
      commit(
        candidate,
        selectedApplicationID: selectedApplicationID,
        selectedProfileID: profile.id
      )
    else {
      return nil
    }
    return profile
  }

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
    let copyName = Self.uniqueProfileName(
      basedOn: String(localized: "\(profile.name) Copy"),
      existingProfiles: applications[appIndex].profiles
    )
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

  @discardableResult
  func removeSelectedProfile(dataRemoval: ProfileDataRemoval = .keep) -> Bool {
    guard
      let selectedProfile = selectedProfile
    else { return false }

    return remove(profile: selectedProfile, dataRemoval: dataRemoval)
  }

  @discardableResult
  func remove(profile: LaunchProfile, dataRemoval: ProfileDataRemoval) -> Bool {
    remove(
      profile: profile,
      dataRemoval: dataRemoval,
      allowActiveDataOverride: false
    )
  }

  @discardableResult
  func remove(
    profile: LaunchProfile,
    dataRemoval: ProfileDataRemoval,
    allowActiveDataOverride: Bool
  ) -> Bool {
    guard canMutateLibrary() else { return false }
    guard
      let appIndex = selectedApplicationIndex,
      let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
    else { return false }

    let application = applications[appIndex]
    let profileToRemove = applications[appIndex].profiles[profileIndex]
    guard
      canMutateProfile(
        application,
        profile: profileToRemove,
        allowActiveDataOverride: allowActiveDataOverride
      )
    else {
      return false
    }
    pendingProfileRemovalRecovery = nil
    var archivedMove:
      (
        source: ManagedProfileRootPath,
        destination: ManagedArchiveEntryPath
      )?
    errorMessage = nil
    launchStatusMessage = nil

    var candidate = applications
    candidate[appIndex].profiles.remove(at: profileIndex)
    let candidateSelectedProfileID = candidate[appIndex].profiles.first?.id
    if dataRemoval != .keep,
      profileDataTransactions != nil,
      repository != nil,
      libraryVersionToken != nil
    {
      let operation: ProfileDataTransactionOperation =
        switch dataRemoval {
        case .archive:
          .archive
        case .delete:
          .delete
        case .keep:
          preconditionFailure("Metadata-only removal is not a data transaction")
        }
      guard
        executeProfileDataTransaction(
          operation: operation,
          application: application,
          sourceProfile: profileToRemove,
          destinationProfile: nil,
          candidate: candidate,
          selectedProfileID: candidateSelectedProfileID,
          externalDataHandling: .notConfigured
        ) != nil
      else {
        recoverProfileDataTransactionsAfterRemovalFailure()
        prepareRemoveEntryAnywayRecovery(
          application: application,
          profile: profileToRemove
        )
        return false
      }
      launchStatusMessage =
        dataRemoval == .archive
        ? String(localized: "Archived data for \(profileToRemove.name)")
        : String(localized: "Deleted data for \(profileToRemove.name)")
      return true
    }

    do {
      switch dataRemoval {
      case .keep:
        break
      case .archive:
        let source = try managedPaths(
          for: application,
          profile: profileToRemove
        ).profileRoot
        if let destination = try archiveProfileData(
          for: application,
          profile: profileToRemove
        ) {
          archivedMove = (source, destination)
        }
      case .delete:
        let source = try managedPaths(
          for: application,
          profile: profileToRemove
        ).profileRoot
        if let destination = try archiveProfileData(
          for: application,
          profile: profileToRemove
        ) {
          archivedMove = (source, destination)
        }
      }
    } catch {
      errorMessage = error.localizedDescription
      prepareRemoveEntryAnywayRecovery(
        application: application,
        profile: profileToRemove
      )
      return false
    }

    guard
      commit(
        candidate,
        selectedApplicationID: selectedApplicationID,
        selectedProfileID: candidateSelectedProfileID,
        backupReason: dataRemoval == .keep
          ? .destructiveRewrite
          : nil
      )
    else {
      if let archivedMove {
        do {
          try moveManagedItem(
            at: archivedMove.destination,
            to: archivedMove.source
          )
        } catch {
          let persistenceError =
            errorMessage ?? String(localized: "The library could not be saved.")
          errorMessage = String(
            localized:
              "\(persistenceError) The archived profile data could not be restored: \(error.localizedDescription)"
          )
        }
      }
      return false
    }

    switch dataRemoval {
    case .keep:
      break
    case .archive:
      launchStatusMessage = String(localized: "Archived data for \(profileToRemove.name)")
    case .delete:
      if let archivedMove {
        do {
          try removeManagedItem(at: archivedMove.destination)
        } catch {
          errorMessage = String(
            localized:
              "The profile entry was removed, but its transaction-owned data requires recovery at \(archivedMove.destination.url.path): \(error.localizedDescription)"
          )
          loadState = .recoveryRequired(
            originalBytes: nil,
            message: errorMessage ?? error.localizedDescription
          )
          return false
        }
      }
      launchStatusMessage = String(localized: "Deleted data for \(profileToRemove.name)")
    }
    return true
  }

  func dismissProfileRemovalRecovery() {
    pendingProfileRemovalRecovery = nil
  }

  @discardableResult
  func removeEntryAnyway(
    _ recovery: ProfileRemovalRecovery
  ) -> Bool {
    guard canMutateLibrary() else { return false }
    guard
      pendingProfileRemovalRecovery == recovery,
      libraryVersionToken == recovery.expectedVersion,
      let appIndex = applications.firstIndex(where: {
        $0.id == recovery.applicationID
          && $0.storageID == recovery.applicationStorageID
      }),
      let profileIndex = applications[appIndex].profiles
        .firstIndex(where: {
          $0.id == recovery.profileID
            && $0.storageID == recovery.profileStorageID
        })
    else {
      pendingProfileRemovalRecovery = nil
      errorMessage = String(
        localized:
          "The failed profile removal is stale. Review the current profile and data location before trying again."
      )
      return false
    }

    var candidate = applications
    let profile = candidate[appIndex].profiles.remove(
      at: profileIndex
    )
    let nextProfileID = candidate[appIndex].profiles.first?.id
    guard
      commit(
        candidate,
        selectedApplicationID: recovery.applicationID,
        selectedProfileID: nextProfileID,
        backupReason: .destructiveRewrite
      )
    else {
      return false
    }
    pendingProfileRemovalRecovery = nil
    errorMessage = nil
    launchStatusMessage = String(
      localized:
        "Removed \(profile.name) from the library. Its remaining data was kept at \(recovery.canonicalRemainingDataPath)."
    )
    return true
  }

  func prepareRemoveEntryAnywayRecovery(
    application: ManagedApplication,
    profile: LaunchProfile
  ) {
    guard
      case .loaded = loadState,
      let libraryVersionToken,
      applications.contains(where: { currentApplication in
        currentApplication.id == application.id
          && currentApplication.storageID
            == application.storageID
          && currentApplication.profiles.contains(where: {
            $0.id == profile.id
              && $0.storageID == profile.storageID
          })
      }),
      let path = try? managedPaths(
        for: application,
        profile: profile
      ).profileRoot.url.path
    else {
      return
    }
    pendingProfileRemovalRecovery = ProfileRemovalRecovery(
      profileName: profile.name,
      canonicalRemainingDataPath: path,
      applicationID: application.id,
      applicationStorageID: application.storageID,
      profileID: profile.id,
      profileStorageID: profile.storageID,
      expectedVersion: libraryVersionToken
    )
  }

  func recoverProfileDataTransactionsAfterRemovalFailure() {
    guard
      let profileDataTransactions,
      let repository
    else { return }
    let operationMessage = errorMessage
    let priorApplicationID = selectedApplicationID
    let priorProfileID = selectedProfileID
    do {
      for transaction
        in try profileDataTransactions
        .pendingTransactions()
      {
        _ = try profileDataTransactions.recover(
          transactionID: transaction.transactionID,
          repository: repository
        )
      }
      guard case .loaded(let snapshot) = repository.load() else {
        return
      }
      applications = snapshot.applications
      libraryVersionToken = snapshot.versionToken
      selectedApplicationID =
        applications.contains {
          $0.id == priorApplicationID
        } ? priorApplicationID : applications.first?.id
      selectedProfileID =
        applications.first(where: {
          $0.id == selectedApplicationID
        })?.profiles.contains(where: {
          $0.id == priorProfileID
        }) == true
        ? priorProfileID
        : applications.first(where: {
          $0.id == selectedApplicationID
        })?.profiles.first?.id
      loadState = .loaded
      errorMessage = operationMessage
      publishLibraryChange()
    } catch {
      let recoveryMessage = String(
        localized:
          "\(operationMessage ?? "Profile removal failed.") Recovery could not finish: \(error.localizedDescription)"
      )
      errorMessage = recoveryMessage
      let originalBytes: Data? =
        switch repository.load() {
        case .loaded(let snapshot):
          snapshot.originalBytes
        case .recoveryRequired(let failure),
          .readOnly(let failure):
          failure.originalBytes
        case .migrationRequired(let snapshot):
          snapshot.originalBytes
        case .missing:
          nil
        }
      loadState = .recoveryRequired(
        originalBytes: originalBytes,
        message: recoveryMessage
      )
    }
  }

  func updateApplication(_ application: ManagedApplication) {
    guard canMutateLibrary() else { return }
    guard let index = applications.firstIndex(where: { $0.id == application.id }) else { return }
    let persisted = applications[index]
    var updated = application.preservingIdentity(of: persisted)
    // Ordinary metadata edits never imply storage relocation.
    updated.baseStoragePath = persisted.baseStoragePath
    let invalidatesImportedApproval =
      updated.appPath != persisted.appPath
      || updated.bundleIdentifier
        != persisted.bundleIdentifier
      || updated.baseStoragePath != persisted.baseStoragePath
    var consumedPersistedProfileIDs = Set<LaunchProfile.ID>()
    updated.profiles = updated.profiles.map { proposed in
      guard
        let persistedProfile = persisted.profiles.first(where: { $0.id == proposed.id }),
        consumedPersistedProfileIDs.insert(persistedProfile.id).inserted
      else {
        return proposed.duplicatedWithFreshIdentity()
      }
      var preserved = proposed.preservingIdentity(
        of: persistedProfile
      )
      if invalidatesImportedApproval,
        preserved.launchConfigurationTrust.isImported
      {
        preserved.markLaunchConfigurationImported()
      }
      return preserved
    }
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
    var updated = profile.preservingIdentity(of: persisted)
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
