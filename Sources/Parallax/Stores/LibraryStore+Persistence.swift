import AppKit
import Foundation
import Observation

// MARK: - Persistence integration

extension LibraryStore {
  func load() {
    loadState = .loading
    if let repository {
      load(from: repository)
      return
    }

    do {
      switch try persistence.loadResult() {
      case .current(let loaded):
        try LibraryPersistence.validateCurrentApplications(loaded)
        migrationRequiredLibrary = nil
        applications = loaded
        selectedApplicationID = applications.first?.id
        selectedProfileID = applications.first?.profiles.first?.id
        loadState = .loaded
      case .migrationRequired(let legacy):
        migrationRequiredLibrary = legacy
        applications = []
        selectedApplicationID = nil
        selectedProfileID = nil
        errorMessage =
          LibraryPersistenceError
          .migrationRequired(format: legacy.format)
          .localizedDescription
        loadState = .recoveryRequired(
          originalBytes: nil,
          message: errorMessage ?? String(localized: "Library migration is required.")
        )
      }
    } catch {
      AppLog.persistence.error("Failed to load library: \(error.localizedDescription)")
      applications = []
      selectedApplicationID = nil
      selectedProfileID = nil
      errorMessage = error.localizedDescription
      if case LibraryPersistenceError.unsupportedVersion(let found, let supported) = error {
        loadState = .unsupportedNewerVersion(
          originalBytes: nil,
          message: String(
            localized: "The library uses format v\(found), but this build supports v\(supported)."
          )
        )
      } else {
        loadState = .unrecoverable(
          originalBytes: nil,
          message: error.localizedDescription
        )
      }
    }
  }

  func load(
    from repository: any LibraryRepositoryPersisting,
    recoveryPass: Int = 0
  ) {
    guard recoveryPass <= 4 else {
      let error =
        LibraryStoreInfrastructureError
        .startupRecoveryDidNotConverge
      applications = []
      selectedApplicationID = nil
      selectedProfileID = nil
      libraryVersionToken = nil
      errorMessage = error.localizedDescription
      loadState = .recoveryRequired(
        originalBytes: nil,
        message: error.localizedDescription
      )
      return
    }
    switch repository.load() {
    case .missing:
      applications = []
      selectedApplicationID = nil
      selectedProfileID = nil
      libraryVersionToken = .missing
      migrationRequiredLibrary = nil
      loadState = .loaded
    case .loaded(let snapshot):
      if let storageRelocationCoordinator {
        do {
          let pending =
            try storageRelocationCoordinator.pendingRelocations()
          if !pending.isEmpty {
            _ = try storageRelocationCoordinator.recoverAll(
              repository: repository
            )
            load(
              from: repository,
              recoveryPass: recoveryPass + 1
            )
            return
          }
        } catch {
          applications = []
          selectedApplicationID = nil
          selectedProfileID = nil
          libraryVersionToken = nil
          errorMessage = error.localizedDescription
          loadState = .recoveryRequired(
            originalBytes: snapshot.originalBytes,
            message: error.localizedDescription
          )
          return
        }
      }
      if let profileDataTransactions {
        do {
          let pending = try profileDataTransactions.pendingTransactions()
          if !pending.isEmpty {
            for transaction in pending {
              _ = try profileDataTransactions.recover(
                transactionID: transaction.transactionID,
                repository: repository
              )
            }
            load(
              from: repository,
              recoveryPass: recoveryPass + 1
            )
            return
          }
        } catch {
          applications = []
          selectedApplicationID = nil
          selectedProfileID = nil
          libraryVersionToken = nil
          errorMessage = error.localizedDescription
          loadState = .recoveryRequired(
            originalBytes: snapshot.originalBytes,
            message: error.localizedDescription
          )
          return
        }
      }
      if let applicationRemovalTransactions {
        do {
          let pending =
            try applicationRemovalTransactions
            .pendingTransactions()
          if !pending.isEmpty {
            for transactionID in pending {
              _ =
                try applicationRemovalTransactions
                .recover(
                  transactionID: transactionID,
                  repository: repository
                )
            }
            load(
              from: repository,
              recoveryPass: recoveryPass + 1
            )
            return
          }
        } catch {
          applications = []
          selectedApplicationID = nil
          selectedProfileID = nil
          libraryVersionToken = nil
          errorMessage = error.localizedDescription
          loadState = .recoveryRequired(
            originalBytes: snapshot.originalBytes,
            message: error.localizedDescription
          )
          return
        }
      }
      applications = snapshot.applications
      selectedApplicationID = applications.first?.id
      selectedProfileID = applications.first?.profiles.first?.id
      libraryVersionToken = snapshot.versionToken
      migrationRequiredLibrary = nil
      loadState = .loaded
    case .migrationRequired(let snapshot):
      do {
        switch try persistence.loadResult() {
        case .current:
          load(
            from: repository,
            recoveryPass: recoveryPass + 1
          )
        case .migrationRequired(let legacy):
          migrationRequiredLibrary = legacy
          applications = []
          selectedApplicationID = nil
          selectedProfileID = nil
          libraryVersionToken = nil
          let error =
            LibraryPersistenceError.migrationRequired(
              format: legacy.format
            )
          errorMessage = error.localizedDescription
          loadState = .recoveryRequired(
            originalBytes: snapshot.originalBytes,
            message: error.localizedDescription
          )
        }
      } catch {
        migrationRequiredLibrary = snapshot.library
        applications = []
        selectedApplicationID = nil
        selectedProfileID = nil
        errorMessage = error.localizedDescription
        loadState = .recoveryRequired(
          originalBytes: snapshot.originalBytes,
          message: error.localizedDescription
        )
      }
    case .recoveryRequired(let failure):
      applications = []
      selectedApplicationID = nil
      selectedProfileID = nil
      libraryVersionToken = nil
      errorMessage = failure.error.localizedDescription
      loadState = .recoveryRequired(
        originalBytes: failure.originalBytes,
        message: failure.error.localizedDescription
      )
    case .readOnly(let failure):
      applications = []
      selectedApplicationID = nil
      selectedProfileID = nil
      libraryVersionToken = nil
      errorMessage = failure.error.localizedDescription
      loadState = .unsupportedNewerVersion(
        originalBytes: failure.originalBytes,
        message: failure.error.localizedDescription
      )
    }
  }

  /// Refreshes a peer scene after another window commits to the shared
  /// repository. Window-local selection and presentation state are retained
  /// when their immutable targets still exist.
  func reloadFromSharedRepository() {
    guard let repository else { return }
    let applicationID = selectedApplicationID
    let profileID = selectedProfileID
    switch repository.load() {
    case .loaded(let snapshot):
      applications = snapshot.applications
      libraryVersionToken = snapshot.versionToken
      selectedApplicationID =
        applications.contains {
          $0.id == applicationID
        } ? applicationID : nil
      if let selectedApplication = applications.first(where: {
        $0.id == selectedApplicationID
      }),
        selectedApplication.profiles.contains(where: {
          $0.id == profileID
        })
      {
        selectedProfileID = profileID
      } else {
        selectedProfileID = nil
      }
      loadState = .loaded
    case .missing:
      applications = []
      selectedApplicationID = nil
      selectedProfileID = nil
      libraryVersionToken = .missing
      loadState = .loaded
    case .migrationRequired, .recoveryRequired, .readOnly:
      // The full load path owns migration and recovery presentation.
      load()
    }
  }

  func publishLibraryChange() {
    libraryChangeBroadcaster?.publish(sourceSceneID: sceneID)
  }

  func persistApplicationEdit(
    _ application: ManagedApplication,
    expectedVersion: LibraryVersionToken
  ) throws -> (
    persisted: ManagedApplication,
    version: LibraryVersionToken
  ) {
    guard
      let repository,
      let index = applications.firstIndex(where: {
        $0.id == application.id
          && $0.storageID == application.storageID
      })
    else {
      throw LibraryEditPersistenceFailure(
        message: String(
          localized:
            "Application edit persistence is unavailable."
        )
      )
    }
    var candidate = applications
    candidate[index] = application
    let snapshot = try repository.save(
      candidate,
      expectedVersion: expectedVersion
    )
    applications = snapshot.applications
    libraryVersionToken = snapshot.versionToken
    sceneCoordinator.synchronize(with: applications)
    loadState = .loaded
    publishLibraryChange()
    return (
      applications[index],
      snapshot.versionToken
    )
  }

  func persistProfileEdit(
    _ profile: LaunchProfile,
    applicationID: UUID,
    expectedVersion: LibraryVersionToken
  ) throws -> (
    persisted: LaunchProfile,
    version: LibraryVersionToken
  ) {
    guard
      let repository,
      let applicationIndex = applications.firstIndex(where: {
        $0.id == applicationID
      }),
      let profileIndex = applications[applicationIndex]
        .profiles.firstIndex(where: {
          $0.id == profile.id
            && $0.storageID == profile.storageID
        })
    else {
      throw LibraryEditPersistenceFailure(
        message: String(
          localized:
            "Profile edit persistence is unavailable."
        )
      )
    }
    var candidate = applications
    candidate[applicationIndex].profiles[profileIndex] = profile
    let snapshot = try repository.save(
      candidate,
      expectedVersion: expectedVersion
    )
    applications = snapshot.applications
    libraryVersionToken = snapshot.versionToken
    sceneCoordinator.synchronize(with: applications)
    loadState = .loaded
    publishLibraryChange()
    return (
      applications[applicationIndex].profiles[profileIndex],
      snapshot.versionToken
    )
  }

  func handleApplicationEditResult(
    _ result:
      LibraryEditApplyResult<ManagedApplicationEditField>
  ) -> Bool {
    switch result {
    case .applied, .noChanges:
      errorMessage = nil
      return true
    case .targetChanged:
      errorMessage = String(
        localized:
          "The application changed identity. Your draft was kept."
      )
    case .conflicts(let fields):
      errorMessage = String(
        localized:
          "Another window changed the same application fields: \(Self.editFieldList(fields.map(\.rawValue))). Your draft was kept."
      )
    case .persistenceFailed(let failure):
      errorMessage = failure.localizedDescription
    }
    return false
  }

  func handleProfileEditResult(
    _ result: LibraryEditApplyResult<LaunchProfileEditField>
  ) -> Bool {
    switch result {
    case .applied, .noChanges:
      errorMessage = nil
      return true
    case .targetChanged:
      errorMessage = String(
        localized:
          "The space changed identity. Your draft was kept."
      )
    case .conflicts(let fields):
      errorMessage = String(
        localized:
          "Another window changed the same profile fields: \(Self.editFieldList(fields.map(\.rawValue))). Your draft was kept."
      )
    case .persistenceFailed(let failure):
      errorMessage = failure.localizedDescription
    }
    return false
  }

  static func editFieldList(_ fields: [String]) -> String {
    fields.sorted().joined(separator: ", ")
  }

  @discardableResult
  func save() -> Bool {
    commit(
      applications,
      selectedApplicationID: selectedApplicationID,
      selectedProfileID: selectedProfileID
    )
  }

  @discardableResult
  func commit(
    _ candidate: [ManagedApplication],
    selectedApplicationID candidateApplicationID: ManagedApplication.ID?,
    selectedProfileID candidateProfileID: LaunchProfile.ID?,
    backupReason: LibraryBackupReason? = nil
  ) -> Bool {
    guard canMutateLibrary() else { return false }
    do {
      if let repository {
        guard let libraryVersionToken else {
          throw LibraryRepositoryError.libraryUnavailable(
            LibraryPersistenceFailure(
              originalBytes: nil,
              error: CocoaError(.fileReadCorruptFile)
            )
          )
        }
        let snapshot = try repository.save(
          candidate,
          expectedVersion: libraryVersionToken,
          backupReason: backupReason
        )
        self.libraryVersionToken = snapshot.versionToken
      } else {
        try persistence.save(candidate)
      }
      applications = candidate
      selectedApplicationID = candidateApplicationID
      selectedProfileID = candidateProfileID
      loadState = .loaded
      publishLibraryChange()
      return true
    } catch {
      AppLog.persistence.error("Failed to save library: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
      if case LibraryRepositoryError.commitFailed(let state, let failure) = error,
        state != .prior
      {
        loadState = .recoveryRequired(
          originalBytes: failure.originalBytes,
          message: error.localizedDescription
        )
      }
      return false
    }
  }

}
