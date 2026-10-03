import AppKit
import Foundation
import Observation

// MARK: - Persistence integration

extension LibraryStore {
  func load() {
    let recoveryBytes: Data? = if case .recoveryRequired(
      let originalBytes,
      _
    ) = loadState {
      originalBytes
    } else {
      nil
    }
    if preserveInfrastructureRecoveryState(
      originalBytes: recoveryBytes
    ) {
      return
    }
    clearPendingApplicationRemovalRecoveryReason()
    let wasBusy = isLibraryOperationInProgress
    isLibraryOperationInProgress = false
    if wasBusy { libraryOperationStatusMessage = nil }
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
        sceneCoordinator.synchronize(with: applications)
        migrationBlockers = []
        loadState = .loaded
        finishLibraryReloadRetry()
        if errorMessage == LibraryOperationInProgressError().localizedDescription {
          errorMessage = nil
        }
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
      if let resolution = error as? LibraryMigrationResolutionRequired {
        finishLibraryReloadRetry()
        migrationRequiredLibrary = resolution.library
        migrationBlockers = resolution.blockers
        showLibraryRecovery(error, originalBytes: nil)
        return
      }
      if error is LibraryOperationInProgressError {
        isLibraryOperationInProgress = true
        libraryOperationStatusMessage = error.localizedDescription
        scheduleLibraryReloadRetry()
        return
      }
      finishLibraryReloadRetry()
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
    recoveryPass: Int = 0,
    allowMigration: Bool = true
  ) {
    let initialBytes = originalBytes(from: repository.load())
    guard !preserveInfrastructureRecoveryState(originalBytes: initialBytes) else {
      return
    }
    clearPendingApplicationRemovalRecoveryReason()
    let wasBusy = isLibraryOperationInProgress
    isLibraryOperationInProgress = false
    if wasBusy { libraryOperationStatusMessage = nil }
    let priorReadOnlyWarning = libraryReadOnlyWarning
    libraryReadOnlyWarning = nil
    do {
      let result = try repository.tryWithExclusiveAccess { access in
        try loadWhileLocked(
          from: repository,
          recoveryPass: recoveryPass,
          allowMigration: allowMigration,
          access: access
        )
      }
      if case .busy = result {
        // Read-only discovery can narrow launch admission without the library
        // lock. Live operations still hold their data-operation reservations;
        // if journals cannot be listed, conservatively block all launches.
        pendingRecoveryIdentities = try? pendingTransactionIdentities(repository: repository)
        applyRepositoryLoad(repository.load())
        isLibraryOperationInProgress = true
        if migrationRequiredLibrary != nil {
          loadState = .loading
          errorMessage = nil
        }
        libraryOperationStatusMessage = LibraryOperationInProgressError()
          .localizedDescription
        shouldRetryLibraryMigration = shouldRetryLibraryMigration || allowMigration
        scheduleLibraryReloadRetry()
      } else {
        Task { await refreshApplicationRemovalRecoveryReviews() }
        finishLibraryReloadRetry()
        if errorMessage == LibraryOperationInProgressError().localizedDescription
          || (priorReadOnlyWarning != nil && errorMessage == priorReadOnlyWarning)
        {
          errorMessage = nil
        }
      }
    } catch where Self.isRecoveryOperationInProgress(error) {
      applyRepositoryLoad(repository.load())
      if errorMessage == LibraryOperationInProgressError().localizedDescription { errorMessage = nil }
      isLibraryOperationInProgress = true
      libraryOperationStatusMessage = deferredRecoveryMessage()
      shouldRetryLibraryMigration = shouldRetryLibraryMigration || allowMigration
      scheduleLibraryReloadRetry()
    } catch LibraryAdvisoryLockError.unavailable(let error) {
      applyRepositoryLoad(repository.load())
      libraryReadOnlyWarning = LibraryAdvisoryLockError.unavailable(error).localizedDescription
      errorMessage = libraryReadOnlyWarning
      finishLibraryReloadRetry()
    } catch {
      finishLibraryReloadRetry()
      if let resolution = error as? LibraryMigrationResolutionRequired {
        migrationRequiredLibrary = resolution.library
        migrationBlockers = resolution.blockers
      }
      if let failure = error as? ApplicationRemovalPendingRecoveryFailure,
        case .loaded(let snapshot) = repository.load(),
        presentPendingApplicationRemovalRecovery(failure.underlying, loadedLibrary: snapshot)
      { return }
      // A journal or storage failure can block an intact current library.
      // Restoring a backup or starting over cannot fix it, and could detach
      // the library from data that a pending operation already moved.
      let failedBytes: Data? = if case .loaded = repository.load() { nil } else { initialBytes }
      showLibraryRecovery(error, originalBytes: failedBytes)
    }
  }

  func applyRepositoryLoad(_ outcome: LibraryRepositoryLoadOutcome) {
    switch outcome {
    case .missing:
      applications = []
      sceneCoordinator.synchronize(with: applications)
      libraryVersionToken = .missing
      migrationRequiredLibrary = nil
      migrationBlockers = []
      loadState = .loaded
    case .loaded(let snapshot):
      applications = snapshot.applications
      sceneCoordinator.synchronize(with: applications)
      libraryVersionToken = snapshot.versionToken
      migrationRequiredLibrary = nil
      migrationBlockers = []
      loadState = .loaded
    case .migrationRequired(let snapshot):
      if migrationRequiredLibrary != snapshot.library {
        migrationBlockers = []
      }
      migrationRequiredLibrary = snapshot.library
      let error: any Error = migrationBlockers.isEmpty
        ? LibraryPersistenceError.migrationRequired(format: snapshot.library.format)
        : LibraryMigrationResolutionRequired(
          library: snapshot.library,
          blockers: migrationBlockers
        )
      showLibraryRecovery(error, originalBytes: snapshot.originalBytes)
    case .recoveryRequired(let failure):
      showLibraryRecovery(failure.error, originalBytes: failure.originalBytes)
    case .readOnly(let failure):
      showLibraryRecovery(failure.error, originalBytes: failure.originalBytes)
      loadState = .unsupportedNewerVersion(
        originalBytes: failure.originalBytes,
        message: failure.error.localizedDescription
      )
    }
  }

  private func showLibraryRecovery(_ error: any Error, originalBytes: Data?) {
    applications = []
    sceneCoordinator.synchronize(with: applications)
    libraryVersionToken = nil
    errorMessage = error.localizedDescription
    loadState = .recoveryRequired(
      originalBytes: originalBytes,
      message: error.localizedDescription
    )
  }

  private func originalBytes(from outcome: LibraryRepositoryLoadOutcome) -> Data? {
    switch outcome {
    case .loaded(let snapshot): snapshot.originalBytes
    case .migrationRequired(let snapshot): snapshot.originalBytes
    case .recoveryRequired(let failure), .readOnly(let failure): failure.originalBytes
    case .missing: nil
    }
  }

  /// Passive refreshes still check transaction recovery, but never retry a
  /// blocked legacy migration. Explicit load/relaunch owns that work.
  func reloadFromSharedRepository() {
    guard let repository else { return }
    load(from: repository, allowMigration: false)
  }

  func scheduleLibraryReloadRetry(immediately: Bool = false) {
    guard isLibraryOperationInProgress else { return }
    guard immediately || libraryReloadRetryCancellation == nil else { return }
    libraryReloadRetryCancellation?()
    libraryReloadRetryGeneration &+= 1
    let generation = libraryReloadRetryGeneration
    let delay = immediately ? .zero : libraryReloadRetryDelay
    if !immediately {
      libraryReloadRetryDelay = min(libraryReloadRetryDelay * 2, .seconds(5))
    }
    libraryReloadRetryCancellation = libraryReloadRetryScheduler(delay) { [weak self] in
      guard let self, self.libraryReloadRetryGeneration == generation else { return }
      self.libraryReloadRetryCancellation = nil
      self.retryBusyLibraryLoad()
    }
    if libraryReloadActivationObservation == nil {
      libraryReloadActivationObservation = LibraryReloadActivationObservation { [weak self] in
        self?.retryBusyLibraryLoad()
      }
    }
  }

  func retryBusyLibraryLoad() {
    guard isLibraryOperationInProgress else { return }
    if let repository {
      load(from: repository, allowMigration: shouldRetryLibraryMigration)
    } else {
      load()
    }
  }

  private func finishLibraryReloadRetry() {
    libraryReloadRetryCancellation?()
    libraryReloadRetryCancellation = nil
    libraryReloadRetryGeneration &+= 1
    libraryReloadActivationObservation = nil
    libraryReloadRetryDelay = .milliseconds(100)
    shouldRetryLibraryMigration = false
  }

  private func preserveInfrastructureRecoveryState(
    originalBytes: Data?
  ) -> Bool {
    guard let infrastructureFailureMessage else {
      return false
    }
    applications = []
    selectedApplicationID = nil
    selectedProfileID = nil
    libraryVersionToken = nil
    errorMessage = infrastructureFailureMessage
    loadState = .recoveryRequired(
      originalBytes: originalBytes,
      message: infrastructureFailureMessage
    )
    return true
  }

  func publishLibraryChange() {
    // A detached operation can finish after a peer has committed again. Its
    // continuation's candidate must not replace that newer durable snapshot.
    if let repository {
      switch repository.load() {
      case .loaded(let snapshot):
        if snapshot.versionToken != libraryVersionToken {
          reloadFromSharedRepository()
        }
      case .missing:
        if libraryVersionToken != .missing {
          reloadFromSharedRepository()
        }
      case .migrationRequired, .recoveryRequired, .readOnly:
        reloadFromSharedRepository()
      }
    }
    libraryChangeBroadcaster?.publish(sourceSceneID: sceneID)
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
      handleLibrarySaveFailure(error)
      if case LibraryRepositoryError.commitFailed(.target, _) = error {
        selectedApplicationID = candidateApplicationID
        selectedProfileID = candidateProfileID
      }
      return false
    }
  }

  func handleLibrarySaveFailure(_ error: any Error) {
    switch error {
    case LibraryRepositoryError.staleWriter:
      reloadFromSharedRepository()
      errorMessage = String(localized: "Your change was not saved because the library changed in another Parallax process. This window was refreshed. Review it before trying again.")
      return
    case LibraryRepositoryError.commitFailed(let state, let failure):
      switch state {
      case .prior:
        break
      case .target:
        // The rename succeeded. Adopt and broadcast the durable primary, while
        // keeping the durability warning visible to the caller.
        publishLibraryChange()
      case .neither:
        showLibraryRecovery(error, originalBytes: failure.originalBytes)
      }
    default:
      break
    }
    errorMessage = error.localizedDescription
  }

}
