import Foundation

extension StorageRelocationCoordinator {
  func recoverySource(_ plan: StorageRelocationControlPlan) throws -> ResolvedApplicationStoragePaths {
    let source = try pathResolver.resolveApplication(configuredBaseRoot: plan.unsigned.sourceBasePath,
      applicationStorageID: plan.unsigned.applicationStorageID)
    guard source.canonicalBaseRootURL.path == plan.unsigned.sourceBasePath,
      fileSystem.fileExists(at: source.canonicalBaseRootURL) else {
      throw StorageRelocationError(.sourceChanged, path: plan.unsigned.sourceBasePath)
    }
    try validateRecoveryRoot(plan.unsigned.sourceRoot, basePath: plan.unsigned.sourceBasePath)
    return source
  }

  func validateRecoveryRoot(_ binding: StorageTransactionRootBinding?, basePath: String) throws {
    guard let binding else { return } // Earlier plans keep their original tree identity checks.
    let base = URL(fileURLWithPath: basePath).pathComponents
    guard binding.identityVersion == 1, base.starts(with: binding.url.pathComponents),
      binding.matches(try identitySource(SecureManagedFileSystem(rootURL: binding.url)))
    else { throw StorageRelocationError(.sourceChanged, path: binding.path) }
  }

  func recoverySnapshot(_ snapshot: StorageRelocationOwnedTreeSnapshot?, root: StorageTransactionRootBinding?) throws
    -> StorageRelocationOwnedTreeSnapshot? {
    guard let snapshot, let root, root.identityVersion == 1 else { return snapshot }
    let secure = try SecureManagedFileSystem(rootURL: root.url)
    guard root.matches(try identitySource(secure)) else { throw StorageRelocationError(.sourceChanged, path: root.path) }
    return StorageRelocationOwnedTreeSnapshot(identity: StorageRelocationItemIdentity(
      volumeID: UInt64(bitPattern: Int64(secure.rootIdentity.device)),
      fileID: snapshot.identity.fileID, kind: snapshot.identity.kind), manifest: snapshot.manifest,
      manifestSHA256: snapshot.manifestSHA256, manifestEntryCount: snapshot.manifestEntryCount)
  }

  func finishControlTransaction(plan: StorageRelocationControlPlan,
    completion: StorageRelocationControlCompletion, leftoverSourcePaths: [String] = []) throws {
    _ = try writeControlReceipt(plan: plan, completion: completion, leftoverSourcePaths: leftoverSourcePaths)
    guard let receipt = try loadControlReceiptIfPresent(plan: plan) else {
      throw StorageRelocationError(.invalidReceipt)
    }
    do { try enrollCompletedPlan(plan, completion: completion) }
    catch { AppLog.persistence.error("Storage volume enrollment failed: \(error.localizedDescription)") }
    retireCompletedPlanBestEffort(plan, receipt: receipt)
  }

  func enrollCompletedPlan(_ plan: StorageRelocationControlPlan, completion: StorageRelocationControlCompletion) throws {
    let path = completion == .committed ? plan.unsigned.destinationBasePath
      : (plan.unsigned.sourceConfiguredBasePath ?? plan.unsigned.sourceBasePath)
    let root = URL(fileURLWithPath: path, isDirectory: true)
    let binding = completion == .committed ? plan.unsigned.destinationRoot : plan.unsigned.sourceRoot
    if let binding {
      // The verified completion proof survives even if the volume is now unplugged.
      try enrollmentStore.recordVerifiedRoot(applicationStorageID: plan.unsigned.applicationStorageID,
        baseRoot: root, volumeUUID: binding.volumeUUID)
    } else if fileSystem.fileExists(at: root) {
      try enrollmentStore.enroll(applicationStorageID: plan.unsigned.applicationStorageID,
        configuredBaseRoot: root, canonicalBaseRoot: root)
    }
  }

  func retireCompletedPlanBestEffort(_ plan: StorageRelocationControlPlan, receipt: StorageRelocationControlReceipt) {
    do { try retireCompletedPlan(plan, receipt: receipt) }
    catch { AppLog.persistence.error("Completed relocation control cleanup deferred: \(error.localizedDescription)") }
  }

  func retireCompletedPlan(_ plan: StorageRelocationControlPlan, receipt: StorageRelocationControlReceipt) throws {
    try writeControlFileAtomically(canonicalBytes(receipt), to: privateControlPath(plan.unsigned.transactionID, suffix: ".retired"))
    try finishRetirement(receipt)
  }
}
