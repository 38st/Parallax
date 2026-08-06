import Darwin
import Foundation

// MARK: - Filesystem and request validation

extension ProfileDataTransactionCoordinator {
  func validateRequest(
    _ request: ProfileDataTransactionRequest
  ) throws {
    switch request.operation {
    case .duplicate, .relocate:
      guard
        request.destination != nil,
        request.identity.destinationProfileID != nil,
        request.identity.destinationProfileStorageID != nil
      else {
        throw ProfileDataTransactionError(.invalidJournal)
      }
    case .archive, .clear, .delete:
      guard
        request.destination == nil,
        request.identity.destinationProfileID == nil,
        request.identity.destinationProfileStorageID == nil
      else {
        throw ProfileDataTransactionError(.invalidJournal)
      }
    }
    if let destination = request.destination,
      destination.profileRoot.url.standardizedFileURL
        == request.source.profileRoot.url.standardizedFileURL
    {
      throw ProfileDataTransactionError(.sameSourceAndDestination)
    }
  }

  func verifyInitialState(
    _ plan: Plan,
    sourceFS: SecureManagedFileSystem,
    destinationFS: SecureManagedFileSystem?
  ) throws {
    guard
      try snapshot(at: plan.sourcePath.value, in: sourceFS)
        == plan.sourceSnapshot
    else {
      throw ProfileDataTransactionError(
        .sourceChanged,
        operation: plan.operation
      )
    }
    if let destinationFS,
      let destination = plan.destinationPath?.value
    {
      guard try destinationFS.itemState(at: destination) == .missing else {
        throw ProfileDataTransactionError(
          .unexpectedDestination,
          operation: plan.operation
        )
      }
    }
  }

  func rootBinding(
    for context: ManagedPathValidationContext
  ) throws -> RootBinding {
    let root = context.canonicalBaseRootURL.standardizedFileURL
    let attributes = try fileSystem.attributesOfItem(at: root)
    guard
      attributes.kind == .directory,
      let identity = attributes.identity
    else {
      throw ProfileDataTransactionError(
        .sourceChanged,
        path: root.path
      )
    }
    return RootBinding(
      path: root.path,
      volumeID: identity.volumeID,
      fileID: identity.fileID
    )
  }

  func secureFileSystem(
    for binding: RootBinding
  ) throws -> SecureManagedFileSystem {
    let attributes = try fileSystem.attributesOfItem(at: binding.url)
    guard
      attributes.kind == .directory,
      attributes.identity == binding.identity
    else {
      throw ProfileDataTransactionError(
        .sourceChanged,
        path: binding.path
      )
    }
    let boundaryHook = secureBoundary
    return try SecureManagedFileSystem(
      rootURL: binding.url,
      boundaryHook: { boundary in
        try boundaryHook?(binding.url, boundary)
      }
    )
  }

  func securePath(
    _ target: URL,
    relativeTo root: URL
  ) throws -> SecureManagedPath {
    let rootComponents = root.standardizedFileURL.pathComponents
    let targetComponents = target.standardizedFileURL.pathComponents
    guard
      targetComponents.count > rootComponents.count,
      Array(targetComponents.prefix(rootComponents.count))
        == rootComponents
    else {
      throw ProfileDataTransactionError(
        .invalidJournal,
        path: target.path
      )
    }
    return try SecureManagedPath(
      Array(targetComponents.dropFirst(rootComponents.count))
    )
  }

  func snapshot(
    at path: SecureManagedPath,
    in fileSystem: SecureManagedFileSystem
  ) throws -> ItemSnapshot? {
    switch try fileSystem.itemState(at: path) {
    case .missing:
      return nil
    case .present(let identity):
      return ItemSnapshot(
        identity: IdentityValue(identity),
        manifest: ManifestValue(try fileSystem.manifest(at: path))
      )
    }
  }

  func snapshotDetails(
    at path: SecureManagedPath,
    in fileSystem: SecureManagedFileSystem
  ) throws -> [String: String] {
    guard let snapshot = try snapshot(at: path, in: fileSystem) else {
      return ["state": "missing"]
    }
    return [
      "state": "present",
      "identity": try canonicalBytes(snapshot.identity)
        .base64EncodedString(),
      "manifest": try canonicalBytes(snapshot.manifest)
        .base64EncodedString(),
    ]
  }

  func removeCurrentOwnedTree(
    _ path: SecureManagedPath,
    in fileSystem: SecureManagedFileSystem
  ) throws {
    guard let snapshot = try snapshot(at: path, in: fileSystem) else {
      return
    }
    try fileSystem.removeOwnedTree(
      at: path,
      expectedIdentity: snapshot.identity.value,
      expectedManifest: snapshot.manifest.value
    )
  }

  func removePayloadOwnerIfPresent(
    log: inout TransactionLog,
    fileSystem: SecureManagedFileSystem,
    container: SecureManagedPath
  ) throws {
    let marker = payloadOwnerPath(
      for: log,
      publishedContainer: container
    )
    guard try fileSystem.itemState(at: marker) != .missing else {
      return
    }
    try requirePayloadOwner(log: log, fileSystem: fileSystem, at: marker)
    _ = try perform(.removePayloadMarker, log: &log) {
      try removeCurrentOwnedTree(marker, in: fileSystem)
      return [:]
    }
  }

  func requireOwner(
    log: TransactionLog,
    hostFS: SecureManagedFileSystem
  ) throws {
    let expected = try canonicalBytes(
      OwnerMarker(
        version: 1,
        transactionID: log.plan.transactionID,
        planSHA256: log.planHash
      )
    )
    let actual = try readManagedFile(
      log.plan.stageOwnerPath.value,
      root: log.plan.hostRoot
    )
    guard actual == expected else {
      throw ProfileDataTransactionError(
        .unownedData,
        operation: log.plan.operation,
        path: log.plan.stageOwnerPath.value.components.joined(
          separator: "/"
        )
      )
    }
    _ = hostFS
  }

  func requirePayloadOwner(
    log: TransactionLog,
    fileSystem: SecureManagedFileSystem,
    at path: SecureManagedPath
  ) throws {
    guard try fileSystem.itemState(at: path) != .missing else {
      throw ProfileDataTransactionError(
        .unownedData,
        operation: log.plan.operation,
        path: path.components.joined(separator: "/")
      )
    }
    let expected = try canonicalBytes(
      OwnerMarker(
        version: 1,
        transactionID: log.plan.transactionID,
        planSHA256: log.planHash
      )
    )
    let root = rootContaining(path: path, plan: log.plan)
    let actual = try readManagedFile(path, root: root)
    guard actual == expected else {
      throw ProfileDataTransactionError(
        .unownedData,
        operation: log.plan.operation,
        path: path.components.joined(separator: "/")
      )
    }
  }

  func rootContaining(
    path: SecureManagedPath,
    plan: Plan
  ) -> RootBinding {
    if let destination = plan.destinationPath?.value,
      destination.components.count <= path.components.count,
      Array(path.components.prefix(destination.components.count))
        == destination.components
    {
      return plan.destinationRoot ?? plan.hostRoot
    }
    return plan.sourceRoot
  }

  func requireMissing(
    _ path: SecureManagedPath,
    in fileSystem: SecureManagedFileSystem
  ) throws {
    guard try fileSystem.itemState(at: path) == .missing else {
      throw ProfileDataTransactionError(
        .unexpectedDestination,
        path: path.components.joined(separator: "/")
      )
    }
  }

  func payloadOwnerPath(
    for log: TransactionLog,
    published: Bool
  ) -> SecureManagedPath {
    if published,
      let destination = log.plan.destinationPath?.value
    {
      return payloadOwnerPath(for: log, publishedContainer: destination)
    }
    return log.plan.payloadOwnerPath.value
  }

  func payloadOwnerPath(
    for log: TransactionLog,
    publishedContainer: SecureManagedPath
  ) -> SecureManagedPath {
    do {
      return try publishedContainer.appending(
        Self.payloadOwnerPrefix
          + log.plan.transactionID.uuidString.lowercased()
      )
    } catch {
      preconditionFailure("Validated payload owner path became invalid.")
    }
  }

  func classifyPrimary(
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

  func committedMutation(for plan: Plan) -> ProfileDataMutation {
    guard plan.sourceSnapshot != nil else { return .noManagedData }
    switch plan.operation {
    case .archive, .clear:
      return .archivedManagedData
    case .delete:
      return .deletedManagedData
    case .duplicate:
      return .copiedManagedData
    case .relocate:
      return .relocatedManagedData
    }
  }

  func metadataBackupReason(
    for operation: ProfileDataTransactionOperation
  ) -> LibraryBackupReason? {
    switch operation {
    case .archive, .delete, .relocate:
      return .destructiveRewrite
    case .clear, .duplicate:
      return nil
    }
  }

  func outcome(
    from receipt: Receipt,
    plan: Plan
  ) -> ProfileDataTransactionOutcome {
    let archiveURL: URL?
    if receipt.completion == .committed,
      receipt.dataMutation == .archivedManagedData,
      let archive = plan.archivePath?.value
    {
      archiveURL = absoluteURL(archive, root: plan.sourceRoot)
    } else {
      archiveURL = nil
    }
    return ProfileDataTransactionOutcome(
      transactionID: plan.transactionID,
      operation: receipt.operation,
      dataMutation: receipt.dataMutation,
      externalDataHandling: receipt.externalDataHandling,
      didArchiveData: receipt.completion == .committed
        && receipt.dataMutation == .archivedManagedData,
      archiveURL: archiveURL,
      receiptURL: controlRootURL.appendingPathComponent(
        plan.transactionID.uuidString.lowercased()
          + ".receipt.json",
        isDirectory: false
      )
    )
  }

  func preparedCommitIdentifier(
    request: ProfileDataTransactionRequest,
    preparedCommit: PreparedLibraryCommit
  ) -> String {
    let fields = [
      request.transactionID.uuidString.lowercased(),
      request.identity.applicationID.uuidString.lowercased(),
      request.identity.applicationStorageID.uuidString.lowercased(),
      request.identity.sourceProfileID.uuidString.lowercased(),
      request.identity.sourceProfileStorageID.uuidString.lowercased(),
      request.identity.destinationProfileID?.uuidString.lowercased() ?? "",
      request.identity.destinationProfileStorageID?.uuidString.lowercased()
        ?? "",
      request.operation.rawValue,
      String(preparedCommit.priorVersion.revision.rawValue),
      preparedCommit.priorVersion.primarySHA256 ?? "",
      String(preparedCommit.targetVersion.revision.rawValue),
      preparedCommit.targetVersion.primarySHA256 ?? "",
      LibraryPersistence.sha256(preparedCommit.targetBytes),
    ]
    return LibraryPersistence.sha256(Data(fields.joined(separator: "\n").utf8))
  }

  func canonicalBytes<T: Encodable>(_ value: T) throws -> Data {
    try encoder.encode(value)
  }

  func controlPlanPath(_ transactionID: UUID) throws -> SecureManagedPath {
    try SecureManagedPath([
      transactionID.uuidString.lowercased() + ".plan.json"
    ])
  }

  func controlRecordPath(
    transactionID: UUID,
    sequence: Int
  ) throws -> SecureManagedPath {
    try SecureManagedPath([
      transactionID.uuidString.lowercased()
        + "."
        + String(format: "%06d", sequence)
        + ".record.json"
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

  func absoluteURL(
    _ path: SecureManagedPath,
    root: RootBinding
  ) -> URL {
    path.components.reduce(root.url) {
      $0.appendingPathComponent($1)
    }
  }

  func validateControlRoot() throws {
    let attributes = try fileSystem.attributesOfItem(at: controlRootURL)
    guard
      attributes.kind == .directory,
      attributes.identity == controlRootIdentity
    else {
      throw ProfileDataTransactionError(
        .invalidJournal,
        path: controlRootURL.path
      )
    }
  }

  func readControlFile(_ path: SecureManagedPath) throws -> Data {
    try validateControlRoot()
    let data = try readNoFollow(
      path: path,
      rootURL: controlRootURL,
      expectedRootIdentity: controlRootIdentity
    )
    try validateControlRoot()
    return data
  }

  func readManagedFile(
    _ path: SecureManagedPath,
    root: RootBinding
  ) throws -> Data {
    let attributes = try fileSystem.attributesOfItem(at: root.url)
    guard attributes.identity == root.identity else {
      throw ProfileDataTransactionError(
        .sourceChanged,
        path: root.path
      )
    }
    return try readNoFollow(
      path: path,
      rootURL: root.url,
      expectedRootIdentity: root.identity
    )
  }

  func readNoFollow(
    path: SecureManagedPath,
    rootURL: URL,
    expectedRootIdentity: FileSystemObjectIdentity
  ) throws -> Data {
    var descriptor = open(
      rootURL.path,
      O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
    )
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(descriptor) }
    var rootStatus = stat()
    guard
      fstat(descriptor, &rootStatus) == 0,
      UInt64(rootStatus.st_dev) == expectedRootIdentity.volumeID,
      UInt64(rootStatus.st_ino) == expectedRootIdentity.fileID
    else {
      throw ProfileDataTransactionError(
        .invalidJournal,
        path: rootURL.path
      )
    }

    for component in path.components.dropLast() {
      let next = openat(
        descriptor,
        component,
        O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
      )
      guard next >= 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      close(descriptor)
      descriptor = next
    }
    guard let leaf = path.components.last else {
      throw ProfileDataTransactionError(.invalidJournal)
    }
    let file = openat(
      descriptor,
      leaf,
      O_RDONLY | O_NOFOLLOW | O_CLOEXEC
    )
    guard file >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(file) }
    var status = stat()
    guard
      fstat(file, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_nlink == 1
    else {
      throw ProfileDataTransactionError(.invalidJournal)
    }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    let maximumBytes = 4 * 1_024 * 1_024
    while true {
      let count = Darwin.read(file, &buffer, buffer.count)
      if count == 0 { break }
      guard count > 0 else {
        if errno == EINTR { continue }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      result.append(buffer, count: count)
      guard result.count <= maximumBytes else {
        throw ProfileDataTransactionError(
          .invalidJournal,
          path: rootURL.path
        )
      }
    }
    return result
  }
}
