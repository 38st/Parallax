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
    try control.write(
      bytes,
      to: try controlRecordPath(
        transactionID: log.plan.transactionID,
        sequence: sequence
      )
    )
    log.records.append(record)
  }

  func loadLog(transactionID: UUID) throws -> TransactionLog {
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
      plan.version == 2,
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
        throw ProfileDataTransactionError(
          .invalidJournal,
          path: controlURL(for: path).path
        )
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

    let prefix = transactionID.uuidString.lowercased() + "."
    let recordSuffix = ".record.json"
    let files = try fileSystem.contentsOfDirectory(at: controlRootURL)
    let unexpectedSequence = files.contains { url in
      guard
        url.lastPathComponent.hasPrefix(prefix),
        url.lastPathComponent.hasSuffix(recordSuffix)
      else { return false }
      let value = url.lastPathComponent
        .dropFirst(prefix.count)
        .dropLast(recordSuffix.count)
      guard let number = Int(value) else { return true }
      return number >= sequence
    }
    guard !unexpectedSequence else {
      throw ProfileDataTransactionError(.invalidJournal)
    }
    return TransactionLog(
      plan: plan,
      planBytes: planBytes,
      planHash: planHash,
      records: records
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

  func validatePreparedCommit(
    _ prepared: PreparedLibraryCommit
  ) throws {
    guard
      prepared.targetVersion.primarySHA256
        == LibraryPersistence.sha256(prepared.targetBytes),
      prepared.targetVersion.revision.rawValue
        == prepared.priorVersion.revision.rawValue + 1
    else {
      throw ProfileDataTransactionError(.preparedCommitMismatch)
    }
  }

  func validateMetadataTransition(
    plan: Plan,
    priorApplications: [ManagedApplication],
    targetApplications: [ManagedApplication]
  ) throws {
    guard
      let priorApplication = priorApplications.first(where: {
        $0.id == plan.identity.applicationID
      }),
      let targetApplication = targetApplications.first(where: {
        $0.id == plan.identity.applicationID
      }),
      priorApplications.filter({
        $0.id == plan.identity.applicationID
      }).count == 1,
      targetApplications.filter({
        $0.id == plan.identity.applicationID
      }).count == 1,
      priorApplication.storageID
        == plan.identity.applicationStorageID,
      targetApplication.storageID
        == plan.identity.applicationStorageID,
      let priorSource = priorApplication.profiles.first(where: {
        $0.id == plan.identity.sourceProfileID
      }),
      priorSource.storageID
        == plan.identity.sourceProfileStorageID
    else {
      throw ProfileDataTransactionError(
        .preparedCommitMismatch,
        operation: plan.operation
      )
    }

    let targetSource = targetApplication.profiles.first {
      $0.id == plan.identity.sourceProfileID
    }
    let targetHasSource =
      targetSource?.storageID
      == plan.identity.sourceProfileStorageID
    switch plan.operation {
    case .archive, .delete:
      guard !targetHasSource else {
        throw ProfileDataTransactionError(
          .preparedCommitMismatch,
          operation: plan.operation
        )
      }
    case .clear:
      guard targetHasSource else {
        throw ProfileDataTransactionError(
          .preparedCommitMismatch,
          operation: plan.operation
        )
      }
    case .duplicate:
      guard
        targetHasSource,
        let destinationID = plan.identity.destinationProfileID,
        destinationID != plan.identity.sourceProfileID,
        !priorApplication.profiles.contains(where: {
          $0.id == destinationID
        }),
        let targetDestination = targetApplication.profiles.first(where: {
          $0.id == destinationID
        }),
        targetDestination.storageID
          == plan.identity.destinationProfileStorageID
      else {
        throw ProfileDataTransactionError(
          .preparedCommitMismatch,
          operation: plan.operation
        )
      }
    case .relocate:
      guard targetHasSource else {
        throw ProfileDataTransactionError(
          .preparedCommitMismatch,
          operation: plan.operation
        )
      }
    }
  }

  func validateDecodedPlan(_ plan: Plan) throws -> Bool {
    guard
      plan.version == 2,
      plan.sourceRoot.path.hasPrefix("/"),
      plan.hostRoot.path.hasPrefix("/"),
      !plan.preparedCommitIdentifier.isEmpty,
      plan.targetBytesSHA256 == plan.targetVersion.primarySHA256,
      plan.priorVersion.revision < UInt64.max,
      plan.targetVersion.revision == plan.priorVersion.revision + 1
    else { return false }
    switch plan.operation {
    case .archive, .clear:
      guard
        plan.destinationRoot == nil,
        plan.destinationPath == nil,
        plan.archivePath != nil,
        plan.hostRoot == plan.sourceRoot,
        plan.identity.destinationProfileID == nil,
        plan.identity.destinationProfileStorageID == nil
      else { return false }
    case .delete:
      guard
        plan.destinationRoot == nil,
        plan.destinationPath == nil,
        plan.archivePath == nil,
        plan.hostRoot == plan.sourceRoot,
        plan.identity.destinationProfileID == nil,
        plan.identity.destinationProfileStorageID == nil
      else { return false }
    case .duplicate:
      guard
        let destinationRoot = plan.destinationRoot,
        plan.destinationPath != nil,
        plan.archivePath == nil,
        plan.hostRoot == destinationRoot,
        plan.identity.destinationProfileID != nil,
        plan.identity.destinationProfileStorageID != nil
      else { return false }
    case .relocate:
      guard
        let destinationRoot = plan.destinationRoot,
        plan.destinationPath != nil,
        plan.archivePath == nil,
        plan.hostRoot == destinationRoot,
        plan.identity.destinationProfileID
          == plan.identity.sourceProfileID,
        plan.identity.destinationProfileStorageID
          == plan.identity.sourceProfileStorageID
      else { return false }
    }
    let paths = [
      plan.sourcePath,
      plan.destinationPath,
      plan.archivePath,
      plan.stagePath,
      plan.stageOwnerPath,
      plan.payloadPath,
      plan.payloadOwnerPath,
    ].compactMap { $0 }
    for path in paths {
      _ = try SecureManagedPath(path.components)
    }
    let applicationStorage =
      plan.identity.applicationStorageID.uuidString.lowercased()
    let sourceStorage =
      plan.identity.sourceProfileStorageID.uuidString.lowercased()
    guard
      plan.sourcePath.components == [
        ".parallax",
        "Applications",
        applicationStorage,
        "Profiles",
        sourceStorage,
      ]
    else { return false }
    let transaction = plan.transactionID.uuidString.lowercased()
    guard
      plan.stagePath.components == [
        ".parallax", "Transactions", transaction,
      ],
      plan.stageOwnerPath.components == [
        ".parallax", "Transactions", transaction + ".owner",
      ],
      plan.payloadPath.components
        == plan.stagePath.components + ["payload"],
      plan.payloadOwnerPath.components
        == plan.payloadPath.components
        + [Self.payloadOwnerPrefix + transaction]
    else { return false }
    if let destination = plan.destinationPath {
      guard
        let destinationStorage =
          plan.identity.destinationProfileStorageID?
          .uuidString.lowercased()
      else { return false }
      guard
        destination.components == [
          ".parallax",
          "Applications",
          applicationStorage,
          "Profiles",
          destinationStorage,
        ]
      else { return false }
    }
    if let archive = plan.archivePath {
      guard
        archive.components.count == 5,
        Array(archive.components.prefix(4)) == [
          ".parallax",
          "Archives",
          applicationStorage,
          sourceStorage,
        ],
        archive.components[4].hasSuffix("-" + transaction)
      else { return false }
    }
    let snapshots = [plan.sourceSnapshot].compactMap { $0 }
    for snapshot in snapshots {
      guard snapshot.identity.isValid else { return false }
      for entry in snapshot.manifest.entries {
        guard
          IdentityValue.validKinds.contains(entry.kind),
          entry.relativeComponents.allSatisfy({
            !$0.isEmpty
              && $0 != "."
              && $0 != ".."
              && !$0.contains("/")
              && !$0.contains("\0")
          })
        else { return false }
      }
    }
    return true
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
