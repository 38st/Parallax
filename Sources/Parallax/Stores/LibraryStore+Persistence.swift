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
        // A live owner may still be changing its journals. Do not even inspect
        // them until a later load acquires the lock.
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
        finishLibraryReloadRetry()
        if errorMessage == LibraryOperationInProgressError().localizedDescription
          || (priorReadOnlyWarning != nil && errorMessage == priorReadOnlyWarning)
        {
          errorMessage = nil
        }
      }
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
      showLibraryRecovery(error, originalBytes: initialBytes)
    }
  }

  private func loadWhileLocked(
    from repository: any LibraryRepositoryPersisting,
    recoveryPass: Int,
    allowMigration: Bool,
    access: LibraryExclusiveAccess
  ) throws {
    try access.validate(for: repository)
    guard recoveryPass <= 4 else {
      throw LibraryStoreInfrastructureError.startupRecoveryDidNotConverge
    }
    let outcome = repository.load()
    switch outcome {
    case .missing, .loaded:
      if try recoverPendingTransactions(repository: repository, access: access) {
        try loadWhileLocked(
          from: repository,
          recoveryPass: recoveryPass + 1,
          allowMigration: allowMigration,
          access: access
        )
        return
      }
      applyRepositoryLoad(outcome)
      if case .loaded(let snapshot) = outcome,
        let warning = repository.persistence.finalizeCommittedMigrationIfNeeded(
          applications: snapshot.applications, access: access
        )
      {
        errorMessage = warning
      }
    case .migrationRequired(let snapshot):
      guard allowMigration else {
        applyRepositoryLoad(outcome)
        return
      }
      migrationRequiredLibrary = snapshot.library
      migrationBlockers = []
      let result = try repository.persistence.loadResultWhileLocked(access: access)
      switch result {
      case .current:
        try loadWhileLocked(
          from: repository,
          recoveryPass: recoveryPass + 1,
          allowMigration: allowMigration,
          access: access
        )
      case .migrationRequired:
        applyRepositoryLoad(outcome)
      }
    case .recoveryRequired, .readOnly:
      applyRepositoryLoad(outcome)
    }
  }

  /// Discovery and all recovery effects run under the same library lock.
  private func recoverPendingTransactions(
    repository: any LibraryRepositoryPersisting,
    access: LibraryExclusiveAccess
  ) throws -> Bool {
    try access.validate(for: repository)
    if let storageRelocationCoordinator,
      try !storageRelocationCoordinator.pendingRelocations().isEmpty
    {
      _ = try storageRelocationCoordinator.recoverAll(repository: repository, access: access)
      return true
    }
    if let profileDataTransactions {
      let pending = try profileDataTransactions.pendingTransactions()
      if !pending.isEmpty {
        for transaction in pending {
          _ = try profileDataTransactions.recover(
            transactionID: transaction.transactionID,
            repository: repository,
            access: access
          )
        }
        return true
      }
    }
    if let applicationRemovalTransactions {
      let pending = try applicationRemovalTransactions.pendingTransactions()
      if !pending.isEmpty {
        for transactionID in pending {
          _ = try applicationRemovalTransactions.recover(
            transactionID: transactionID,
            repository: repository,
            access: access
          )
        }
        return true
      }
    }
    return false
  }

  private func applyRepositoryLoad(_ outcome: LibraryRepositoryLoadOutcome) {
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

  func persistApplicationEdit(
    _ application: ManagedApplication,
    expectedVersion: LibraryVersionToken
  ) throws -> (
    persisted: ManagedApplication,
    version: LibraryVersionToken
  ) {
    guard canMutateLibrary() else {
      throw LibraryEditPersistenceFailure(
        message: errorMessage ?? String(localized: "The library is read-only until its load or recovery problem is resolved.")
      )
    }
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
    let snapshot: LibraryRepositorySnapshot
    do {
      snapshot = try repository.save(candidate, expectedVersion: expectedVersion)
    } catch {
      handleLibrarySaveFailure(error)
      if case LibraryRepositoryError.staleWriter = error, let errorMessage {
        throw LibraryEditPersistenceFailure(message: errorMessage)
      }
      throw error
    }
    applications = snapshot.applications
    libraryVersionToken = snapshot.versionToken
    sceneCoordinator.synchronize(with: applications)
    loadState = .loaded
    publishLibraryChange()
    return (
      snapshot.applications[index],
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
    guard canMutateLibrary() else {
      throw LibraryEditPersistenceFailure(
        message: errorMessage ?? String(localized: "The library is read-only until its load or recovery problem is resolved.")
      )
    }
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
    let snapshot: LibraryRepositorySnapshot
    do {
      snapshot = try repository.save(candidate, expectedVersion: expectedVersion)
    } catch {
      handleLibrarySaveFailure(error)
      if case LibraryRepositoryError.staleWriter = error, let errorMessage {
        throw LibraryEditPersistenceFailure(message: errorMessage)
      }
      throw error
    }
    applications = snapshot.applications
    libraryVersionToken = snapshot.versionToken
    sceneCoordinator.synchronize(with: applications)
    loadState = .loaded
    publishLibraryChange()
    return (
      snapshot.applications[applicationIndex].profiles[profileIndex],
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
          "Another window changed the same application fields: \(Self.editFieldList(fields.map(\.localizedLabel))). Your draft was kept."
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
          "Another window changed the same profile fields: \(Self.editFieldList(fields.map(\.localizedLabel))). Your draft was kept."
      )
    case .persistenceFailed(let failure):
      errorMessage = failure.localizedDescription
    }
    return false
  }

  static func editFieldList(_ fields: [String]) -> String {
    LibraryLocalizedList.string(from: fields.sorted())
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

  private func handleLibrarySaveFailure(_ error: any Error) {
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
