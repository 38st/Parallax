import Darwin
import Foundation

// MARK: - Journal and validation

extension ProfileDataTransactionCoordinator {
  func perform(
    _ effect: ProfileDataTransactionEffect,
    log: inout TransactionLog,
    body: () throws -> [String: String]
  ) throws -> [String: String] {
    try appendRecord(
      event: Event(phase: .intent, effect: effect),
      details: [:],
      log: &log
    )
    try transactionBoundary?(.beforeEffect(effect))
    let details = try body()
    try transactionBoundary?(.afterEffectBeforeRecord(effect))
    try appendRecord(
      event: Event(phase: .effect, effect: effect),
      details: details,
      log: &log
    )
    try transactionBoundary?(.afterRecord(effect))
    return details
  }

  func appendRecord(
    event: Event,
    details: [String: String],
    log: inout TransactionLog
  ) throws {
    let sequence = log.records.count + 1
    let unsigned = UnsignedRecord(
      version: 1,
      transactionID: log.plan.transactionID,
      sequence: sequence,
      previousSHA256: log.chainHead,
      planSHA256: log.planHash,
      event: event,
      details: details,
      recordedAt: now()
    )
    let unsignedBytes = try canonicalBytes(unsigned)
    let recordHash = LibraryPersistence.sha256(unsignedBytes)
    let record = Record(unsigned: unsigned, recordSHA256: recordHash)
    let bytes = try canonicalBytes(record)
    try writeAtomically(
      bytes,
      in: control,
      to: try controlRecordPath(
        transactionID: log.plan.transactionID,
        sequence: sequence
      )
    )
    log.records.append(record)
  }

  func loadLog(transactionID: UUID, allowingTornTail: Bool = false) throws -> TransactionLog {
    let planPath = try controlPlanPath(transactionID)
    guard try control.itemState(at: planPath) != .missing else {
      throw ProfileDataTransactionError(.transactionNotFound)
    }
    let planBytes = try readControlFile(planPath)
    let plan: Plan
    do {
      plan = try decoder.decode(Plan.self, from: planBytes)
    } catch {
      throw ProfileDataTransactionError(
        .invalidJournal,
        path: controlURL(for: planPath).path,
        detail: error.localizedDescription
      )
    }
    guard
      [2, 3, 4].contains(plan.version),
      plan.transactionID == transactionID,
      try canonicalBytes(plan) == planBytes,
      try validateDecodedPlan(plan)
    else {
      throw ProfileDataTransactionError(
        .invalidJournal,
        path: controlURL(for: planPath).path
      )
    }
    let planHash = LibraryPersistence.sha256(planBytes)
    let files = try fileSystem.contentsOfDirectory(at: controlRootURL)
    let prefix = transactionID.uuidString.lowercased() + "."
    let recordSuffix = ".record.json"
    let recordFiles = files.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.lastPathComponent.hasSuffix(recordSuffix) }
    var tornRecordPath: SecureManagedPath?
    var records: [Record] = []
    var sequence = 1
    var previousHash = planHash
    while true {
      let path = try controlRecordPath(
        transactionID: transactionID,
        sequence: sequence
      )
      guard try control.itemState(at: path) != .missing else { break }
      let bytes = try readControlFile(path)
      let record: Record
      do {
        record = try decoder.decode(Record.self, from: bytes)
      } catch {
        let expectedNames = try (1...sequence).map {
          controlURL(for: try controlRecordPath(transactionID: transactionID, sequence: $0)).lastPathComponent
        }
        if allowingTornTail, isTornJSON(bytes), Set(recordFiles.map(\.lastPathComponent)) == Set(expectedNames) {
          tornRecordPath = path
          break
        }
        throw ProfileDataTransactionError(.invalidJournal, path: controlURL(for: path).path)
      }
      let expectedHash = LibraryPersistence.sha256(
        try canonicalBytes(record.unsigned)
      )
      guard
        try canonicalBytes(record) == bytes,
        record.unsigned.version == 1,
        record.unsigned.transactionID == transactionID,
        record.unsigned.sequence == sequence,
        record.unsigned.planSHA256 == planHash,
        record.unsigned.previousSHA256 == previousHash,
        record.recordSHA256 == expectedHash
      else {
        throw ProfileDataTransactionError(
          .invalidJournal,
          path: controlURL(for: path).path
        )
      }
      records.append(record)
      previousHash = record.recordSHA256
      sequence += 1
    }

    let unexpectedSequence = files.contains { url in
      guard
        url.lastPathComponent.hasPrefix(prefix),
        url.lastPathComponent.hasSuffix(recordSuffix)
      else { return false }
      let value = url.lastPathComponent
        .dropFirst(prefix.count)
        .dropLast(recordSuffix.count)
      guard let number = Int(value) else { return true }
      return number >= sequence && url.lastPathComponent != tornRecordPath?.components.last
    }
    guard !unexpectedSequence else {
      throw ProfileDataTransactionError(.invalidJournal)
    }
    return TransactionLog(
      plan: plan,
      planBytes: planBytes,
      planHash: planHash,
      records: records,
      tornRecordPath: tornRecordPath
    )
  }

  func validatedReceiptIfPresent(
    log: TransactionLog
  ) throws -> Receipt? {
    let path = try controlReceiptPath(log.plan.transactionID)
    guard try control.itemState(at: path) != .missing else {
      if log.hasEffect(.writeReceipt) {
        throw ProfileDataTransactionError(.invalidReceipt)
      }
      return nil
    }
    let bytes = try readControlFile(path)
    let receipt: Receipt
    do {
      receipt = try decoder.decode(Receipt.self, from: bytes)
    } catch {
      throw ProfileDataTransactionError(.invalidReceipt)
    }
    guard
      try canonicalBytes(receipt) == bytes,
      receipt.version == 1,
      receipt.transactionID == log.plan.transactionID,
      receipt.planSHA256 == log.planHash,
      receipt.identity == log.plan.identity,
      receipt.operation == log.plan.operation,
      receipt.externalDataHandling == log.plan.externalDataHandling,
      receipt.priorVersion == log.plan.priorVersion,
      receipt.targetVersion == log.plan.targetVersion,
      receiptIsConsistent(receipt, plan: log.plan),
      let receiptRecord = log.records.last(where: {
        $0.unsigned.event
          == Event(phase: .effect, effect: .writeReceipt)
      }),
      let receiptIntent = log.records.last(where: {
        $0.unsigned.event
          == Event(phase: .intent, effect: .writeReceipt)
      }),
      receiptRecord.unsigned.details["receiptSHA256"]
        == LibraryPersistence.sha256(bytes),
      receipt.chainHeadSHA256
        == receiptIntent.unsigned.previousSHA256,
      receiptRecord.unsigned.previousSHA256
        == receiptIntent.recordSHA256
    else {
      throw ProfileDataTransactionError(.invalidReceipt)
    }
    return receipt
  }

  func repairReceiptEffect(
    log: inout TransactionLog
  ) throws {
    guard
      let intent = log.records.last,
      intent.unsigned.event
        == Event(phase: .intent, effect: .writeReceipt)
    else {
      throw ProfileDataTransactionError(.invalidReceipt)
    }
    let path = try controlReceiptPath(log.plan.transactionID)
    let bytes = try readControlFile(path)
    let receipt: Receipt
    do {
      receipt = try decoder.decode(Receipt.self, from: bytes)
    } catch {
      throw ProfileDataTransactionError(.invalidReceipt)
    }
    guard
      try canonicalBytes(receipt) == bytes,
      receipt.version == 1,
      receipt.transactionID == log.plan.transactionID,
      receipt.planSHA256 == log.planHash,
      receipt.chainHeadSHA256 == intent.unsigned.previousSHA256,
      receipt.identity == log.plan.identity,
      receipt.operation == log.plan.operation,
      receipt.externalDataHandling == log.plan.externalDataHandling,
      receipt.priorVersion == log.plan.priorVersion,
      receipt.targetVersion == log.plan.targetVersion,
      receiptIsConsistent(receipt, plan: log.plan)
    else {
      throw ProfileDataTransactionError(.invalidReceipt)
    }
    try appendRecord(
      event: Event(phase: .effect, effect: .writeReceipt),
      details: [
        "receiptSHA256": LibraryPersistence.sha256(bytes)
      ],
      log: &log
    )
  }

  func markRecoveryRequired(
    log: inout TransactionLog,
    primary: LibraryCommitPrimaryState,
    error: Error
  ) throws {
    guard !log.hasEffect(.requireRecovery) else { return }
    _ = try perform(.requireRecovery, log: &log) {
      [
        "primaryState": primary.rawValue,
        "errorType": String(reflecting: type(of: error)),
      ]
    }
  }

  func receiptIsConsistent(
    _ receipt: Receipt,
    plan: Plan
  ) -> Bool {
    switch receipt.completion {
    case .committed:
      return receipt.dataMutation == committedMutation(for: plan)
    case .rolledBack:
      return receipt.dataMutation == .rolledBack
    }
  }

}
