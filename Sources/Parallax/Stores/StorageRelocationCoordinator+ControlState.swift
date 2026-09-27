import Darwin
import Foundation

// MARK: - Control state and reconciliation

extension StorageRelocationCoordinator {
  func loadControlPlan(
    _ transactionID: UUID
  ) throws -> StorageRelocationControlPlan {
    let path = try controlPlanPath(transactionID)
    guard try control.itemState(at: path) != .missing else {
      throw StorageRelocationError(
        .transactionNotFound,
        path: controlURL(for: path).path
      )
    }
    // Version 1 embedded an unbounded manifest. Keep those journals readable;
    // newly published version 2 control files are bounded before publication.
    let bytes = try readControlFile(path, maximumBytes: Self.maximumLegacyControlBytes)
    let plan: StorageRelocationControlPlan
    do {
      plan = try decoder.decode(
        StorageRelocationControlPlan.self,
        from: bytes
      )
    } catch {
      throw StorageRelocationError(
        .invalidJournal,
        path: controlURL(for: path).path,
        detail: error.localizedDescription
      )
    }
    guard
      try canonicalBytes(plan) == bytes,
      [1, 2].contains(plan.unsigned.version),
      plan.unsigned.version == 1 || bytes.count <= Self.maximumControlBytes,
      plan.unsigned.transactionID == transactionID,
      plan.planSHA256
        == LibraryPersistence.sha256(
          try canonicalBytes(plan.unsigned)
        ),
      plan.unsigned.priorVersion.revision.rawValue < UInt64.max,
      plan.unsigned.targetVersion.revision.rawValue
        == plan.unsigned.priorVersion.revision.rawValue + 1,
      plan.unsigned.targetVersion.primarySHA256 != nil,
      plan.unsigned.sourceBasePath.hasPrefix("/"),
      !plan.unsigned.sourceBasePath.contains("\0"),
      plan.unsigned.destinationBasePath.hasPrefix("/"),
      !plan.unsigned.destinationBasePath.contains("\0"),
      (plan.unsigned.sourceApplicationFingerprint == nil)
        == (plan.unsigned.sourceApplicationSnapshot == nil),
      (plan.unsigned.sourceArchiveFingerprint == nil)
        == (plan.unsigned.sourceArchiveSnapshot == nil),
      (plan.unsigned.sourceApplicationFingerprint?.count ?? 64)
        == 64,
      (plan.unsigned.sourceArchiveFingerprint?.count ?? 64)
        == 64,
      snapshotsAreValid(plan)
    else {
      throw StorageRelocationError(
        .invalidJournal,
        path: controlURL(for: path).path
      )
    }
    return plan
  }

  func loadControlReceiptIfPresent(
    plan: StorageRelocationControlPlan
  ) throws -> StorageRelocationControlReceipt? {
    let path = try controlReceiptPath(plan.unsigned.transactionID)
    guard try control.itemState(at: path) != .missing else {
      return nil
    }
    let bytes = try readControlFile(path)
    let receipt: StorageRelocationControlReceipt
    do {
      receipt = try decoder.decode(
        StorageRelocationControlReceipt.self,
        from: bytes
      )
    } catch {
      throw StorageRelocationError(
        .invalidReceipt,
        path: controlURL(for: path).path,
        detail: error.localizedDescription
      )
    }
    guard
      try canonicalBytes(receipt) == bytes,
      receipt.unsigned.version == 1,
      receipt.unsigned.transactionID
        == plan.unsigned.transactionID,
      receipt.unsigned.planSHA256 == plan.planSHA256,
      receipt.unsigned.priorVersion == plan.unsigned.priorVersion,
      receipt.unsigned.targetVersion == plan.unsigned.targetVersion,
      receipt.receiptSHA256
        == LibraryPersistence.sha256(
          try canonicalBytes(receipt.unsigned)
        )
    else {
      throw StorageRelocationError(
        .invalidReceipt,
        path: controlURL(for: path).path
      )
    }
    return receipt
  }

  func completedOutcome(
    receipt: StorageRelocationControlReceipt,
    plan: StorageRelocationControlPlan,
    repository: any LibraryRepositoryPersisting
  ) throws -> StorageRelocationRecoveryOutcome {
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
    switch receipt.unsigned.completion {
    case .committed:
      guard primary == .target else {
        throw StorageRelocationError(.ambiguousLibraryState)
      }
      return .committed(
        StorageRelocationOutcome(
          transactionID: plan.unsigned.transactionID,
          application: application,
          versionToken:
            plan.unsigned.targetVersion.libraryToken,
          receiptURL: controlURL(
            for: try controlReceiptPath(
              plan.unsigned.transactionID
            )
          ),
          leftoverSourcePaths: receipt.unsigned.leftoverSourcePaths ?? []
        )
      )
    case .rolledBack:
      guard primary == .prior else {
        throw StorageRelocationError(.ambiguousLibraryState)
      }
      return .rolledBack
    }
  }

  func recoveryApplication(
    _ outcome: LibraryRepositoryLoadOutcome,
    primary: LibraryCommitPrimaryState,
    plan: StorageRelocationControlPlan
  ) throws -> ManagedApplication {
    guard
      primary != .neither,
      case .loaded(let snapshot) = outcome
    else {
      throw StorageRelocationError(
        .ambiguousLibraryState,
        path: controlURL(
          for: try controlPlanPath(
            plan.unsigned.transactionID
          )
        ).path
      )
    }
    let applications = snapshot.applications.filter {
      $0.id == plan.unsigned.applicationID
    }
    guard
      applications.count == 1,
      applications[0].storageID
        == plan.unsigned.applicationStorageID
    else {
      throw StorageRelocationError(.ambiguousLibraryState)
    }
    let expectedHash =
      primary == .target
      ? plan.unsigned.relocatedApplicationSHA256
      : plan.unsigned.originalApplicationSHA256
    guard try applicationSHA256(applications[0]) == expectedHash else {
      throw StorageRelocationError(.ambiguousLibraryState)
    }
    return applications[0]
  }

  func applicationSHA256(
    _ application: ManagedApplication
  ) throws -> String {
    LibraryPersistence.sha256(
      try canonicalBytes(application)
    )
  }

  func canonicalBytes<T: Encodable>(_ value: T) throws -> Data {
    try encoder.encode(value)
  }

  func controlPlanPath(
    _ transactionID: UUID
  ) throws -> SecureManagedPath {
    try SecureManagedPath([
      transactionID.uuidString.lowercased() + ".plan.json"
    ])
  }

  func controlReceiptPath(
    _ transactionID: UUID
  ) throws -> SecureManagedPath {
    try SecureManagedPath([
      transactionID.uuidString.lowercased() + ".receipt.json"
    ])
  }

  func controlURL(for path: SecureManagedPath) -> URL {
    path.components.reduce(controlRootURL) {
      $0.appendingPathComponent($1, isDirectory: false)
    }
  }

  func validateControlRoot() throws {
    let attributes = try fileSystem.attributesOfItem(
      at: controlRootURL
    )
    guard
      attributes.kind == .directory,
      attributes.identity == controlRootIdentity
    else {
      throw StorageRelocationError(
        .invalidJournal,
        path: controlRootURL.path
      )
    }
  }

  func readControlFile(
    _ path: SecureManagedPath,
    maximumBytes: Int = Self.maximumControlBytes
  ) throws -> Data {
    try validateControlRoot()
    var descriptor = open(
      controlRootURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw StorageRelocationError(
        .invalidJournal,
        path: controlRootURL.path
      )
    }
    defer { close(descriptor) }
    var rootStatus = stat()
    guard
      fstat(descriptor, &rootStatus) == 0,
      UInt64(bitPattern: Int64(rootStatus.st_dev)) == controlRootIdentity.volumeID,
      UInt64(rootStatus.st_ino) == controlRootIdentity.fileID
    else {
      throw StorageRelocationError(
        .invalidJournal,
        path: controlRootURL.path
      )
    }
    for component in path.components.dropLast() {
      let next = openat(
        descriptor,
        component,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard next >= 0 else {
        throw StorageRelocationError(.invalidJournal)
      }
      close(descriptor)
      descriptor = next
    }
    guard let leaf = path.components.last else {
      throw StorageRelocationError(.invalidJournal)
    }
    let file = openat(
      descriptor,
      leaf,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard file >= 0 else {
      throw StorageRelocationError(.invalidJournal)
    }
    defer { close(file) }
    var status = stat()
    guard
      fstat(file, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_size >= 0, status.st_size <= maximumBytes,
      status.st_nlink == 1
    else {
      throw StorageRelocationError(.invalidJournal)
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while true {
      let count = Darwin.read(file, &buffer, buffer.count)
      if count == 0 { break }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw StorageRelocationError(.invalidJournal)
      }
      result.append(buffer, count: count)
      guard result.count <= maximumBytes else {
        throw StorageRelocationError(.invalidJournal)
      }
    }
    try validateControlRoot()
    return result
  }

  func classifyLibrary(
    _ outcome: LibraryRepositoryLoadOutcome,
    prior: LibraryVersionToken,
    target: LibraryVersionToken
  ) -> LibraryCommitPrimaryState {
    let actual: LibraryVersionToken?
    switch outcome {
    case .missing:
      actual = .missing
    case .loaded(let snapshot):
      actual = snapshot.versionToken
    case .migrationRequired, .recoveryRequired, .readOnly:
      actual = nil
    }
    if actual == prior { return .prior }
    if actual == target { return .target }
    return .neither
  }

  func loadReceipt(at url: URL) throws -> StorageRelocationReceipt {
    do {
      return try decoder.decode(
        StorageRelocationReceipt.self,
        from: fileSystem.readData(at: url)
      )
    } catch {
      throw StorageRelocationError(
        .invalidReceipt,
        path: url.path,
        detail: error.localizedDescription
      )
    }
  }

}
