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

  func snapshotsAreValid(
    _ plan: StorageRelocationControlPlan
  ) -> Bool {
    [
      plan.unsigned.sourceApplicationSnapshot,
      plan.unsigned.sourceArchiveSnapshot,
    ].compactMap { $0 }.allSatisfy { snapshot in
      guard StorageRelocationSecureConversions.identity(snapshot.identity) != nil else {
        return false
      }
      if plan.unsigned.version == 2 {
        return snapshot.manifest.isEmpty
          && snapshot.manifestSHA256?.count == 64
          && (snapshot.manifestEntryCount ?? 0) > 0
      }
      return snapshot.manifestSHA256 == nil
        && snapshot.manifestEntryCount == nil
        && StorageRelocationSecureConversions.manifest(snapshot.manifest) != nil
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

  func ownedSnapshotIfPresent(
    _ path: any ManagedMutationPath
  ) throws -> StorageRelocationOwnedTreeSnapshot? {
    _ = try pathResolver.revalidateForMutation(path)
    var baseStatus = stat()
    if lstat(path.validationContext.canonicalBaseRootURL.path, &baseStatus) != 0,
      errno == ENOENT
    {
      return nil
    }
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
      if preparationCancellation != nil {
        return StorageRelocationOwnedTreeSnapshot(identity: StorageRelocationItemIdentity(
          volumeID: identity.volumeID, fileID: identity.fileID, kind: identity.kind.rawValue),
          manifest: try previewManifest(in: secureFileSystem, at: relative, url: path.url))
      }
      return StorageRelocationSecureConversions.snapshot(
        identity: identity,
        manifest: try secureFileSystem.manifest(at: relative)
      )
    }
  }

  @discardableResult
  func removeOriginalOwned(
    _ path: any ManagedMutationPath,
    snapshot: StorageRelocationOwnedTreeSnapshot?,
    allowMissing: Bool = false,
    beforeRemoval: (() throws -> Void)? = nil
  ) throws -> Bool {
    let removal: (SecureManagedPath, SecureManagedItemIdentity, SecureManagedManifest)
    do {
      try transactionBoundary?(.beforeSourceCleanup(path.url))
      let current = try ownedSnapshotIfPresent(path)
      if allowMissing, current == nil {
        return snapshot == nil || fileSystem.fileExists(at: path.validationContext.canonicalBaseRootURL)
      }
      guard let snapshot else {
        guard current == nil else { throw StorageRelocationError(.sourceChanged, path: path.url.path) }
        return true
      }
      guard let current, current.identity == snapshot.identity,
        try (allowMissing ? manifestIsSubset(current.manifest, of: snapshot.manifest)
          : snapshotMatches(current, expected: snapshot)),
        let identity = StorageRelocationSecureConversions.identity(current.identity),
        let manifest = StorageRelocationSecureConversions.manifest(current.manifest),
        let relative = try securePath(path)
      else { throw StorageRelocationError(.sourceChanged, path: path.url.path) }
      removal = (relative, identity, manifest)
    } catch {
      if allowMissing { return false }
      throw error
    }
    // Publication failures must still stop recovery; only source cleanup is
    // best effort once the committed destination has been verified.
    try beforeRemoval?()
    do {
      let secure = try SecureManagedFileSystem(rootURL: path.validationContext.canonicalBaseRootURL)
      try secure.removeOwnedTree(at: removal.0, expectedIdentity: removal.1, expectedManifest: removal.2)
      return true
    } catch {
      if allowMissing { return false }
      throw error
    }
  }

  func requireOriginalOwned(
    _ path: any ManagedMutationPath,
    snapshot: StorageRelocationOwnedTreeSnapshot?
  ) throws {
    let current = try ownedSnapshotIfPresent(path)
    guard try snapshotsMatch(current, expected: snapshot, includingIdentity: true) else {
      throw StorageRelocationError(.rollbackRequired, path: path.url.path)
    }
  }

  @discardableResult
  func requireRecoveryCopy(
    _ path: any ManagedMutationPath,
    snapshot: StorageRelocationOwnedTreeSnapshot?
  ) throws -> StorageRelocationOwnedTreeSnapshot? {
    let current = try ownedSnapshotIfPresent(path)
    guard try snapshotsMatch(current, expected: snapshot, includingIdentity: false) else {
      throw StorageRelocationError(.rollbackRequired, path: path.url.path)
    }
    return current
  }

  func removeRecoveryCopyIfPresent(
    _ path: any ManagedMutationPath,
    snapshot: StorageRelocationOwnedTreeSnapshot?
  ) throws {
    guard let current = try ownedSnapshotIfPresent(path) else { return }
    guard let snapshot,
      manifestIsSubset(current.manifest, of: snapshot.manifest),
      let identity = StorageRelocationSecureConversions.identity(current.identity),
      let manifest = StorageRelocationSecureConversions.manifest(current.manifest),
      let relative = try securePath(path)
    else {
      throw StorageRelocationError(.rollbackRequired, path: path.url.path)
    }
    let secureFileSystem = try SecureManagedFileSystem(
      rootURL: path.validationContext.canonicalBaseRootURL
    )
    try secureFileSystem.removeOwnedTree(
      at: relative, expectedIdentity: identity, expectedManifest: manifest
    )
  }

  func snapshotsMatch(
    _ actual: StorageRelocationOwnedTreeSnapshot?,
    expected: StorageRelocationOwnedTreeSnapshot?,
    includingIdentity: Bool
  ) throws -> Bool {
    guard let expected else { return actual == nil }
    guard let actual else { return false }
    return try (!includingIdentity || actual.identity == expected.identity)
      && snapshotMatches(actual, expected: expected)
  }

  func snapshotMatches(
    _ actual: StorageRelocationOwnedTreeSnapshot,
    expected: StorageRelocationOwnedTreeSnapshot
  ) throws -> Bool {
    if let digest = expected.manifestSHA256 {
      return try actual.manifest.count == expected.manifestEntryCount
        && manifestSHA256(actual.manifest) == digest
    }
    return try manifestSHA256(actual.manifest) == manifestSHA256(expected.manifest)
  }

  func manifestIsSubset(
    _ actual: [StorageRelocationManifestEntry],
    of expected: [StorageRelocationManifestEntry]
  ) -> Bool {
    var entries: [[String]: StorageRelocationManifestEntry] = [:]
    for value in expected {
      let entry = normalizedManifestEntry(value)
      guard entries.updateValue(entry, forKey: entry.relativeComponents) == nil else {
        return false
      }
    }
    return actual.count <= expected.count && actual.allSatisfy {
      let entry = normalizedManifestEntry($0)
      return entries[entry.relativeComponents] == entry
    }
  }

  func manifestSHA256(_ entries: [StorageRelocationManifestEntry]) throws -> String {
    let normalized = entries.map(normalizedManifestEntry)
      .sorted { $0.relativeComponents.lexicographicallyPrecedes($1.relativeComponents) }
    return LibraryPersistence.sha256(try canonicalBytes(normalized))
  }

  func normalizedManifestEntry(_ entry: StorageRelocationManifestEntry) -> StorageRelocationManifestEntry {
    StorageRelocationManifestEntry(relativeComponents: entry.relativeComponents.map(\.precomposedStringWithCanonicalMapping),
      kind: entry.kind, byteCount: entry.byteCount, permissions: entry.permissions, sha256: entry.sha256)
  }

  func compactSnapshot(
    _ snapshot: StorageRelocationOwnedTreeSnapshot?
  ) throws -> StorageRelocationOwnedTreeSnapshot? {
    guard let snapshot else { return nil }
    return StorageRelocationOwnedTreeSnapshot(
      identity: snapshot.identity, manifest: [],
      manifestSHA256: try manifestSHA256(snapshot.manifest),
      manifestEntryCount: snapshot.manifest.count
    )
  }

  func sourceSnapshot(
    _ original: StorageRelocationOwnedTreeSnapshot?,
    verifiedCopy: StorageRelocationOwnedTreeSnapshot?
  ) -> StorageRelocationOwnedTreeSnapshot? {
    guard let original, let verifiedCopy else { return nil }
    return StorageRelocationOwnedTreeSnapshot(
      identity: original.identity, manifest: verifiedCopy.manifest
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
