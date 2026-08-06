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
    let bytes = try readControlFile(path)
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
      plan.unsigned.version == 1,
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
          )
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

  func snapshotsAreValid(
    _ plan: StorageRelocationControlPlan
  ) -> Bool {
    [
      plan.unsigned.sourceApplicationSnapshot,
      plan.unsigned.sourceArchiveSnapshot,
    ].compactMap { $0 }.allSatisfy { snapshot in
      StorageRelocationSecureConversions.identity(
        snapshot.identity
      ) != nil
        && StorageRelocationSecureConversions.manifest(
          snapshot.manifest
        ) != nil
    }
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
    _ path: SecureManagedPath
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
      UInt64(rootStatus.st_dev) == controlRootIdentity.volumeID,
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
      status.st_nlink == 1
    else {
      throw StorageRelocationError(.invalidJournal)
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    let maximumBytes = 4 * 1_024 * 1_024
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

  func ownedSnapshotIfPresent(
    _ path: any ManagedMutationPath
  ) throws -> StorageRelocationOwnedTreeSnapshot? {
    let secureFileSystem = try SecureManagedFileSystem(
      rootURL: path.validationContext.canonicalBaseRootURL
    )
    guard let relative = try securePath(path) else {
      throw StorageRelocationError(
        .sourceChanged,
        path: path.url.path
      )
    }
    switch try secureFileSystem.itemState(at: relative) {
    case .missing:
      return nil
    case .present(let identity):
      return StorageRelocationSecureConversions.snapshot(
        identity: identity,
        manifest: try secureFileSystem.manifest(at: relative)
      )
    }
  }

  func removeOriginalOwned(
    _ path: any ManagedMutationPath,
    snapshot: StorageRelocationOwnedTreeSnapshot?,
    allowMissing: Bool = false
  ) throws {
    guard let snapshot else {
      guard !exists(path) else {
        throw StorageRelocationError(
          .sourceChanged,
          path: path.url.path
        )
      }
      return
    }
    guard
      let expectedIdentity =
        StorageRelocationSecureConversions.identity(
          snapshot.identity
        ),
      let expectedManifest =
        StorageRelocationSecureConversions.manifest(
          snapshot.manifest
        ),
      let relative = try securePath(path)
    else {
      throw StorageRelocationError(
        .invalidJournal,
        path: path.url.path
      )
    }
    let secureFileSystem = try SecureManagedFileSystem(
      rootURL: path.validationContext.canonicalBaseRootURL
    )
    if allowMissing,
      try secureFileSystem.itemState(at: relative) == .missing
    {
      return
    }
    try transactionBoundary?(.beforeSourceCleanup(path.url))
    do {
      try secureFileSystem.removeOwnedTree(
        at: relative,
        expectedIdentity: expectedIdentity,
        expectedManifest: expectedManifest
      )
    } catch {
      throw StorageRelocationError(
        .sourceChanged,
        path: path.url.path,
        detail: error.localizedDescription
      )
    }
  }

  func requireOriginalOwned(
    _ path: any ManagedMutationPath,
    snapshot: StorageRelocationOwnedTreeSnapshot?
  ) throws {
    guard let snapshot else {
      guard !exists(path) else {
        throw StorageRelocationError(
          .rollbackRequired,
          path: path.url.path
        )
      }
      return
    }
    guard try ownedSnapshotIfPresent(path) == snapshot else {
      throw StorageRelocationError(
        .rollbackRequired,
        path: path.url.path
      )
    }
  }

  func requireRecoveryCopy(
    _ path: any ManagedMutationPath,
    snapshot: StorageRelocationOwnedTreeSnapshot?
  ) throws {
    guard let snapshot else {
      guard !exists(path) else {
        throw StorageRelocationError(
          .rollbackRequired,
          path: path.url.path
        )
      }
      return
    }
    guard
      let expectedManifest =
        StorageRelocationSecureConversions.manifest(
          snapshot.manifest
        ),
      let relative = try securePath(path)
    else {
      throw StorageRelocationError(.invalidJournal)
    }
    let secureFileSystem = try SecureManagedFileSystem(
      rootURL: path.validationContext.canonicalBaseRootURL
    )
    guard
      try secureFileSystem.itemState(at: relative) != .missing,
      try secureFileSystem.manifest(at: relative)
        == expectedManifest
    else {
      throw StorageRelocationError(
        .rollbackRequired,
        path: path.url.path
      )
    }
  }

  func removeRecoveryCopyIfPresent(
    _ path: any ManagedMutationPath,
    snapshot: StorageRelocationOwnedTreeSnapshot?
  ) throws {
    guard exists(path) else { return }
    guard
      let snapshot,
      let expectedManifest =
        StorageRelocationSecureConversions.manifest(
          snapshot.manifest
        ),
      let relative = try securePath(path)
    else {
      throw StorageRelocationError(
        .rollbackRequired,
        path: path.url.path
      )
    }
    let secureFileSystem = try SecureManagedFileSystem(
      rootURL: path.validationContext.canonicalBaseRootURL
    )
    guard
      case .present(let identity) =
        try secureFileSystem.itemState(at: relative),
      try secureFileSystem.manifest(at: relative)
        == expectedManifest
    else {
      throw StorageRelocationError(
        .rollbackRequired,
        path: path.url.path
      )
    }
    try secureFileSystem.removeOwnedTree(
      at: relative,
      expectedIdentity: identity,
      expectedManifest: expectedManifest
    )
  }

  func removePublishedIfUnchanged(
    _ path: any ManagedMutationPath,
    expected: String?
  ) throws {
    guard exists(path) else { return }
    try requireFingerprint(path, expected: expected)
    try removeIfPresent(path)
  }

  func requireFingerprint(
    _ path: any ManagedMutationPath,
    expected: String?
  ) throws {
    guard
      let expected,
      exists(path),
      try fingerprintIfPresent(path) == expected
    else {
      throw StorageRelocationError(
        .sourceChanged,
        path: path.url.path
      )
    }
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
