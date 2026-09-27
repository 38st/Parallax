import AppKit
import Foundation
import Observation

extension LibraryStore {
  func loadWhileLocked(
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
    if let storageRelocationCoordinator {
      let outcomes = try storageRelocationCoordinator.recoverAll(repository: repository, access: access)
      let leftovers = try storageRelocationCoordinator.recordedLeftoverSourcePaths()
      if !leftovers.isEmpty {
        let paths: String = leftovers.joined(separator: "\n")
        libraryOperationStatusMessage = String(localized: "The storage move is committed. Original data was left in place or could not be checked at: \(paths)")
      } else if let committed = outcomes.compactMap({ outcome -> StorageRelocationOutcome? in
        if case .committed(let value) = outcome { return value }
        return nil
      }).last {
        libraryOperationStatusMessage = storageRelocationCompletionMessage(committed)
      }
      if !outcomes.isEmpty { return true }
    }
    if let profileDataTransactions {
      try profileDataTransactions.performMaintenance(repository: repository, access: access)
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
      do {
        let pending = try applicationRemovalTransactions.pendingTransactions()
        for transactionID in pending {
          _ = try applicationRemovalTransactions.recover(
            transactionID: transactionID,
            repository: repository,
            access: access
          )
        }
        if !pending.isEmpty { return true }
      } catch {
        if Self.isRecoveryOperationInProgress(error) { throw error }
        throw ApplicationRemovalPendingRecoveryFailure(underlying: error)
      }
    }
    return false
  }

  static func isRecoveryOperationInProgress(_ error: any Error) -> Bool {
    switch error {
    case is LibraryOperationInProgressError,
      ProfileActivityRegistryError.storageReservedForDataOperation,
      ProfileActivityRegistryError.profileAlreadyActive,
      ProfileActivityRegistryError.processIdentityAmbiguous,
      DurableLaunchActivityStoreError.profileAlreadyActive,
      DurableLaunchActivityStoreError.activityBusy:
      return true
    default:
      return false
    }
  }

}
