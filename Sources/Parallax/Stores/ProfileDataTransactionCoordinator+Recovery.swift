import Foundation

extension ProfileDataTransactionCoordinator {
  func isUnpublishedTornPlan(_ transactionID: UUID) throws -> Bool {
    let bytes = try readControlFile(controlPlanPath(transactionID))
    do {
      _ = try decoder.decode(Plan.self, from: bytes)
      return false
    } catch {
      let prefix = transactionID.uuidString.lowercased() + "."
      let entries = try fileSystem.contentsOfDirectory(at: controlRootURL)
      guard !entries.contains(where: {
        $0.lastPathComponent.hasPrefix(prefix)
          && ($0.lastPathComponent.hasSuffix(".record.json") || $0.lastPathComponent.hasSuffix(".receipt.json"))
      }) else {
        throw ProfileDataTransactionError(.invalidJournal, path: controlURL(for: try controlPlanPath(transactionID)).path)
      }
      return true
    }
  }

  @discardableResult
  func quarantine(_ path: SecureManagedPath, in fileSystem: SecureManagedFileSystem) throws -> SecureManagedPath {
    let destination = try SecureManagedPath(Array(path.components.dropLast()) + [
      ".parallax-quarantine-" + UUID().uuidString.lowercased()
    ])
    try fileSystem.rename(from: path, to: destination)
    return destination
  }

  // Called only by recovery while its caller holds the library lock and lease.
  func repairInterruptedControlWrites(log: inout TransactionLog) throws {
    if let torn = log.tornRecordPath {
      try quarantine(torn, in: control)
      log.tornRecordPath = nil
    }
    let receiptPath = try controlReceiptPath(log.plan.transactionID)
    if try control.itemState(at: receiptPath) != .missing {
      let bytes = try readControlFile(receiptPath)
      do { _ = try decoder.decode(Receipt.self, from: bytes) }
      catch {
        guard log.records.last?.unsigned.event == Event(phase: .intent, effect: .writeReceipt) else {
          throw ProfileDataTransactionError(.invalidReceipt, path: controlURL(for: receiptPath).path)
        }
        try quarantine(receiptPath, in: control)
      }
    }
    try sweepWriteTemporaries(in: control, directory: nil, rootURL: controlRootURL)
  }

  func repairInterruptedMarkers(log: TransactionLog) throws {
    let hostFS = try secureFileSystem(for: log.plan.hostRoot)
    let expected = try canonicalBytes(OwnerMarker(version: 1,
      transactionID: log.plan.transactionID, planSHA256: log.planHash))
    var markers: [(SecureManagedPath, ProfileDataTransactionEffect)] = [
      (log.plan.stageOwnerPath.value, .writeOwnerMarker),
      (log.plan.payloadOwnerPath.value, .writePayloadMarker)
    ]
    let restoredSource = [.clear, .archive, .delete].contains(log.plan.operation) ? log.plan.sourcePath.value : nil
    for container in [restoredSource, log.plan.destinationPath?.value, log.plan.archivePath?.value].compactMap({ $0 }) {
      markers.append((payloadOwnerPath(for: log, publishedContainer: container), .writePayloadMarker))
    }
    for (marker, effect) in markers {
      let root = rootContaining(path: marker, plan: log.plan)
      let fs = try secureFileSystem(for: root)
      guard try fs.itemState(at: marker) != .missing else { continue }
      let actual = try readManagedFile(marker, root: root)
      guard actual != expected else { continue }
      guard actual.count < expected.count, expected.starts(with: actual),
        log.hasEvent(effect), !log.hasEffect(effect)
      else {
        throw ProfileDataTransactionError(.unownedData, operation: log.plan.operation,
          path: absoluteURL(marker, root: root).path)
      }
      try quarantine(marker, in: fs)
      let temporaryDirectory = try fs.itemState(at: log.plan.stagePath.value) != .missing
        ? log.plan.stagePath.value : nil
      try writeAtomically(expected, in: fs, to: marker, temporaryDirectory: temporaryDirectory)
    }
    let parent = try SecureManagedPath(Array(log.plan.stagePath.components.dropLast()))
    if try hostFS.itemState(at: parent) != .missing {
      try sweepWriteTemporaries(in: hostFS, directory: parent, rootURL: URL(fileURLWithPath: log.plan.hostRoot.path))
    }
  }

  func sweepWriteTemporaries(
    in secureFS: SecureManagedFileSystem, directory: SecureManagedPath?, rootURL: URL
  ) throws {
    let url = (directory?.components ?? []).reduce(rootURL) { $0.appendingPathComponent($1) }
    for entry in try fileSystem.contentsOfDirectory(at: url) {
      let name = entry.lastPathComponent
      guard name.hasPrefix(".parallax-write-"),
        let id = UUID(uuidString: String(name.dropFirst(".parallax-write-".count))),
        name == ".parallax-write-" + id.uuidString.lowercased()
      else { continue }
      let path = try SecureManagedPath((directory?.components ?? []) + [name])
      guard case .present(let identity) = try secureFS.itemState(at: path), identity.kind == .regularFile else { continue }
      try removeCurrentOwnedTree(path, in: secureFS)
    }
  }
}
