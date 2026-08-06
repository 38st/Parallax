import Darwin
import Foundation

extension ProfileDataTransactionCoordinator {
  enum Phase: String, Codable {
    case intent
    case effect
  }

  enum Completion: String, Codable {
    case committed
    case rolledBack
  }

  struct Event: Codable, Equatable {
    let phase: Phase
    let effect: ProfileDataTransactionEffect
  }

  struct TokenValue: Codable, Equatable {
    let revision: UInt64
    let primarySHA256: String?

    init(_ value: LibraryVersionToken) {
      revision = value.revision.rawValue
      primarySHA256 = value.primarySHA256
    }

    var value: LibraryVersionToken {
      LibraryVersionToken(
        revision: LibraryRevision(rawValue: revision),
        primarySHA256: primarySHA256
      )
    }
  }

  struct RootBinding: Codable, Equatable {
    let path: String
    let volumeID: UInt64
    let fileID: UInt64

    var url: URL {
      URL(fileURLWithPath: path, isDirectory: true)
    }

    var identity: FileSystemObjectIdentity {
      FileSystemObjectIdentity(volumeID: volumeID, fileID: fileID)
    }
  }

  struct PathValue: Codable, Equatable {
    let components: [String]

    init(_ path: SecureManagedPath) {
      components = path.components
    }

    var value: SecureManagedPath {
      // Values have already passed SecureManagedPath validation and the
      // immutable plan's canonical-byte check.
      do {
        return try SecureManagedPath(components)
      } catch {
        preconditionFailure("Validated transaction path became invalid.")
      }
    }
  }

  struct IdentityValue: Codable, Equatable {
    static let validKinds = [
      SecureManagedItemIdentity.Kind.directory.rawValue,
      SecureManagedItemIdentity.Kind.regularFile.rawValue,
    ]

    let volumeID: UInt64
    let fileID: UInt64
    let kind: String

    init(_ identity: SecureManagedItemIdentity) {
      volumeID = identity.volumeID
      fileID = identity.fileID
      kind = identity.kind.rawValue
    }

    var isValid: Bool {
      Self.validKinds.contains(kind)
    }

    var value: SecureManagedItemIdentity {
      SecureManagedItemIdentity(
        volumeID: volumeID,
        fileID: fileID,
        kind: kind == SecureManagedItemIdentity.Kind.regularFile.rawValue
          ? .regularFile
          : .directory
      )
    }
  }

  struct ManifestEntryValue: Codable, Equatable {
    let relativeComponents: [String]
    let kind: String
    let byteCount: UInt64
    let permissions: UInt16
    let sha256: String?
  }

  struct ManifestValue: Codable, Equatable {
    let entries: [ManifestEntryValue]

    init(_ manifest: SecureManagedManifest) {
      entries = manifest.entries.map {
        ManifestEntryValue(
          relativeComponents: $0.relativeComponents,
          kind: $0.kind.rawValue,
          byteCount: $0.byteCount,
          permissions: $0.permissions,
          sha256: $0.sha256
        )
      }
    }

    var value: SecureManagedManifest {
      SecureManagedManifest(
        entries: entries.map {
          SecureManagedManifest.Entry(
            relativeComponents: $0.relativeComponents,
            kind: $0.kind
              == SecureManagedItemIdentity.Kind.regularFile.rawValue
              ? .regularFile
              : .directory,
            byteCount: $0.byteCount,
            permissions: $0.permissions,
            sha256: $0.sha256
          )
        }
      )
    }
  }

  struct ItemSnapshot: Codable, Equatable {
    let identity: IdentityValue
    let manifest: ManifestValue
  }

  struct Plan: Codable, Equatable {
    let version: Int
    let transactionID: UUID
    let identity: ProfileDataTransactionIdentity
    let operation: ProfileDataTransactionOperation
    let createdAt: Date
    let sourceRoot: RootBinding
    let sourcePath: PathValue
    let sourceSnapshot: ItemSnapshot?
    let destinationRoot: RootBinding?
    let destinationPath: PathValue?
    let archivePath: PathValue?
    let hostRoot: RootBinding
    let stagePath: PathValue
    let stageOwnerPath: PathValue
    let payloadPath: PathValue
    let payloadOwnerPath: PathValue
    let priorVersion: TokenValue
    let targetVersion: TokenValue
    let targetBytesSHA256: String
    let preparedCommitIdentifier: String
    let externalDataHandling: ProfileExternalDataHandling
  }

  struct OwnerMarker: Codable, Equatable {
    let version: Int
    let transactionID: UUID
    let planSHA256: String
  }

  struct UnsignedRecord: Codable, Equatable {
    let version: Int
    let transactionID: UUID
    let sequence: Int
    let previousSHA256: String
    let planSHA256: String
    let event: Event
    let details: [String: String]
    let recordedAt: Date
  }

  struct Record: Codable, Equatable {
    let unsigned: UnsignedRecord
    let recordSHA256: String
  }

  struct Receipt: Codable, Equatable {
    let version: Int
    let transactionID: UUID
    let planSHA256: String
    let chainHeadSHA256: String
    let identity: ProfileDataTransactionIdentity
    let operation: ProfileDataTransactionOperation
    let completion: Completion
    let dataMutation: ProfileDataMutation
    let externalDataHandling: ProfileExternalDataHandling
    let priorVersion: TokenValue
    let targetVersion: TokenValue
    let completedAt: Date
  }

  struct TransactionLog {
    let plan: Plan
    let planBytes: Data
    let planHash: String
    var records: [Record]

    var chainHead: String {
      records.last?.recordSHA256 ?? planHash
    }

    func hasEffect(_ effect: ProfileDataTransactionEffect) -> Bool {
      records.contains {
        $0.unsigned.event
          == Event(phase: .effect, effect: effect)
      }
    }

    func hasEvent(_ effect: ProfileDataTransactionEffect) -> Bool {
      records.contains {
        $0.unsigned.event.effect == effect
      }
    }
  }
}
