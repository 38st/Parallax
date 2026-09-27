import Darwin
import Foundation

extension StorageRelocationCoordinator {
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

}
