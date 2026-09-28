import Foundation

extension ProfileDataTransactionCoordinator {
  func pruneCompletedTransactionsBestEffort() {
    do { try pruneCompletedTransactions() }
    catch { AppLog.persistence.error("Completed profile transaction cleanup deferred: \(error.localizedDescription)") }
  }

  struct PruningMarker: Codable {
    let receipt: Receipt
    let intent: Record
    let effect: Record
  }

  // Startup can call this even when discovery returns no pending operations.
  func performMaintenance(repository: any LibraryRepositoryPersisting, access: LibraryExclusiveAccess) throws {
    try access.validate(for: repository)
    try sweepWriteTemporaries(in: control, directory: nil, rootURL: controlRootURL)
    try pruneCompletedTransactions()
  }

  func pruningPath(_ id: UUID) throws -> SecureManagedPath {
    try SecureManagedPath([".parallax-pruning-" + id.uuidString.lowercased()])
  }

  func hasPruningMarker(_ id: UUID) throws -> Bool {
    let path = try pruningPath(id)
    guard try control.itemState(at: path) != .missing else { return false }
    let bytes = try readControlFile(path)
    do {
      let marker = try decoder.decode(PruningMarker.self, from: bytes)
      let receipt = marker.receipt
      let intent = marker.intent
      let effect = marker.effect
      guard try canonicalBytes(marker) == bytes,
        receipt.version == 1, receipt.transactionID == id,
        receipt.planSHA256.count == 64,
        intent.unsigned.version == 1, effect.unsigned.version == 1,
        intent.unsigned.transactionID == id, effect.unsigned.transactionID == id,
        intent.unsigned.planSHA256 == receipt.planSHA256, effect.unsigned.planSHA256 == receipt.planSHA256,
        intent.unsigned.sequence > 0, intent.unsigned.sequence < Int.max,
        effect.unsigned.sequence == intent.unsigned.sequence + 1,
        intent.unsigned.event == Event(phase: .intent, effect: .writeReceipt),
        effect.unsigned.event == Event(phase: .effect, effect: .writeReceipt),
        intent.recordSHA256 == LibraryPersistence.sha256(try canonicalBytes(intent.unsigned)),
        effect.recordSHA256 == LibraryPersistence.sha256(try canonicalBytes(effect.unsigned)),
        effect.unsigned.previousSHA256 == intent.recordSHA256,
        receipt.chainHeadSHA256 == intent.unsigned.previousSHA256,
        effect.unsigned.details["receiptSHA256"] == LibraryPersistence.sha256(try canonicalBytes(receipt))
      else { throw ProfileDataTransactionError(.invalidReceipt) }
      return true
    } catch {
      throw ProfileDataTransactionError(.invalidReceipt, path: controlURL(for: path).path)
    }
  }

  func finishPruning(_ id: UUID) throws {
    guard try hasPruningMarker(id) else { return }
    let prefix = id.uuidString.lowercased() + "."
    for entry in try fileSystem.contentsOfDirectory(at: controlRootURL) {
      let name = entry.lastPathComponent
      guard name.hasPrefix(prefix) else { continue }
      let isRecord: Bool
      if name.hasSuffix(".record.json"),
        let sequence = Int(name.dropFirst(prefix.count).dropLast(".record.json".count)), sequence > 0
      {
        isRecord = try controlURL(for: controlRecordPath(transactionID: id, sequence: sequence)).lastPathComponent == name
      } else { isRecord = false }
      guard name == prefix + "plan.json" || name == prefix + "receipt.json" || isRecord else { continue }
      let path = try SecureManagedPath([name])
      guard case .present(let identity) = try control.itemState(at: path), identity.kind == .regularFile else {
        throw ProfileDataTransactionError(.invalidJournal, path: entry.path)
      }
      try removeCurrentOwnedTree(path, in: control)
    }
    try removeCurrentOwnedTree(pruningPath(id), in: control)
  }

  // The pruning marker is a self-contained completion proof. Discovery can skip
  // a partially pruned transaction, and the next locked pass finishes deletion.
  func pruneCompletedTransactions() throws {
    var entries = try fileSystem.contentsOfDirectory(at: controlRootURL)
    for entry in entries where entry.lastPathComponent.hasPrefix(".parallax-pruning-") {
      guard let id = UUID(uuidString: String(entry.lastPathComponent.dropFirst(".parallax-pruning-".count))),
        try controlURL(for: pruningPath(id)).lastPathComponent == entry.lastPathComponent
      else { throw ProfileDataTransactionError(.invalidJournal, path: entry.path) }
      try finishPruning(id)
    }
    entries = try fileSystem.contentsOfDirectory(at: controlRootURL)
    let grouped = Dictionary(grouping: entries) { String($0.lastPathComponent.prefix(36)) }
    var completed: [(UUID, Receipt, [URL])] = []
    for entry in entries where entry.lastPathComponent.hasSuffix(".plan.json") {
      guard let id = UUID(uuidString: String(entry.lastPathComponent.dropLast(".plan.json".count))) else { continue }
      let files = grouped[id.uuidString.lowercased()] ?? []
      if try completedReceiptIfPresent(transactionID: id, entries: files) {
        let receipt = try decoder.decode(Receipt.self, from: readControlFile(controlReceiptPath(id)))
        completed.append((id, receipt, files))
      }
    }
    completed.sort {
      $0.1.completedAt == $1.1.completedAt
        ? $0.0.uuidString > $1.0.uuidString : $0.1.completedAt > $1.1.completedAt
    }
    for (id, receipt, files) in completed.dropFirst(Self.retainedCompletedTransactions) {
      let sequences = files.compactMap { url -> Int? in
        let name = url.lastPathComponent
        guard name.hasSuffix(".record.json") else { return nil }
        return Int(name.dropFirst(37).dropLast(".record.json".count))
      }
      guard let last = sequences.max(), last > 1 else { throw ProfileDataTransactionError(.invalidReceipt) }
      let intent = try decoder.decode(Record.self, from: readControlFile(controlRecordPath(transactionID: id, sequence: last - 1)))
      let effect = try decoder.decode(Record.self, from: readControlFile(controlRecordPath(transactionID: id, sequence: last)))
      let marker = PruningMarker(receipt: receipt, intent: intent, effect: effect)
      try writeAtomically(canonicalBytes(marker), in: control, to: pruningPath(id))
      try finishPruning(id)
    }
  }
}
