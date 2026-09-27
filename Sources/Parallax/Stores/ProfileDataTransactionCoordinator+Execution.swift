import Darwin
import Foundation

// MARK: - Planning and execution

extension ProfileDataTransactionCoordinator {
  func preparePlan(
    request: ProfileDataTransactionRequest,
    preparedCommit: PreparedLibraryCommit
  ) throws -> TransactionLog {
    let sourceBinding = try rootBinding(
      for: request.source.profileRoot.validationContext
    )
    let sourcePath = try securePath(
      request.source.profileRoot.url,
      relativeTo: sourceBinding.url
    )
    let archivePath =
      request.operation == .archive
        || request.operation == .clear
      ? try securePath(
        request.source.archiveEntry(
          timestamp: now(),
          nonce: request.transactionID
        ).url,
        relativeTo: sourceBinding.url
      )
      : nil

    let destinationBinding: RootBinding?
    let destinationPath: PathValue?
    if let destination = request.destination {
      destinationBinding = try rootBinding(
        for: destination.profileRoot.validationContext
      )
      destinationPath = PathValue(
        try securePath(
          destination.profileRoot.url,
          relativeTo: destinationBinding?.url
            ?? destination.profileRoot.validationContext.canonicalBaseRootURL
        )
      )
    } else {
      destinationBinding = nil
      destinationPath = nil
    }

    let sourceFS = try secureFileSystem(for: sourceBinding)
    let sourceSnapshot = try snapshot(at: sourcePath, in: sourceFS)
    if let destinationBinding, let destinationPath {
      let destinationFS = try secureFileSystem(for: destinationBinding)
      guard try destinationFS.itemState(at: destinationPath.value) == .missing else {
        throw ProfileDataTransactionError(
          .unexpectedDestination,
          operation: request.operation,
          path: request.destination?.profileRoot.url.path
        )
      }
    }
    if let archivePath {
      guard try sourceFS.itemState(at: archivePath) == .missing else {
        throw ProfileDataTransactionError(
          .unexpectedDestination,
          operation: request.operation,
          path: request.source.archiveRoot.url.path
        )
      }
    }

    let transactionComponent = request.transactionID.uuidString.lowercased()
    let hostBinding = destinationBinding ?? sourceBinding
    let stagePath = try SecureManagedPath([
      ".parallax",
      "Transactions",
      transactionComponent,
    ])
    let stageOwnerPath = try SecureManagedPath([
      ".parallax",
      "Transactions",
      transactionComponent + ".owner",
    ])
    let payloadPath = try stagePath.appending("payload")
    let payloadOwnerPath = try payloadPath.appending(
      Self.payloadOwnerPrefix + transactionComponent
    )

    let createdAt = now()
    let preparedIdentifier = preparedCommitIdentifier(
      request: request,
      preparedCommit: preparedCommit
    )
    let plan = Plan(
      version: 3,
      transactionID: request.transactionID,
      identity: request.identity,
      operation: request.operation,
      createdAt: createdAt,
      sourceRoot: sourceBinding,
      sourcePath: PathValue(sourcePath),
      sourceSnapshot: sourceSnapshot,
      destinationRoot: destinationBinding,
      destinationPath: destinationPath,
      archivePath: archivePath.map(PathValue.init),
      hostRoot: hostBinding,
      stagePath: PathValue(stagePath),
      stageOwnerPath: PathValue(stageOwnerPath),
      payloadPath: PathValue(payloadPath),
      payloadOwnerPath: PathValue(payloadOwnerPath),
      priorVersion: TokenValue(preparedCommit.priorVersion),
      targetVersion: TokenValue(preparedCommit.targetVersion),
      targetBytesSHA256: LibraryPersistence.sha256(
        preparedCommit.targetBytes
      ),
      preparedCommitIdentifier: preparedIdentifier,
      externalDataHandling: request.externalDataHandling
    )
    let planBytes = try canonicalBytes(plan)
    let planHash = LibraryPersistence.sha256(planBytes)
    return TransactionLog(
      plan: plan,
      planBytes: planBytes,
      planHash: planHash,
      records: []
    )
  }

  func publishPlan(_ log: TransactionLog) throws {
    let path = try controlPlanPath(log.plan.transactionID)
    guard try control.itemState(at: path) == .missing else {
      throw ProfileDataTransactionError(
        .unexpectedDestination,
        operation: log.plan.operation,
        path: controlURL(for: path).path
      )
    }
    try writeAtomically(log.planBytes, in: control, to: path)
  }

  func prepareOwnedStaging(
    log: inout TransactionLog,
    hostFS: SecureManagedFileSystem
  ) throws {
    let parent = try SecureManagedPath(
      Array(log.plan.stagePath.value.components.dropLast())
    )
    if try hostFS.itemState(at: parent) == .missing {
      _ = try perform(.createTransactionsDirectory, log: &log) {
        try hostFS.createDirectory(at: parent)
        return try snapshotDetails(at: parent, in: hostFS)
      }
    }

    let ownerBytes = try canonicalBytes(
      OwnerMarker(
        version: 1,
        transactionID: log.plan.transactionID,
        planSHA256: log.planHash
      )
    )
    let stageOwnerPath = log.plan.stageOwnerPath.value
    if try hostFS.itemState(at: stageOwnerPath) == .missing {
      _ = try perform(.writeOwnerMarker, log: &log) {
        try writeAtomically(ownerBytes, in: hostFS, to: stageOwnerPath)
        return [
          "ownerSHA256": LibraryPersistence.sha256(ownerBytes)
        ].merging(
          try snapshotDetails(
            at: stageOwnerPath,
            in: hostFS
          )
        ) { _, new in new }
      }
    } else {
      try requireOwner(log: log, hostFS: hostFS)
    }

    let stagePath = log.plan.stagePath.value
    if try hostFS.itemState(at: stagePath) == .missing {
      _ = try perform(.createStaging, log: &log) {
        try hostFS.createDirectory(at: stagePath)
        return try snapshotDetails(
          at: stagePath,
          in: hostFS
        )
      }
    }
  }

  func applyData(
    log: inout TransactionLog,
    sourceFS: SecureManagedFileSystem,
    destinationFS: SecureManagedFileSystem?
  ) throws -> ProfileDataMutation {
    guard log.plan.sourceSnapshot != nil else {
      return .noManagedData
    }
    let hostFS = destinationFS ?? sourceFS
    let sourcePath = log.plan.sourcePath.value
    let payloadPath = log.plan.payloadPath.value
    switch log.plan.operation {
    case .archive, .clear, .delete:
      if try hostFS.itemState(at: payloadPath) == .missing {
        _ = try perform(.moveToStaging, log: &log) {
          try sourceFS.rename(
            from: sourcePath,
            to: payloadPath
          )
          return try snapshotDetails(
            at: payloadPath,
            in: hostFS
          )
        }
      }
    case .duplicate, .relocate:
      if try hostFS.itemState(at: payloadPath) == .missing {
        _ = try perform(.copyToStaging, log: &log) {
          try sourceFS.copyTree(
            from: sourcePath,
            to: payloadPath,
            in: hostFS
          )
          return try snapshotDetails(
            at: payloadPath,
            in: hostFS
          )
        }
      }
    }

    try writePayloadOwnerIfNeeded(log: &log, hostFS: hostFS)

    switch log.plan.operation {
    case .archive, .clear:
      guard let archive = log.plan.archivePath?.value else {
        throw ProfileDataTransactionError(.invalidJournal)
      }
      if try sourceFS.itemState(at: archive) == .missing {
        let payloadPath = log.plan.payloadPath.value
        _ = try perform(.publishArchive, log: &log) {
          try sourceFS.rename(
            from: payloadPath,
            to: archive
          )
          return try snapshotDetails(at: archive, in: sourceFS)
        }
      }
      return .archivedManagedData
    case .delete:
      return .deletedManagedData
    case .duplicate:
      guard
        let destinationFS,
        let destination = log.plan.destinationPath?.value
      else {
        throw ProfileDataTransactionError(.invalidJournal)
      }
      if try destinationFS.itemState(at: destination) == .missing {
        let payloadPath = log.plan.payloadPath.value
        _ = try perform(.publishDestination, log: &log) {
          try destinationFS.rename(
            from: payloadPath,
            to: destination
          )
          return try snapshotDetails(
            at: destination,
            in: destinationFS
          )
        }
      }
      return .copiedManagedData
    case .relocate:
      guard
        let destinationFS,
        let destination = log.plan.destinationPath?.value
      else {
        throw ProfileDataTransactionError(.invalidJournal)
      }
      if try destinationFS.itemState(at: destination) == .missing {
        let payloadPath = log.plan.payloadPath.value
        _ = try perform(.publishDestination, log: &log) {
          try destinationFS.rename(
            from: payloadPath,
            to: destination
          )
          return try snapshotDetails(
            at: destination,
            in: destinationFS
          )
        }
      }
      return .relocatedManagedData
    }
  }

  func writePayloadOwnerIfNeeded(
    log: inout TransactionLog,
    hostFS: SecureManagedFileSystem
  ) throws {
    let payloadOwner = payloadOwnerPath(for: log, published: false)
    if try hostFS.itemState(at: payloadOwner) != .missing {
      try requirePayloadOwner(log: log, fileSystem: hostFS, at: payloadOwner)
      return
    }
    let bytes = try canonicalBytes(
      OwnerMarker(
        version: 1,
        transactionID: log.plan.transactionID,
        planSHA256: log.planHash
      )
    )
    let payloadPath = log.plan.payloadPath.value
    let stagePath = log.plan.stagePath.value
    _ = try perform(.writePayloadMarker, log: &log) {
      try writeAtomically(bytes, in: hostFS, to: payloadOwner, temporaryDirectory: stagePath)
      return [
        "ownerSHA256": LibraryPersistence.sha256(bytes)
      ].merging(
        try snapshotDetails(at: payloadPath, in: hostFS)
      ) { _, new in new }
    }
  }

}
