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
    let state = try sourceFS.itemState(at: plan.sourcePath.value)
    let matches: Bool
    if let expected = plan.sourceSnapshot {
      matches = try state == .present(expected.identity.value)
        && expected.matches(sourceFS.manifest(at: plan.sourcePath.value))
    } else {
      matches = state == .missing
    }
    guard matches else {
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
    try RootBinding.capture(context.canonicalBaseRootURL.standardizedFileURL, identitySource: identitySource)
  }

  func secureFileSystem(
    for binding: RootBinding
  ) throws -> SecureManagedFileSystem {
    let boundaryHook = secureBoundary
    let secure = try SecureManagedFileSystem(rootURL: binding.url, boundaryHook: { boundary in
      try boundaryHook?(binding.url, boundary)
    })
    guard binding.matches(try identitySource(secure)) else {
      throw ProfileDataTransactionError(.sourceChanged, path: binding.path)
    }
    return secure
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
      return try ItemSnapshot(
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
      "manifestSHA256": snapshot.manifestSHA256 ?? "",
      "entryCount": String(snapshot.entryCount ?? 0),
    ]
  }

  func removeCurrentOwnedTree(
    _ path: SecureManagedPath,
    in fileSystem: SecureManagedFileSystem
  ) throws {
    guard case .present(let identity) = try fileSystem.itemState(at: path) else {
      return
    }
    let manifest = try fileSystem.manifest(at: path)
    try fileSystem.removeOwnedTree(
      at: path,
      expectedIdentity: identity,
      expectedManifest: manifest
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
    if path.components.starts(with: plan.stagePath.components)
      || path == plan.stageOwnerPath.value
    {
      return plan.hostRoot
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

  func absoluteURL(
    _ path: SecureManagedPath,
    root: RootBinding
  ) -> URL {
    path.components.reduce(root.url) {
      $0.appendingPathComponent($1)
    }
  }

}
