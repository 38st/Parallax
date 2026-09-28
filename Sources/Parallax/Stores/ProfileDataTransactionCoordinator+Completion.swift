import Darwin
import Foundation

extension ProfileDataTransactionCoordinator {
  func finalizeCommittedData(
    log: inout TransactionLog,
    sourceFS: SecureManagedFileSystem,
    destinationFS: SecureManagedFileSystem?
  ) throws {
    let hostFS = destinationFS ?? sourceFS
    switch log.plan.operation {
    case .archive, .clear:
      guard let archive = log.plan.archivePath?.value else {
        throw ProfileDataTransactionError(.invalidJournal)
      }
      try removePayloadOwnerIfPresent(
        log: &log,
        fileSystem: sourceFS,
        container: archive
      )
    case .delete:
      let payloadPath = log.plan.payloadPath.value
      if try hostFS.itemState(at: payloadPath) != .missing {
        try requireRemovalOwner(
          log: log, fileSystem: hostFS,
          container: payloadPath, effect: .removeDeletedPayload
        )
        _ = try perform(.removeDeletedPayload, log: &log) {
          try removeCurrentOwnedTree(
            payloadPath,
            in: hostFS
          )
          return [:]
        }
      }
    case .duplicate:
      guard
        let destinationFS,
        let destination = log.plan.destinationPath?.value
      else {
        throw ProfileDataTransactionError(.invalidJournal)
      }
      try removePayloadOwnerIfPresent(
        log: &log,
        fileSystem: destinationFS,
        container: destination
      )
    case .relocate:
      guard
        let destinationFS,
        let destination = log.plan.destinationPath?.value
      else {
        throw ProfileDataTransactionError(.invalidJournal)
      }
      try removePayloadOwnerIfPresent(
        log: &log,
        fileSystem: destinationFS,
        container: destination
      )
      if let sourceSnapshot = log.plan.sourceSnapshot,
        try sourceFS.itemState(at: log.plan.sourcePath.value) != .missing
      {
        let sourcePath = log.plan.sourcePath.value
        let acceptsDeviceChange = log.plan.sourceRoot.identityVersion == 1
        _ = try perform(.removeRelocatedSource, log: &log) {
          let manifest = try sourceFS.manifest(at: sourcePath)
          guard try sourceSnapshot.matches(manifest) else {
            throw ProfileDataTransactionError(.sourceChanged)
          }
          guard case .present(let current) = try sourceFS.itemState(at: sourcePath),
            current.fileID == sourceSnapshot.identity.fileID,
            current.kind == sourceSnapshot.identity.value.kind,
            acceptsDeviceChange || current == sourceSnapshot.identity.value
          else { throw ProfileDataTransactionError(.sourceChanged) }
          try sourceFS.removeOwnedTree(
            at: sourcePath,
            expectedIdentity: current,
            expectedManifest: manifest
          )
          return [:]
        }
      }
    }
  }

  func rollBackData(
    log: inout TransactionLog,
    sourceFS: SecureManagedFileSystem,
    destinationFS: SecureManagedFileSystem?
  ) throws {
    guard log.plan.sourceSnapshot != nil else { return }
    let hostFS = destinationFS ?? sourceFS
    switch log.plan.operation {
    case .archive, .clear:
      guard let archive = log.plan.archivePath?.value else {
        throw ProfileDataTransactionError(.invalidJournal)
      }
      if try sourceFS.itemState(at: archive) != .missing {
        try requirePayloadOwner(
          log: log,
          fileSystem: sourceFS,
          at: payloadOwnerPath(
            for: log,
            publishedContainer: archive
          )
        )
        try requireMissing(log.plan.sourcePath.value, in: sourceFS)
        try sourceFS.rename(
          from: archive,
          to: log.plan.sourcePath.value
        )
        try removePayloadOwnerIfPresent(
          log: &log,
          fileSystem: sourceFS,
          container: log.plan.sourcePath.value
        )
      } else if try hostFS.itemState(at: log.plan.payloadPath.value) != .missing {
        try requireOwner(log: log, hostFS: hostFS)
        try requireMissing(log.plan.sourcePath.value, in: sourceFS)
        try sourceFS.rename(
          from: log.plan.payloadPath.value,
          to: log.plan.sourcePath.value
        )
        try removePayloadOwnerIfPresent(
          log: &log,
          fileSystem: sourceFS,
          container: log.plan.sourcePath.value
        )
      }
      if try sourceFS.itemState(at: log.plan.sourcePath.value) != .missing {
        try removePayloadOwnerIfPresent(
          log: &log,
          fileSystem: sourceFS,
          container: log.plan.sourcePath.value
        )
      }
    case .delete:
      if try hostFS.itemState(at: log.plan.payloadPath.value) != .missing {
        try requireOwner(log: log, hostFS: hostFS)
        try requireMissing(log.plan.sourcePath.value, in: sourceFS)
        try sourceFS.rename(
          from: log.plan.payloadPath.value,
          to: log.plan.sourcePath.value
        )
        try removePayloadOwnerIfPresent(
          log: &log,
          fileSystem: sourceFS,
          container: log.plan.sourcePath.value
        )
      }
      if try sourceFS.itemState(at: log.plan.sourcePath.value) != .missing {
        try removePayloadOwnerIfPresent(
          log: &log,
          fileSystem: sourceFS,
          container: log.plan.sourcePath.value
        )
      }
    case .duplicate, .relocate:
      if let destinationFS,
        let destination = log.plan.destinationPath?.value,
        try destinationFS.itemState(at: destination) != .missing
      {
        if log.hasEvent(.publishDestination) {
          try requireRemovalOwner(
            log: log, fileSystem: destinationFS,
            container: destination, effect: .removeDuplicateDestination
          )
          _ = try perform(.removeDuplicateDestination, log: &log) {
            try removeCurrentOwnedTree(destination, in: destinationFS)
            return [:]
          }
        }
      }
      if try hostFS.itemState(at: log.plan.payloadPath.value) != .missing {
        try requireOwner(log: log, hostFS: hostFS)
        try removeCurrentOwnedTree(log.plan.payloadPath.value, in: hostFS)
      }
    }
  }

  func cleanupOwnedStaging(
    log: inout TransactionLog,
    hostFS: SecureManagedFileSystem
  ) throws {
    let stageState = try hostFS.itemState(at: log.plan.stagePath.value)
    if case .present = stageState {
      try requireOwner(log: log, hostFS: hostFS)
      let stagePath = log.plan.stagePath.value
      _ = try perform(.removeStaging, log: &log) {
        try removeCurrentOwnedTree(stagePath, in: hostFS)
        return [:]
      }
    }

    if try hostFS.itemState(at: log.plan.stageOwnerPath.value) != .missing {
      try requireOwner(log: log, hostFS: hostFS)
      let stageOwnerPath = log.plan.stageOwnerPath.value
      _ = try perform(.removeOwnerMarker, log: &log) {
        try removeCurrentOwnedTree(
          stageOwnerPath,
          in: hostFS
        )
        return [:]
      }
    }
  }

  func complete(
    log: inout TransactionLog,
    mutation: ProfileDataMutation,
    completion: Completion
  ) throws -> ProfileDataTransactionOutcome {
    if let existing = try validatedReceiptIfPresent(log: log) {
      return outcome(
        from: existing,
        plan: log.plan
      )
    }
    let receipt = Receipt(
      version: 1,
      transactionID: log.plan.transactionID,
      planSHA256: log.planHash,
      chainHeadSHA256: log.chainHead,
      identity: log.plan.identity,
      operation: log.plan.operation,
      completion: completion,
      dataMutation: mutation,
      externalDataHandling: log.plan.externalDataHandling,
      priorVersion: log.plan.priorVersion,
      targetVersion: log.plan.targetVersion,
      completedAt: now()
    )
    let bytes = try canonicalBytes(receipt)
    let hash = LibraryPersistence.sha256(bytes)
    let transactionID = log.plan.transactionID
    _ = try perform(.writeReceipt, log: &log) {
      try writeAtomically(
        bytes,
        in: control,
        to: try controlReceiptPath(transactionID)
      )
      return ["receiptSHA256": hash]
    }
    let validated = try validatedReceiptIfPresent(log: log)
    guard let validated else {
      throw ProfileDataTransactionError(.invalidReceipt)
    }
    return outcome(
      from: validated,
      plan: log.plan
    )
  }

}
