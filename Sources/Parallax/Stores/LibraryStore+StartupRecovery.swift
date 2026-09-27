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

  /// Recovery discovery and all recovery effects run under the same library lock.
  private func recoverPendingTransactions(
    repository: any LibraryRepositoryPersisting,
    access: LibraryExclusiveAccess
  ) throws -> Bool {
    try access.validate(for: repository)
    pendingRecoveryIdentities = try pendingTransactionIdentities(repository: repository)
    if let storageRelocationCoordinator {
      let outcomes = try storageRelocationCoordinator.recoverAll(repository: repository, access: access)
      if let notices = try? storageRelocationCoordinator.recordedLeftoverNotices() {
        let unseen = notices.filter { !presentedRelocationNoticeIDs.contains($0.key) }
        let paths: String = unseen.values.flatMap { $0 }.sorted().joined(separator: "\n")
        if !paths.isEmpty {
          visibleRelocationNoticeIDs = Set(unseen.keys)
          presentedRelocationNoticeIDs.formUnion(unseen.keys)
          relocationNoticeMessage = String(localized: "The storage move is committed. Original data was left in place or could not be checked at: \(paths)")
          libraryOperationStatusMessage = relocationNoticeMessage
        } else if let committed = outcomes.compactMap({ outcome -> StorageRelocationOutcome? in
          if case .committed(let value) = outcome, value.leftoverSourcePaths.isEmpty { return value }
          return nil
        }).last {
          libraryOperationStatusMessage = storageRelocationCompletionMessage(committed)
        }
      } else {
        AppLog.persistence.error("Could not list storage relocation leftover notices.")
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
            access: access,
            activityRegistry: profileActivityRegistry
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

  nonisolated static func isRecoveryOperationInProgress(_ error: any Error) -> Bool {
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

  func pendingTransactionIdentities(repository: any LibraryRepositoryPersisting) throws -> Set<ProfileActivityIdentity> {
    var identities: Set<ProfileActivityIdentity> = []
    if let storageRelocationCoordinator {
      let pending = try storageRelocationCoordinator.pendingRelocations()
      if case .loaded(let snapshot) = repository.load() {
        for application in snapshot.applications where pending.contains(where: { $0.applicationStorageID == application.storageID }) {
          identities.formUnion(storageRelocationCoordinator.activityIdentities(application))
        }
      }
    }
    if let profileDataTransactions {
      for pending in try profileDataTransactions.pendingTransactions() {
        if let identity = pending.identity {
          identities.formUnion(profileDataTransactions.activityIdentities(identity))
        }
      }
    }
    if let applicationRemovalTransactions {
      do {
        identities.formUnion(try applicationRemovalTransactions.pendingActivityIdentities())
      } catch {
        if Self.isRecoveryOperationInProgress(error) { throw error }
        throw ApplicationRemovalPendingRecoveryFailure(underlying: error)
      }
    }
    return identities
  }

  func isWaitingForRecovery(identity: ProfileActivityIdentity) -> Bool {
    isLibraryOperationInProgress && (pendingRecoveryIdentities.map { pending in
      pending.contains { $0.applicationStorageID == identity.applicationStorageID && $0.profileStorageID == identity.profileStorageID }
    } ?? true)
  }

  func deferredRecoveryMessage() -> String {
    for application in applications {
      for profile in application.profiles where canRequestStuckLaunchRecovery(for: application, profile: profile) {
        let profileName: String = profile.name
        return String(localized: "Recovery is waiting for a stuck launch record for \(profileName). Quit every instance of the app, then use Clear Stuck Launch Record for that space.")
      }
    }
    return LibraryOperationInProgressError().localizedDescription
  }

}
