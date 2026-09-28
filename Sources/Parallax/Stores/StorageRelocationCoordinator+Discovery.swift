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
      if try retirementReceipt(transactionID) != nil { continue }
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
        (try planIDs.contains(transactionID) || retirementReceipt(transactionID) != nil)
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
    // The capability-taking entry point validates startup's existing lock.
    try sweepControlState()
    let outcomes = try pendingRelocations().map {
      try recover(transactionID: $0.transactionID, repository: repository)
    }
    try sweepControlState()
    return outcomes.map { outcome in
      guard case .committed(let value) = outcome else { return outcome }
      return .committed(StorageRelocationOutcome(transactionID: value.transactionID,
        application: value.application, versionToken: value.versionToken, receiptURL: nil,
        leftoverSourcePaths: value.leftoverSourcePaths))
    }
  }

  func recover(
    transactionID: UUID,
    repository: any LibraryRepositoryPersisting
  ) throws -> StorageRelocationRecoveryOutcome {
    let plan = try loadControlPlan(transactionID)
    if let registry = activityProvider as? ProfileActivityRegistry {
      guard case .loaded(let snapshot) = repository.load(),
        let application = snapshot.applications.first(where: { $0.id == plan.unsigned.applicationID })
      else { throw StorageRelocationError(.ambiguousLibraryState) }
      let reservation: ProfileActivityReservation
      do {
        reservation = try registry.acquireDataOperationLease(identities: activityIdentities(application))
      } catch ProfileActivityRegistryError.storageReservedForDataOperation {
        throw LibraryOperationInProgressError()
      } catch ProfileActivityRegistryError.profileAlreadyActive {
        throw LibraryOperationInProgressError()
      } catch ProfileActivityRegistryError.processIdentityAmbiguous {
        throw LibraryOperationInProgressError()
      } catch DurableLaunchActivityStoreError.profileAlreadyActive {
        throw LibraryOperationInProgressError()
      } catch DurableLaunchActivityStoreError.activityBusy {
        throw LibraryOperationInProgressError()
      }
      defer { reservation.release() }
      var reserved = self
      reserved.activityProvider = reservation.activityProvider
      return try reserved.recover(transactionID: transactionID, repository: repository)
    }
    if let receipt = try loadControlReceiptIfPresent(plan: plan) {
      let outcome = try completedOutcome(receipt: receipt, plan: plan, repository: repository)
      retireCompletedPlanBestEffort(plan, receipt: receipt)
      return outcome
    }
    let libraryOutcome = repository.load()
    let primary = classifyLibrary(
      libraryOutcome,
      prior: plan.unsigned.priorVersion.libraryToken,
      target: plan.unsigned.targetVersion.libraryToken
    )
    let application = try recoveryApplication(libraryOutcome, primary: primary, plan: plan)
    // A rollback with no published destination data has no root to reopen.
    let destinationBase = URL(fileURLWithPath: plan.unsigned.destinationBasePath, isDirectory: true)
    let namespace = destinationBase.appendingPathComponent(".parallax", isDirectory: true)
    let storageID = plan.unsigned.applicationStorageID.uuidString.lowercased()
    let destinationPaths = ["Applications/" + storageID, "Archives/" + storageID,
      "Transactions/" + transactionID.uuidString.lowercased()]
    if primary == .prior, !destinationPaths.contains(where: {
      fileSystem.fileExists(at: namespace.appendingPathComponent($0))
    }) {
      try finishControlTransaction(plan: plan, completion: .rolledBack)
      return .rolledBack
    }
    let destination = try pathResolver.resolveApplication(
      configuredBaseRoot: plan.unsigned.destinationBasePath,
      applicationStorageID: plan.unsigned.applicationStorageID
    )
    guard destination.canonicalBaseRootURL.path == plan.unsigned.destinationBasePath else {
      throw StorageRelocationError(.invalidJournal)
    }
    try validateRecoveryRoot(plan.unsigned.destinationRoot, basePath: plan.unsigned.destinationBasePath)
    let destinationStaging = destination.stagingRoot(transactionID: transactionID)
    switch primary {
    case .target:
      var source: ResolvedApplicationStoragePaths?
      var applicationSnapshot: StorageRelocationOwnedTreeSnapshot?
      var archiveSnapshot: StorageRelocationOwnedTreeSnapshot?
      do {
        source = try recoverySource(plan)
        applicationSnapshot = try recoverySnapshot(plan.unsigned.sourceApplicationSnapshot, root: plan.unsigned.sourceRoot)
        archiveSnapshot = try recoverySnapshot(plan.unsigned.sourceArchiveSnapshot, root: plan.unsigned.sourceRoot)
      } catch {
        // The verified destination is authoritative. Source cleanup is best effort.
        source = nil
      }
      try synchronizeDestination(destination)
      let applicationCopy = try requireRecoveryCopy(destination.applicationRoot,
        snapshot: plan.unsigned.sourceApplicationSnapshot)
      let archiveCopy = try requireRecoveryCopy(destination.applicationArchiveRoot,
        snapshot: plan.unsigned.sourceArchiveSnapshot)
      var leftovers: [String] = []
      if let source {
        if try !removeOriginalOwned(source.applicationRoot,
          snapshot: sourceSnapshot(applicationSnapshot, verifiedCopy: applicationCopy),
          allowMissing: true, beforeRemoval: {
            try verifyPublication(plan: plan, destination: destination)
          }) { leftovers.append(source.applicationRoot.url.path) }
        if try !removeOriginalOwned(source.applicationArchiveRoot,
          snapshot: sourceSnapshot(archiveSnapshot, verifiedCopy: archiveCopy),
          allowMissing: true, beforeRemoval: {
            try verifyPublication(plan: plan, destination: destination)
          }) { leftovers.append(source.applicationArchiveRoot.url.path) }
      } else {
        let root = URL(fileURLWithPath: plan.unsigned.sourceBasePath).appendingPathComponent(".parallax")
        let id = plan.unsigned.applicationStorageID.uuidString.lowercased()
        if plan.unsigned.sourceApplicationSnapshot != nil {
          leftovers.append(root.appendingPathComponent("Applications/" + id).path)
        }
        if plan.unsigned.sourceArchiveSnapshot != nil {
          leftovers.append(root.appendingPathComponent("Archives/" + id).path)
        }
      }
      try removeIfPresent(destinationStaging)
      try finishControlTransaction(plan: plan, completion: .committed, leftoverSourcePaths: leftovers)
      return .committed(StorageRelocationOutcome(transactionID: transactionID,
        application: application, versionToken: plan.unsigned.targetVersion.libraryToken,
        receiptURL: nil, leftoverSourcePaths: leftovers))
    case .prior:
      // With no published copy, only private staging is ours to discard.
      if exists(destination.applicationRoot) || exists(destination.applicationArchiveRoot) {
        let source = try recoverySource(plan)
        let applicationSnapshot = try recoverySnapshot(plan.unsigned.sourceApplicationSnapshot, root: plan.unsigned.sourceRoot)
        let archiveSnapshot = try recoverySnapshot(plan.unsigned.sourceArchiveSnapshot, root: plan.unsigned.sourceRoot)
        try requireOriginalOwned(source.applicationRoot, snapshot: applicationSnapshot)
        try requireOriginalOwned(source.applicationArchiveRoot, snapshot: archiveSnapshot)
        try removeRecoveryCopyIfPresent(destination.applicationRoot,
          snapshot: try ownedSnapshotIfPresent(source.applicationRoot))
        try removeRecoveryCopyIfPresent(destination.applicationArchiveRoot,
          snapshot: try ownedSnapshotIfPresent(source.applicationArchiveRoot))
      }
      try removeIfPresent(destinationStaging)
      try finishControlTransaction(plan: plan, completion: .rolledBack)
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
      version: 3,
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
        try compactSnapshot(preview.sourceApplicationSnapshot),
      sourceArchiveSnapshot: try compactSnapshot(preview.sourceArchiveSnapshot),
      sourceConfiguredBasePath: preview.source.applicationRoot.validationContext.configuredBaseRootURL.path,
      sourceRoot: try StorageTransactionRootBinding.capture(pathResolver.normalizedCanonicalURL(preview.source.applicationRoot.validationContext.identityAnchorURL),
        identitySource: identitySource),
      destinationRoot: try StorageTransactionRootBinding.capture(pathResolver.normalizedCanonicalURL(preview.destination.applicationRoot.validationContext.identityAnchorURL),
        identitySource: identitySource)
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
    let bytes = try canonicalBytes(plan)
    try writeControlFileAtomically(bytes, to: path)
    do {
      _ = try loadControlPlan(plan.unsigned.transactionID)
    } catch {
      try control.removeTree(at: path)
      throw error
    }
  }

  @discardableResult
  func writeControlReceipt(
    plan: StorageRelocationControlPlan,
    completion: StorageRelocationControlCompletion,
    leftoverSourcePaths: [String] = []
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
      leftoverSourcePaths: leftoverSourcePaths.isEmpty ? nil : leftoverSourcePaths,
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
    try writeControlFileAtomically(try canonicalBytes(receipt), to: path)
    do {
      guard
        let validated = try loadControlReceiptIfPresent(plan: plan),
        validated.unsigned.completion == completion,
        validated.unsigned.transactionID
        == receipt.unsigned.transactionID,
        validated.receiptSHA256 == receipt.receiptSHA256
      else {
        throw StorageRelocationError(.invalidReceipt, path: controlURL(for: path).path)
      }
    } catch {
      try control.removeTree(at: path)
      throw error
    }
    return controlURL(for: path)
  }

  // Version 1 embedded manifests. Permit up to 256 MiB, never an unbounded read.
  static let maximumLegacyControlBytes = 256 * 1_024 * 1_024
  static let maximumControlBytes = 4 * 1_024 * 1_024

  func writeControlFileAtomically(_ bytes: Data, to path: SecureManagedPath) throws {
    guard bytes.count <= Self.maximumControlBytes else {
      throw StorageRelocationError(.invalidJournal, path: controlURL(for: path).path)
    }
    let temporary = try SecureManagedPath([".\(UUID().uuidString.lowercased()).pending"])
    defer { try? control.removeTree(at: temporary) }
    try control.write(bytes, to: temporary)
    let file = openat(control.rootDescriptor, temporary.components[0], O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard file >= 0 else { throw StorageRelocationError(.invalidJournal) }
    defer { close(file) }
    try Self.synchronizeFully(file)
    try transactionBoundary?(.beforeControlPublication(controlURL(for: path)))
    try control.rename(from: temporary, to: path)
    try Self.synchronizeFully(control.rootDescriptor)
  }

}
