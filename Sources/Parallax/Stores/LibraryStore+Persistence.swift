import AppKit
import Foundation
import Observation

// MARK: - Persistence and transaction integration

extension LibraryStore {
  func applicationForLaunch(_ profile: LaunchProfile) -> ManagedApplication? {
    if let selectedApplication,
      selectedApplication.profiles.contains(where: { $0.id == profile.id })
    {
      return selectedApplication
    }

    return applications.first { application in
      application.profiles.contains { $0.id == profile.id }
    }
  }

  func submitLaunchConfirmation(
    application: ManagedApplication,
    profile: LaunchProfile,
    source: LaunchConfigurationSource,
    fingerprint: LaunchConfigurationFingerprint
  ) {
    let request = ImmutableLaunchRequest(
      sceneID: sceneID,
      applicationName: application.displayName,
      profileName: profile.name,
      configurationSnapshot: source,
      configurationFingerprint: fingerprint
    )
    switch launchRequests.submit(request, policy: .rejectNew) {
    case .awaitingConfirmation:
      isShowingLaunchConfirmation = true
    case .queued:
      isShowingLaunchConfirmation = true
    case .rejected(_, let reason):
      errorMessage = reason.message
    }
  }

  func currentLaunchTarget(
    for request: ImmutableLaunchRequest
  ) -> LaunchRequestCurrentTarget {
    guard
      let application = applications.first(where: {
        $0.id == request.applicationID
      })
    else {
      return .applicationRemoved
    }
    guard
      let profile = application.profiles.first(where: {
        $0.id == request.profileID
      })
    else {
      return .profileRemoved
    }
    let source = launchConfigurationSource(
      application: application,
      profile: profile,
      requestID: request.requestID
    )
    return .available(
      applicationID: application.id,
      profileID: profile.id,
      configurationRevision: source.configurationRevision,
      configurationFingerprint:
        LaunchConfigurationCompiler
        .configurationFingerprint(for: source)
    )
  }

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

  func executeProfileDataTransaction(
    operation: ProfileDataTransactionOperation,
    application: ManagedApplication,
    sourceProfile: LaunchProfile,
    destinationProfile: LaunchProfile?,
    candidate: [ManagedApplication],
    selectedProfileID candidateProfileID: LaunchProfile.ID?,
    externalDataHandling: ProfileExternalDataHandling
  ) -> ProfileDataTransactionOutcome? {
    guard
      let profileDataTransactions,
      let repository,
      let libraryVersionToken
    else {
      return nil
    }
    let priorVersionToken = libraryVersionToken

    do {
      let prepared = try prepareProfileDataTransaction(
        operation: operation,
        application: application,
        sourceProfile: sourceProfile,
        destinationProfile: destinationProfile,
        candidate: candidate,
        externalDataHandling: externalDataHandling,
        expectedVersion: libraryVersionToken,
        repository: repository
      )
      let outcome = try profileDataTransactions.execute(
        prepared.request,
        preparedCommit: prepared.commit,
        repository: repository
      )
      applyProfileDataTransactionSuccess(
        candidate: candidate,
        applicationID: application.id,
        selectedProfileID: candidateProfileID,
        targetVersion: prepared.commit.targetVersion
      )
      return outcome
    } catch {
      reconcileAfterProfileDataTransactionFailure(
        error,
        repository: repository,
        priorVersionToken: priorVersionToken,
        profileDataTransactions: profileDataTransactions
      )
      return nil
    }
  }

  func executeProfileDataTransactionAsync(
    operation: ProfileDataTransactionOperation,
    application: ManagedApplication,
    sourceProfile: LaunchProfile,
    destinationProfile: LaunchProfile?,
    candidate: [ManagedApplication],
    selectedProfileID candidateProfileID: LaunchProfile.ID?,
    externalDataHandling: ProfileExternalDataHandling
  ) async -> ProfileDataTransactionOutcome? {
    guard
      let profileDataTransactions,
      let repository,
      let libraryVersionToken
    else {
      return nil
    }
    let priorVersionToken = libraryVersionToken

    do {
      let prepared = try prepareProfileDataTransaction(
        operation: operation,
        application: application,
        sourceProfile: sourceProfile,
        destinationProfile: destinationProfile,
        candidate: candidate,
        externalDataHandling: externalDataHandling,
        expectedVersion: libraryVersionToken,
        repository: repository
      )
      let outcome = try await Task.detached(
        priority: .userInitiated
      ) {
        try profileDataTransactions.execute(
          prepared.request,
          preparedCommit: prepared.commit,
          repository: repository
        )
      }.value
      applyProfileDataTransactionSuccess(
        candidate: candidate,
        applicationID: application.id,
        selectedProfileID: candidateProfileID,
        targetVersion: prepared.commit.targetVersion
      )
      return outcome
    } catch {
      reconcileAfterProfileDataTransactionFailure(
        error,
        repository: repository,
        priorVersionToken: priorVersionToken,
        profileDataTransactions: profileDataTransactions
      )
      return nil
    }
  }

  private struct PreparedProfileDataTransactionExecution: Sendable {
    let request: ProfileDataTransactionRequest
    let commit: PreparedLibraryCommit
  }

  private func prepareProfileDataTransaction(
    operation: ProfileDataTransactionOperation,
    application: ManagedApplication,
    sourceProfile: LaunchProfile,
    destinationProfile: LaunchProfile?,
    candidate: [ManagedApplication],
    externalDataHandling: ProfileExternalDataHandling,
    expectedVersion: LibraryVersionToken,
    repository: any LibraryRepositoryPersisting
  ) throws -> PreparedProfileDataTransactionExecution {
    let source = try managedPaths(
      for: application,
      profile: sourceProfile
    )
    let destination = try destinationProfile.map {
      try managedPaths(for: application, profile: $0)
    }
    let commit = try repository.prepare(
      candidate,
      expectedVersion: expectedVersion
    )
    let request = ProfileDataTransactionRequest(
      transactionID: UUID(),
      identity: ProfileDataTransactionIdentity(
        applicationID: application.id,
        applicationStorageID: application.storageID,
        sourceProfileID: sourceProfile.id,
        sourceProfileStorageID: sourceProfile.storageID,
        destinationProfileID: destinationProfile?.id,
        destinationProfileStorageID: destinationProfile?.storageID
      ),
      operation: operation,
      source: source,
      destination: destination,
      externalDataHandling: externalDataHandling
    )
    return PreparedProfileDataTransactionExecution(
      request: request,
      commit: commit
    )
  }

  private func applyProfileDataTransactionSuccess(
    candidate: [ManagedApplication],
    applicationID: ManagedApplication.ID,
    selectedProfileID candidateProfileID: LaunchProfile.ID?,
    targetVersion: LibraryVersionToken
  ) {
    applications = candidate
    selectedApplicationID = applicationID
    selectedProfileID = candidateProfileID
    libraryVersionToken = targetVersion
    loadState = .loaded
    publishLibraryChange()
  }

  private func reconcileAfterProfileDataTransactionFailure(
    _ error: Error,
    repository: any LibraryRepositoryPersisting,
    priorVersionToken: LibraryVersionToken,
    profileDataTransactions: ProfileDataTransactionCoordinator
  ) {
    AppLog.profiles.error(
      "Profile data transaction failed: \(error.localizedDescription)"
    )
    errorMessage = error.localizedDescription
    switch repository.load() {
    case .loaded(let snapshot):
      let previousApplicationID = selectedApplicationID
      let previousProfileID = selectedProfileID
      applications = snapshot.applications
      libraryVersionToken = snapshot.versionToken
      selectedApplicationID =
        applications.contains {
          $0.id == previousApplicationID
        } ? previousApplicationID : applications.first?.id
      if let selectedApplication = applications.first(where: {
        $0.id == selectedApplicationID
      }) {
        selectedProfileID =
          selectedApplication.profiles.contains {
            $0.id == previousProfileID
          } ? previousProfileID : selectedApplication.profiles.first?.id
      } else {
        selectedProfileID = nil
      }
      if snapshot.versionToken == priorVersionToken {
        loadState = .loaded
      } else {
        loadState = .recoveryRequired(
          originalBytes: nil,
          message: error.localizedDescription
        )
      }
    case .recoveryRequired(let failure),
      .readOnly(let failure):
      loadState = .recoveryRequired(
        originalBytes: failure.originalBytes,
        message: error.localizedDescription
      )
    case .missing, .migrationRequired:
      loadState = .recoveryRequired(
        originalBytes: nil,
        message: error.localizedDescription
      )
    }
    if (try? profileDataTransactions.pendingTransactions().isEmpty) == false {
      loadState = .recoveryRequired(
        originalBytes: failedPrimaryBytes,
        message: error.localizedDescription
      )
    }
  }
}
