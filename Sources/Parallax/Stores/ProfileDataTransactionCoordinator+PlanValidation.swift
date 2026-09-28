import Darwin
import Foundation

extension ProfileDataTransactionCoordinator {
  func validateDecodedPlan(_ plan: Plan) throws -> Bool {
    guard
      [2, 3, 4].contains(plan.version),
      [plan.sourceRoot, plan.hostRoot, plan.destinationRoot].compactMap({ $0 }).allSatisfy(\.isValid),
      plan.version < 4 || [plan.sourceRoot, plan.hostRoot, plan.destinationRoot].compactMap({ $0 })
        .allSatisfy({ $0.identityVersion == 1 }),
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
      guard snapshot.manifest != nil
        || (snapshot.manifestSHA256?.count == 64 && (snapshot.entryCount ?? -1) >= 0)
      else { return false }
      for entry in snapshot.manifest?.entries ?? [] {
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

}
