import Darwin
import Foundation

// MARK: - Public operations

extension ProfileDataTransactionCoordinator {
  // Disabling failure recovery is reserved for fixtures that simulate process
  // termination before the in-process error handler can run.
  func execute(
    _ request: ProfileDataTransactionRequest,
    preparedCommit: PreparedLibraryCommit,
    repository: any LibraryRepositoryPersisting,
    activityRegistry: ProfileActivityRegistry? = nil,
    activityPolicy: DataOperationActivityPolicy = .requireInactive,
    recoverOnFailure: Bool = true
  ) throws -> ProfileDataTransactionOutcome {
    try validatePreparedCommit(preparedCommit)
    try validateRequest(request)

    do {
      return try repository.withExclusiveMutation(
        expectedVersion: preparedCommit.priorVersion
      ) { capability in
        let registry = try activityRegistry ?? ProfileActivityRegistry(
          applicationSupportURL: applicationSupportURL
        )
        let reservation = try registry.acquireDataOperationLease(
          identities: activityIdentities(request.identity),
          activityPolicy: activityPolicy
        )
        defer { reservation.release() }
        var log = try preparePlan(
          request: request,
          preparedCommit: preparedCommit
        )
        try validateMetadataTransition(
          plan: log.plan,
          priorApplications: capability.applications,
          targetApplications: preparedCommit.applications
        )
        guard
          log.plan.preparedCommitIdentifier
            == preparedCommitIdentifier(
              request: request,
              preparedCommit: preparedCommit
            )
        else {
          throw ProfileDataTransactionError(
            .preparedCommitMismatch,
            operation: request.operation
          )
        }
        let sourceFS = try secureFileSystem(for: log.plan.sourceRoot)
        let destinationFS = try log.plan.destinationRoot.map {
          try secureFileSystem(for: $0)
        }
        try verifyInitialState(
          log.plan,
          sourceFS: sourceFS,
          destinationFS: destinationFS
        )
        let planPath = try controlPlanPath(request.transactionID)
        let planWasMissing = try control.itemState(at: planPath) == .missing
        do {
          try publishPlan(log)
          if log.plan.sourceSnapshot != nil {
            try prepareOwnedStaging(
              log: &log,
              hostFS: destinationFS ?? sourceFS
            )
          }

          let mutation = try applyData(
            log: &log,
            sourceFS: sourceFS,
            destinationFS: destinationFS
          )
          _ = try perform(
            .commitMetadata,
            log: &log
          ) {
            let result = try capability.commit(
              preparedCommit,
              backupReason: metadataBackupReason(
                for: request.operation
              )
            )
            return [
              "primaryState": result.primaryState.rawValue,
              "targetSHA256":
                result.snapshot.versionToken.primarySHA256 ?? "",
            ]
          }

          try finalizeCommittedData(
            log: &log,
            sourceFS: sourceFS,
            destinationFS: destinationFS
          )
          try cleanupOwnedStaging(
            log: &log,
            hostFS: destinationFS ?? sourceFS
          )
          let outcome = try complete(log: &log, mutation: mutation, completion: .committed)
          try pruneCompletedTransactions()
          return outcome
        } catch {
          let operationError = error
          guard recoverOnFailure, planWasMissing else { throw operationError }
          let planState: SecureManagedItemState
          do { planState = try control.itemState(at: planPath) }
          catch {
            throw ProfileDataTransactionRecoveryFailure(operationError: operationError, recoveryError: error)
          }
          guard planState != .missing else { throw operationError }
          do {
            var recoveryLog = try loadLog(transactionID: request.transactionID, allowingTornTail: true)
            guard recoveryLog.planHash == log.planHash else {
              throw ProfileDataTransactionError(.invalidJournal, path: controlURL(for: planPath).path)
            }
            var outcome = try recover(log: &recoveryLog, repository: repository)
            try pruneCompletedTransactions()
            if outcome.dataMutation == .rolledBack { outcome.operationFailure = operationError.localizedDescription }
            return outcome
          } catch {
            throw ProfileDataTransactionRecoveryFailure(operationError: operationError, recoveryError: error)
          }
        }
      }
    } catch {
      if error as? SecureManagedFileSystemError == .symbolicLinkEncountered {
        throw ProfileDataTransactionError(.unsupportedSymbolicLink, operation: request.operation)
      }
      throw error
    }
  }

  func recover(
    transactionID: UUID,
    repository: any LibraryRepositoryPersisting,
    access: LibraryExclusiveAccess
  ) throws -> ProfileDataTransactionOutcome {
    try access.validate(for: repository)
    if try isUnpublishedTornPlan(transactionID) {
      try quarantine(controlPlanPath(transactionID), in: control)
      try sweepWriteTemporaries(in: control, directory: nil, rootURL: controlRootURL)
      return ProfileDataTransactionOutcome(transactionID: transactionID, operation: nil,
        dataMutation: .rolledBack, externalDataHandling: .notConfigured,
        didArchiveData: false, archiveURL: nil, receiptURL: nil)
    }
    var log = try loadLog(transactionID: transactionID, allowingTornTail: true)
    let registry = try ProfileActivityRegistry(applicationSupportURL: applicationSupportURL)
    let reservation = try registry.acquireDataOperationLease(
      identities: activityIdentities(log.plan.identity)
    )
    defer { reservation.release() }
    let outcome = try recover(log: &log, repository: repository)
    try pruneCompletedTransactions()
    return outcome
  }

  private func recover(
    log: inout TransactionLog,
    repository: any LibraryRepositoryPersisting
  ) throws -> ProfileDataTransactionOutcome {
    let primary = classifyPrimary(repository.load(), prior: log.plan.priorVersion.value,
      target: log.plan.targetVersion.value)
    do {
      try repairInterruptedControlWrites(log: &log)
      if try control.itemState(at: controlReceiptPath(log.plan.transactionID)) != .missing,
        !log.hasEffect(.writeReceipt)
      {
        try repairReceiptEffect(log: &log)
      }
      if let receipt = try validatedReceiptIfPresent(log: log) {
        return outcome(from: receipt, plan: log.plan)
      }
      guard primary != .neither else {
        throw ProfileDataTransactionError(.ambiguousLibraryState, operation: log.plan.operation)
      }
      // A receipt intent is written only after every data and cleanup step.
      // Its interrupted publication needs no further access to managed data.
      if log.records.last?.unsigned.event == Event(phase: .intent, effect: .writeReceipt) {
        return try complete(log: &log,
          mutation: primary == .target ? committedMutation(for: log.plan) : .rolledBack,
          completion: primary == .target ? .committed : .rolledBack)
      }
      try repairInterruptedMarkers(log: log)
      let sourceFS = try secureFileSystem(for: log.plan.sourceRoot)
      let destinationFS = try log.plan.destinationRoot.map { try secureFileSystem(for: $0) }
      if primary == .target {
        try finalizeCommittedData(log: &log, sourceFS: sourceFS, destinationFS: destinationFS)
        try cleanupOwnedStaging(log: &log, hostFS: destinationFS ?? sourceFS)
        return try complete(log: &log, mutation: committedMutation(for: log.plan), completion: .committed)
      }
      try rollBackData(log: &log, sourceFS: sourceFS, destinationFS: destinationFS)
      try cleanupOwnedStaging(log: &log, hostFS: destinationFS ?? sourceFS)
      return try complete(log: &log, mutation: .rolledBack, completion: .rolledBack)
    } catch {
      let recoveryError = error
      do { try markRecoveryRequired(log: &log, primary: primary, error: recoveryError) }
      catch { throw ProfileDataTransactionRecoveryFailure(operationError: recoveryError, recoveryError: error) }
      throw recoveryError
    }
  }

  func pendingTransactions() throws -> [PendingProfileDataTransaction] {
    try validateControlRoot()
    let entries = try fileSystem.contentsOfDirectory(at: controlRootURL)
    let suffix = ".plan.json"
    let grouped = Dictionary(grouping: entries) { String($0.lastPathComponent.prefix(36)) }
    var pending: [PendingProfileDataTransaction] = []
    for entry
      in entries
      .filter({ $0.lastPathComponent.hasSuffix(suffix) })
      .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    {
      let rawID = String(entry.lastPathComponent.dropLast(suffix.count))
      guard
        let id = UUID(uuidString: rawID),
        id.uuidString.lowercased() == rawID
      else {
        throw ProfileDataTransactionError(
          .invalidJournal,
          path: entry.path
        )
      }
      if try hasPruningMarker(id) { continue }
      if try completedReceiptIfPresent(transactionID: id, entries: grouped[rawID] ?? []) {
        continue
      }
      if try isUnpublishedTornPlan(id) {
        pending.append(PendingProfileDataTransaction(transactionID: id, identity: nil,
          operation: nil, state: "unpublished", createdAt: nil))
        continue
      }
      let log = try loadLog(transactionID: id, allowingTornTail: true)
      pending.append(
        PendingProfileDataTransaction(
          transactionID: id,
          identity: log.plan.identity,
          operation: log.plan.operation,
          state: log.records.last?.unsigned.event.effect.rawValue
            ?? "prepared",
          createdAt: log.plan.createdAt
        )
      )
    }
    try validateControlRoot()
    return pending
  }

  private func activityIdentities(
    _ identity: ProfileDataTransactionIdentity
  ) -> Set<ProfileActivityIdentity> {
    var identities: Set<ProfileActivityIdentity> = [
      ProfileActivityIdentity(
        applicationID: identity.applicationID,
        applicationStorageID: identity.applicationStorageID,
        profileID: identity.sourceProfileID,
        profileStorageID: identity.sourceProfileStorageID
      )
    ]
    if let profileID = identity.destinationProfileID,
      let storageID = identity.destinationProfileStorageID
    {
      identities.insert(ProfileActivityIdentity(
        applicationID: identity.applicationID,
        applicationStorageID: identity.applicationStorageID,
        profileID: profileID,
        profileStorageID: storageID
      ))
    }
    return identities
  }
}
