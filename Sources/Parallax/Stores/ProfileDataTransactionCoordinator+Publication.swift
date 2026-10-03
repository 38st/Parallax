import Foundation

extension ProfileDataTransactionCoordinator {
  func writeAtomically(
    _ bytes: Data,
    in fileSystem: SecureManagedFileSystem,
    to path: SecureManagedPath,
    temporaryDirectory: SecureManagedPath? = nil
  ) throws {
    let temporary = try SecureManagedPath(
      (temporaryDirectory?.components ?? Array(path.components.dropLast())) + [".parallax-write-" + UUID().uuidString.lowercased()]
    )
    do {
      try fileSystem.write(bytes, to: temporary)
      try fileSystem.rename(from: temporary, to: path)
    } catch {
      // Only the final name is authoritative. A crash can leave a partial
      // temporary file, but discovery never interprets it as a journal.
      try? removeCurrentOwnedTree(temporary, in: fileSystem)
      throw error
    }
  }

  func requireRemovalOwner(
    log: TransactionLog,
    fileSystem: SecureManagedFileSystem,
    container: SecureManagedPath,
    effect: ProfileDataTransactionEffect
  ) throws {
    // The payload directory survives a partial recursive deletion. Bind the
    // continuation to its recorded identity, even after its marker is gone.
    let expected: IdentityValue?
    if effect == .removeDeletedPayload {
      expected = log.plan.sourceSnapshot?.identity
    } else {
      let record = log.records.last {
        $0.unsigned.event.phase == .effect
          && ($0.unsigned.event.effect == .publishDestination
            || $0.unsigned.event.effect == .writePayloadMarker)
      }
      if let record, let value = record.unsigned.details["identity"], let bytes = Data(base64Encoded: value) {
        do { expected = try decoder.decode(IdentityValue.self, from: bytes) }
        catch {
          throw ProfileDataTransactionError(.invalidJournal,
            path: controlURL(for: try controlRecordPath(transactionID: log.plan.transactionID,
              sequence: record.unsigned.sequence)).path)
        }
      } else { expected = nil }
    }
    let root = rootContaining(path: container, plan: log.plan)
    _ = try secureFileSystem(for: root)
    guard let expected,
      case .present(let current) = try fileSystem.itemState(at: container),
      current.fileID == expected.fileID, current.kind == expected.value.kind,
      root.identityVersion == 1 || current == expected.value
    else {
      throw ProfileDataTransactionError(.unownedData, operation: log.plan.operation,
        path: absoluteURL(container, root: rootContaining(path: container, plan: log.plan)).path)
    }
    let marker = payloadOwnerPath(for: log, publishedContainer: container)
    if try fileSystem.itemState(at: marker) != .missing {
      try requirePayloadOwner(log: log, fileSystem: fileSystem, at: marker)
      return
    }
    // Older duplicate rollback did not journal its deletion. Its published
    // directory identity plus stage owner still prove ownership under .prior.
    let legacyDuplicate = log.plan.version == 2
      && effect == .removeDuplicateDestination && log.hasEvent(.publishDestination)
    guard log.hasEvent(effect) || legacyDuplicate else {
      throw ProfileDataTransactionError(.unownedData, operation: log.plan.operation,
        path: absoluteURL(container, root: rootContaining(path: container, plan: log.plan)).path)
    }
    try requireOwner(log: log, hostFS: fileSystem)
  }

  func completedReceiptIfPresent(
    transactionID: UUID,
    entries: [URL]
  ) throws -> Bool {
    let receiptPath = try controlReceiptPath(transactionID)
    guard try control.itemState(at: receiptPath) != .missing else { return false }
    let bytes = try readControlFile(receiptPath)
    let receipt: Receipt
    do {
      receipt = try decoder.decode(Receipt.self, from: bytes)
    } catch {
      let log = try loadLog(transactionID: transactionID, allowingTornTail: true)
      guard isTornJSON(bytes),
        log.pendingReceiptIntent != nil else {
        throw ProfileDataTransactionError(.invalidReceipt, path: controlURL(for: receiptPath).path)
      }
      return false
    }
    guard try canonicalBytes(receipt) == bytes,
      receipt.version == 1, receipt.transactionID == transactionID,
      receipt.planSHA256.count == 64,
      receipt.priorVersion.revision < UInt64.max,
      receipt.targetVersion.revision == receipt.priorVersion.revision + 1,
      receipt.completion == .committed ? receipt.dataMutation != .rolledBack : receipt.dataMutation == .rolledBack
    else { throw ProfileDataTransactionError(.invalidReceipt) }

    let prefix = transactionID.uuidString.lowercased() + "."
    let suffix = ".record.json"
    let sequences = try entries.filter { $0.lastPathComponent.hasSuffix(suffix) }.map { url in
      let name = url.lastPathComponent
      guard name.hasPrefix(prefix),
        let sequence = Int(name.dropFirst(prefix.count).dropLast(suffix.count)), sequence > 0,
        try controlRecordPath(transactionID: transactionID, sequence: sequence).components.last == name
      else { throw ProfileDataTransactionError(.invalidJournal) }
      return sequence
    }
    guard let last = sequences.max() else { throw ProfileDataTransactionError(.invalidReceipt) }
    func record(_ sequence: Int) throws -> Record {
      let bytes = try readControlFile(controlRecordPath(transactionID: transactionID, sequence: sequence))
      let record: Record
      do { record = try decoder.decode(Record.self, from: bytes) }
      catch { throw ProfileDataTransactionError(.invalidJournal, path: controlURL(for: try controlRecordPath(transactionID: transactionID, sequence: sequence)).path) }
      guard try canonicalBytes(record) == bytes,
        record.unsigned.version == 1, record.unsigned.sequence == sequence,
        record.unsigned.transactionID == transactionID,
        record.unsigned.planSHA256 == receipt.planSHA256,
        record.recordSHA256 == LibraryPersistence.sha256(try canonicalBytes(record.unsigned))
      else { throw ProfileDataTransactionError(.invalidReceipt) }
      return record
    }
    var sequence = last
    var final: Record
    do { final = try record(sequence) }
    catch {
      let log = try loadLog(transactionID: transactionID, allowingTornTail: true)
      guard log.tornRecordPath != nil, log.pendingReceiptIntent != nil else { throw error }
      return false
    }
    while final.unsigned.event.effect == .requireRecovery, sequence > 1 {
      let previous = try record(sequence - 1)
      guard final.unsigned.previousSHA256 == previous.recordSHA256 else {
        throw ProfileDataTransactionError(.invalidReceipt)
      }
      sequence -= 1
      final = previous
    }
    if final.unsigned.event == Event(phase: .intent, effect: .writeReceipt) {
      guard final.unsigned.previousSHA256 == receipt.chainHeadSHA256 else {
        throw ProfileDataTransactionError(.invalidReceipt)
      }
      return false
    }
    guard sequence > 1, final.unsigned.event == Event(phase: .effect, effect: .writeReceipt),
      final.unsigned.details["receiptSHA256"] == LibraryPersistence.sha256(bytes)
    else { throw ProfileDataTransactionError(.invalidReceipt) }
    var recoveryRecords: [Record] = []
    var intent = try record(sequence - 1)
    while intent.unsigned.event.effect == .requireRecovery, intent.unsigned.sequence > 1 {
      recoveryRecords.insert(intent, at: 0)
      intent = try record(intent.unsigned.sequence - 1)
    }
    guard receipt.chainHeadSHA256 == intent.unsigned.previousSHA256,
      receiptRecoveryChainIsValid(intent: intent, effect: final, recoveryRecords: recoveryRecords)
    else { throw ProfileDataTransactionError(.invalidReceipt) }
    return true
  }
}
