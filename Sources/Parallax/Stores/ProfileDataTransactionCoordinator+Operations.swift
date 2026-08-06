import Darwin
import Foundation

// MARK: - Public operations

extension ProfileDataTransactionCoordinator {
  func execute(
    _ request: ProfileDataTransactionRequest,
    preparedCommit: PreparedLibraryCommit,
    repository: any LibraryRepositoryPersisting
  ) throws -> ProfileDataTransactionOutcome {
    try validatePreparedCommit(preparedCommit)
    try validateRequest(request)

    do {
      return try repository.withExclusiveMutation(
        expectedVersion: preparedCommit.priorVersion
      ) { capability in
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
        return try complete(
          log: &log,
          mutation: mutation,
          completion: .committed
        )
      }
    } catch {
      // All state needed by restart recovery is already durable. Do not
      // perform an unlocked best-effort mutation here.
      throw error
    }
  }

  func recover(
    transactionID: UUID,
    repository: any LibraryRepositoryPersisting
  ) throws -> ProfileDataTransactionOutcome {
    var log = try loadLog(transactionID: transactionID)
    if try control.itemState(
      at: controlReceiptPath(transactionID)
    ) != .missing,
      !log.hasEffect(.writeReceipt)
    {
      try repairReceiptEffect(log: &log)
    }
    if let receipt = try validatedReceiptIfPresent(log: log) {
      return outcome(from: receipt, plan: log.plan)
    }

    let primary = classifyPrimary(
      repository.load(),
      prior: log.plan.priorVersion.value,
      target: log.plan.targetVersion.value
    )
    guard primary != .neither else {
      if !log.hasEffect(.requireRecovery) {
        _ = try perform(.requireRecovery, log: &log) {
          ["primaryState": LibraryCommitPrimaryState.neither.rawValue]
        }
      }
      throw ProfileDataTransactionError(
        .ambiguousLibraryState,
        operation: log.plan.operation
      )
    }

    let sourceFS = try secureFileSystem(for: log.plan.sourceRoot)
    let destinationFS = try log.plan.destinationRoot.map {
      try secureFileSystem(for: $0)
    }
    do {
      if primary == .target {
        try finalizeCommittedData(
          log: &log,
          sourceFS: sourceFS,
          destinationFS: destinationFS
        )
        try cleanupOwnedStaging(
          log: &log,
          hostFS: destinationFS ?? sourceFS
        )
        return try complete(
          log: &log,
          mutation: committedMutation(for: log.plan),
          completion: .committed
        )
      }

      try rollBackData(
        log: &log,
        sourceFS: sourceFS,
        destinationFS: destinationFS
      )
      try cleanupOwnedStaging(
        log: &log,
        hostFS: destinationFS ?? sourceFS
      )
      return try complete(
        log: &log,
        mutation: .rolledBack,
        completion: .rolledBack
      )
    } catch {
      try markRecoveryRequired(
        log: &log,
        primary: primary,
        error: error
      )
      throw error
    }
  }

  func pendingTransactions() throws -> [PendingProfileDataTransaction] {
    try validateControlRoot()
    let entries = try fileSystem.contentsOfDirectory(at: controlRootURL)
    let suffix = ".plan.json"
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
      let log = try loadLog(transactionID: id)
      if try validatedReceiptIfPresent(log: log) != nil {
        continue
      }
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

}
