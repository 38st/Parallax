import Darwin
import Foundation

struct RelocationManagedPath: ManagedMutationPath {
  let url: URL
  let validationContext: ManagedPathValidationContext
}

struct RelocationReceiptPath: ManagedMutationPath {
  let url: URL
  let validationContext: ManagedPathValidationContext
}

struct RelocationManifestEntry: Codable {
  let relativePath: String
  let kind: String
  let size: UInt64?
  let contentSHA256: String?
}

enum StorageRelocationControlCompletion:
  String,
  Codable,
  Equatable
{
  case committed
  case rolledBack
}

struct StorageRelocationControlPlan: Codable, Equatable {
  struct Unsigned: Codable, Equatable {
    let version: Int
    let transactionID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let createdAt: Date
    let priorVersion: StorageRelocationVersionToken
    let targetVersion: StorageRelocationVersionToken
    let originalApplicationSHA256: String
    let relocatedApplicationSHA256: String
    let sourceBasePath: String
    let destinationBasePath: String
    let sourceApplicationFingerprint: String?
    let sourceArchiveFingerprint: String?
    let sourceApplicationSnapshot: StorageRelocationOwnedTreeSnapshot?
    let sourceArchiveSnapshot: StorageRelocationOwnedTreeSnapshot?
  }

  let unsigned: Unsigned
  let planSHA256: String
}

struct StorageRelocationControlReceipt: Codable, Equatable {
  struct Unsigned: Codable, Equatable {
    let version: Int
    let transactionID: UUID
    let planSHA256: String
    let completion: StorageRelocationControlCompletion
    let completedAt: Date
    let priorVersion: StorageRelocationVersionToken
    let targetVersion: StorageRelocationVersionToken
  }

  let unsigned: Unsigned
  let receiptSHA256: String
}

enum StorageRelocationSecureConversions {
  static func snapshot(
    identity: SecureManagedItemIdentity,
    manifest: SecureManagedManifest
  ) -> StorageRelocationOwnedTreeSnapshot {
    StorageRelocationOwnedTreeSnapshot(
      identity: StorageRelocationItemIdentity(
        volumeID: identity.volumeID,
        fileID: identity.fileID,
        kind: identity.kind.rawValue
      ),
      manifest: manifest.entries.map {
        StorageRelocationManifestEntry(
          relativeComponents: $0.relativeComponents,
          kind: $0.kind.rawValue,
          byteCount: $0.byteCount,
          permissions: $0.permissions,
          sha256: $0.sha256
        )
      }
    )
  }

  static func identity(
    _ value: StorageRelocationItemIdentity
  ) -> SecureManagedItemIdentity? {
    guard
      let kind = SecureManagedItemIdentity.Kind(
        rawValue: value.kind
      )
    else { return nil }
    return SecureManagedItemIdentity(
      volumeID: value.volumeID,
      fileID: value.fileID,
      kind: kind
    )
  }

  static func manifest(
    _ values: [StorageRelocationManifestEntry]
  ) -> SecureManagedManifest? {
    var entries: [SecureManagedManifest.Entry] = []
    for value in values {
      guard
        let kind = SecureManagedItemIdentity.Kind(
          rawValue: value.kind
        ),
        value.relativeComponents.allSatisfy({
          !$0.isEmpty
            && $0 != "."
            && $0 != ".."
            && !$0.contains("/")
            && !$0.contains(":")
            && !$0.contains("\0")
        })
      else { return nil }
      entries.append(
        SecureManagedManifest.Entry(
          relativeComponents: value.relativeComponents,
          kind: kind,
          byteCount: value.byteCount,
          permissions: value.permissions,
          sha256: value.sha256
        )
      )
    }
    return SecureManagedManifest(entries: entries)
  }
}
