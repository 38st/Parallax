import Darwin
import Foundation

// MARK: - Discovery and control-state recovery

extension StorageRelocationCoordinator {
  func pendingRelocations() throws -> [PendingStorageRelocation] {
    try validateControlRoot()
    let entries = try fileSystem.contentsOfDirectory(at: controlRootURL)
    let planSuffix = ".plan.json"
    var pending: [PendingStorageRelocation] = []
    var planIDs = Set<UUID>()
    for entry
      in entries
      .filter({ $0.lastPathComponent.hasSuffix(planSuffix) })
      .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    {
      let rawID = String(
        entry.lastPathComponent.dropLast(planSuffix.count)
      )
      guard
        let transactionID = UUID(uuidString: rawID),
        transactionID.uuidString.lowercased() == rawID
      else {
        throw StorageRelocationError(
          .invalidJournal,
          path: entry.path
        )
      }
      planIDs.insert(transactionID)
      let plan = try loadControlPlan(transactionID)
      if try loadControlReceiptIfPresent(plan: plan) != nil {
        continue
      }
      pending.append(
        PendingStorageRelocation(
          transactionID: transactionID,
          applicationID: plan.unsigned.applicationID,
          applicationStorageID:
            plan.unsigned.applicationStorageID,
          sourceBasePath: plan.unsigned.sourceBasePath,
          destinationBasePath:
            plan.unsigned.destinationBasePath,
          createdAt: plan.unsigned.createdAt
        )
      )
    }
    for entry in entries
    where
      entry.lastPathComponent.hasSuffix(".receipt.json")
    {
      let rawID = String(
        entry.lastPathComponent.dropLast(".receipt.json".count)
      )
      guard
        let transactionID = UUID(uuidString: rawID),
        transactionID.uuidString.lowercased() == rawID,
        planIDs.contains(transactionID)
      else {
        throw StorageRelocationError(
          .invalidJournal,
          path: entry.path
        )
      }
    }
    try validateControlRoot()
    return pending.sorted {
      if $0.createdAt == $1.createdAt {
        return $0.transactionID.uuidString
          < $1.transactionID.uuidString
      }
      return $0.createdAt < $1.createdAt
    }
  }

  func recoverAll(
    repository: any LibraryRepositoryPersisting
  ) throws -> [StorageRelocationRecoveryOutcome] {
    try pendingRelocations().map {
      try recover(
        transactionID: $0.transactionID,
        repository: repository
      )
    }
  }

  func recover(
    transactionID: UUID,
    repository: any LibraryRepositoryPersisting
  ) throws -> StorageRelocationRecoveryOutcome {
    let plan = try loadControlPlan(transactionID)
    if let receipt = try loadControlReceiptIfPresent(plan: plan) {
      return try completedOutcome(
        receipt: receipt,
        plan: plan,
        repository: repository
      )
    }
    let source = try pathResolver.resolveApplication(
      configuredBaseRoot: plan.unsigned.sourceBasePath,
      applicationStorageID: plan.unsigned.applicationStorageID
    )
    let destination = try pathResolver.resolveApplication(
      configuredBaseRoot: plan.unsigned.destinationBasePath,
      applicationStorageID: plan.unsigned.applicationStorageID
    )
    guard
      source.canonicalBaseRootURL.path
        == plan.unsigned.sourceBasePath,
      destination.canonicalBaseRootURL.path
        == plan.unsigned.destinationBasePath
    else {
      throw StorageRelocationError(.invalidJournal)
    }
    let libraryOutcome = repository.load()
    let primary = classifyLibrary(
      libraryOutcome,
      prior: plan.unsigned.priorVersion.libraryToken,
      target: plan.unsigned.targetVersion.libraryToken
    )
    let application = try recoveryApplication(
      libraryOutcome,
      primary: primary,
      plan: plan
    )
    let destinationStaging = destination.stagingRoot(
      transactionID: transactionID
    )
    let stagedApplication = child(
      "Application",
      in: destinationStaging
    )
    let stagedArchives = child("Archives", in: destinationStaging)

    switch primary {
    case .target:
      try requireRecoveryCopy(
        destination.applicationRoot,
        snapshot: plan.unsigned.sourceApplicationSnapshot
      )
      try requireRecoveryCopy(
        destination.applicationArchiveRoot,
        snapshot: plan.unsigned.sourceArchiveSnapshot
      )
      try removeOriginalOwned(
        source.applicationRoot,
        snapshot: plan.unsigned.sourceApplicationSnapshot,
        allowMissing: true
      )
      try removeOriginalOwned(
        source.applicationArchiveRoot,
        snapshot: plan.unsigned.sourceArchiveSnapshot,
        allowMissing: true
      )
      try removeIfPresent(destinationStaging)
      let receiptURL = try writeControlReceipt(
        plan: plan,
        completion: .committed
      )
      return .committed(
        StorageRelocationOutcome(
          transactionID: transactionID,
          application: application,
          versionToken: plan.unsigned.targetVersion.libraryToken,
          receiptURL: receiptURL
        )
      )
    case .prior:
      try requireOriginalOwned(
        source.applicationRoot,
        snapshot: plan.unsigned.sourceApplicationSnapshot
      )
      try requireOriginalOwned(
        source.applicationArchiveRoot,
        snapshot: plan.unsigned.sourceArchiveSnapshot
      )
      try removeRecoveryCopyIfPresent(
        destination.applicationRoot,
        snapshot: plan.unsigned.sourceApplicationSnapshot
      )
      try removeRecoveryCopyIfPresent(
        destination.applicationArchiveRoot,
        snapshot: plan.unsigned.sourceArchiveSnapshot
      )
      try removeRecoveryCopyIfPresent(
        stagedApplication,
        snapshot: plan.unsigned.sourceApplicationSnapshot
      )
      try removeRecoveryCopyIfPresent(
        stagedArchives,
        snapshot: plan.unsigned.sourceArchiveSnapshot
      )
      try removeIfPresent(destinationStaging)
      _ = try writeControlReceipt(
        plan: plan,
        completion: .rolledBack
      )
      return .rolledBack
    case .neither:
      throw StorageRelocationError(
        .ambiguousLibraryState,
        path: controlURL(
          for: try controlPlanPath(transactionID)
        ).path
      )
    }
  }

  func makeControlPlan(
    preview: StorageRelocationPreview,
    preparedCommit: PreparedLibraryCommit
  ) throws -> StorageRelocationControlPlan {
    let unsigned = StorageRelocationControlPlan.Unsigned(
      version: 1,
      transactionID: preview.requestID,
      applicationID: preview.applicationID,
      applicationStorageID: preview.applicationStorageID,
      createdAt: now(),
      priorVersion: StorageRelocationVersionToken(
        preparedCommit.priorVersion
      ),
      targetVersion: StorageRelocationVersionToken(
        preparedCommit.targetVersion
      ),
      originalApplicationSHA256: try applicationSHA256(
        preview.originalApplication
      ),
      relocatedApplicationSHA256: try applicationSHA256(
        preview.relocatedApplication
      ),
      sourceBasePath: preview.source.canonicalBaseRootURL.path,
      destinationBasePath:
        preview.destination.canonicalBaseRootURL.path,
      sourceApplicationFingerprint:
        preview.sourceApplicationFingerprint,
      sourceArchiveFingerprint:
        preview.sourceArchiveFingerprint,
      sourceApplicationSnapshot:
        preview.sourceApplicationSnapshot,
      sourceArchiveSnapshot: preview.sourceArchiveSnapshot
    )
    return StorageRelocationControlPlan(
      unsigned: unsigned,
      planSHA256: LibraryPersistence.sha256(
        try canonicalBytes(unsigned)
      )
    )
  }

  func writeControlPlan(
    _ plan: StorageRelocationControlPlan
  ) throws {
    try validateControlRoot()
    let path = try controlPlanPath(plan.unsigned.transactionID)
    guard
      try control.itemState(at: path) == .missing,
      try control.itemState(
        at: controlReceiptPath(plan.unsigned.transactionID)
      ) == .missing
    else {
      throw StorageRelocationError(
        .unexpectedDestination,
        path: controlURL(for: path).path
      )
    }
    try control.write(try canonicalBytes(plan), to: path)
    _ = try loadControlPlan(plan.unsigned.transactionID)
  }

  @discardableResult
  func writeControlReceipt(
    plan: StorageRelocationControlPlan,
    completion: StorageRelocationControlCompletion
  ) throws -> URL {
    try transactionBoundary?(
      .beforeCompletionReceipt(plan.unsigned.transactionID)
    )
    let unsigned = StorageRelocationControlReceipt.Unsigned(
      version: 1,
      transactionID: plan.unsigned.transactionID,
      planSHA256: plan.planSHA256,
      completion: completion,
      completedAt: now(),
      priorVersion: plan.unsigned.priorVersion,
      targetVersion: plan.unsigned.targetVersion
    )
    let receipt = StorageRelocationControlReceipt(
      unsigned: unsigned,
      receiptSHA256: LibraryPersistence.sha256(
        try canonicalBytes(unsigned)
      )
    )
    let path = try controlReceiptPath(plan.unsigned.transactionID)
    guard try control.itemState(at: path) == .missing else {
      if let existing = try loadControlReceiptIfPresent(plan: plan),
        existing.unsigned.completion == completion
      {
        return controlURL(for: path)
      }
      throw StorageRelocationError(
        .invalidReceipt,
        path: controlURL(for: path).path
      )
    }
    try control.write(try canonicalBytes(receipt), to: path)
    guard
      let validated = try loadControlReceiptIfPresent(plan: plan),
      validated.unsigned.completion == completion,
      validated.unsigned.transactionID
        == receipt.unsigned.transactionID,
      validated.receiptSHA256 == receipt.receiptSHA256
    else {
      throw StorageRelocationError(
        .invalidReceipt,
        path: controlURL(for: path).path
      )
    }
    return controlURL(for: path)
  }

}
