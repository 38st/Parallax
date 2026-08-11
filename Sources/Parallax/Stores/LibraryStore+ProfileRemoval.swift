import AppKit
import Foundation
import Observation

extension LibraryStore {
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
}
