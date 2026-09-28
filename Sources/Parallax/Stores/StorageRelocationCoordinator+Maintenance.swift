import Foundation

extension StorageRelocationCoordinator {
  /// Call on every startup, even when discovery finds no unfinished plans.
  func maintainControlState(
    repository: any LibraryRepositoryPersisting,
    access: LibraryExclusiveAccess
  ) throws {
    try access.validate(for: repository)
    try sweepControlState()
  }

  // Also used by the existing lock-held recoverAll body.
  func sweepControlState() throws {
    try validateControlRoot()
    for entry in try fileSystem.contentsOfDirectory(at: controlRootURL) {
      let name = entry.lastPathComponent
      if let id = privateControlID(name, suffix: ".pending") {
        let path = try SecureManagedPath([".\(id.uuidString.lowercased()).pending"])
        if case .present(let identity) = try control.itemState(at: path), identity.kind == .regularFile {
          try control.removeTree(at: path)
        }
      }
      if let id = privateControlID(name, suffix: ".retired"),
        let receipt = try retirementReceipt(id) {
        try finishRetirement(receipt)
      }
    }
    for entry in try fileSystem.contentsOfDirectory(at: controlRootURL)
    where entry.lastPathComponent.hasSuffix(".plan.json") {
      let raw = String(entry.lastPathComponent.dropLast(".plan.json".count))
      guard let id = UUID(uuidString: raw), raw == id.uuidString.lowercased() else {
        throw StorageRelocationError(.invalidJournal, path: entry.path)
      }
      let plan = try loadControlPlan(id)
      guard let receipt = try loadControlReceiptIfPresent(plan: plan) else { continue }
      // This durable marker makes interruption between the two removals safe.
      try retireCompletedPlan(plan, receipt: receipt)
    }
    try validateControlRoot()
  }

  func retirementReceipt(_ id: UUID) throws -> StorageRelocationControlReceipt? {
    let marker = try privateControlPath(id, suffix: ".retired")
    guard try control.itemState(at: marker) != .missing else { return nil }
    return try verifiedMaintenanceReceipt(marker, transactionID: id)
  }

  func verifiedMaintenanceReceipt(_ path: SecureManagedPath, transactionID: UUID) throws -> StorageRelocationControlReceipt {
    let bytes = try readControlFile(path)
    let receipt = try decoder.decode(StorageRelocationControlReceipt.self, from: bytes)
    guard receipt.unsigned.version == 1, receipt.unsigned.transactionID == transactionID,
      try canonicalBytes(receipt) == bytes,
      receipt.receiptSHA256 == LibraryPersistence.sha256(try canonicalBytes(receipt.unsigned)) else {
      throw StorageRelocationError(.invalidReceipt)
    }
    return receipt
  }

  func finishRetirement(_ receipt: StorageRelocationControlReceipt) throws {
    let id = receipt.unsigned.transactionID
    let planPath = try controlPlanPath(id)
    if try control.itemState(at: planPath) != .missing {
      let plan = try loadControlPlan(id)
      guard plan.planSHA256 == receipt.unsigned.planSHA256,
        plan.unsigned.priorVersion == receipt.unsigned.priorVersion,
        plan.unsigned.targetVersion == receipt.unsigned.targetVersion else { throw StorageRelocationError(.invalidReceipt) }
      if let existing = try loadControlReceiptIfPresent(plan: plan), existing.receiptSHA256 != receipt.receiptSHA256 {
        throw StorageRelocationError(.invalidReceipt)
      }
    }
    let receiptPath = try controlReceiptPath(id)
    if try control.itemState(at: receiptPath) != .missing {
      guard try verifiedMaintenanceReceipt(receiptPath, transactionID: id).receiptSHA256 == receipt.receiptSHA256 else {
        throw StorageRelocationError(.invalidReceipt)
      }
    }
    // Informational notices are not authority for transaction recovery.
    if !(receipt.unsigned.leftoverSourcePaths ?? []).isEmpty {
      let notice = try privateControlPath(id, suffix: ".leftovers")
      if try control.itemState(at: notice) == .missing {
        try writeControlFileAtomically(canonicalBytes(receipt), to: notice)
      }
    }
    for path in [try controlReceiptPath(id), planPath] {
      if try control.itemState(at: path) != .missing { try control.removeTree(at: path) }
    }
    // Keep the completion proof until both removals have reached stable storage.
    try Self.synchronizeFully(control.rootDescriptor)
    try transactionBoundary?(.beforeRetirementMarkerRemoval(id))
    try control.removeTree(at: privateControlPath(id, suffix: ".retired"))
  }

  func recordedLeftoverNotices() throws -> [UUID: [String]] {
    var notices: [UUID: [String]] = [:]
    for url in try fileSystem.contentsOfDirectory(at: controlRootURL) {
      guard let id = privateControlID(url.lastPathComponent, suffix: ".leftovers") else { continue }
      guard let receipt = try? verifiedMaintenanceReceipt(privateControlPath(id, suffix: ".leftovers"), transactionID: id) else {
        AppLog.persistence.error("Could not read a storage relocation leftover notice.")
        continue
      }
      notices[id] = receipt.unsigned.leftoverSourcePaths ?? []
    }
    return notices
  }

  func recordedLeftoverSourcePaths() throws -> [String] {
    try recordedLeftoverNotices().values.flatMap { $0 }.sorted()
  }

  func retireLeftoverNotices(_ ids: Set<UUID>, repository: any LibraryRepositoryPersisting) throws {
    let result = try repository.tryWithExclusiveAccess { access in
      try access.validate(for: repository)
      // Finish any interrupted retirement before removing its informational copy.
      try sweepControlState()
      for id in ids {
        let path = try privateControlPath(id, suffix: ".leftovers")
        if case .present(let identity) = try control.itemState(at: path) {
          guard identity.kind == .regularFile else { throw StorageRelocationError(.invalidReceipt) }
          try control.removeTree(at: path)
        }
      }
      try Self.synchronizeFully(control.rootDescriptor)
    }
    if case .busy = result { throw LibraryOperationInProgressError() }
  }

  func privateControlID(_ name: String, suffix: String) -> UUID? {
    guard name.hasPrefix("."), name.hasSuffix(suffix) else { return nil }
    let raw = String(name.dropFirst().dropLast(suffix.count))
    guard let id = UUID(uuidString: raw), raw == id.uuidString.lowercased() else { return nil }
    return id
  }

  func privateControlPath(_ id: UUID, suffix: String) throws -> SecureManagedPath {
    try SecureManagedPath([".\(id.uuidString.lowercased())\(suffix)"])
  }
}
