import Foundation

extension LibraryMigrationCoordinator {
  struct DirectoryManifest: Hashable, Sendable {
    struct Entry: Hashable, Sendable {
      enum Kind: String, Hashable, Sendable {
        case directory
        case regularFile
        case symbolicLink
      }

      let relativePath: String
      let kind: Kind
      let size: UInt64?
      let posixPermissions: Int?
      let digestOrTarget: String?
    }

    let entries: [Entry]
  }

  struct MigrationJournal: Codable, Hashable, Sendable {
    let schemaVersion: Int
    let migrationID: UUID
    let sourceFormat: String
    let sourceSHA256: String
    let sourceByteCount: Int
    let targetSHA256: String
    let createdAt: Date
    let applicationMappings: [LibraryMigrationApplicationMapping]
    let mappings: [LibraryMigrationPathMapping]

    enum CodingKeys: String, CodingKey {
      case schemaVersion
      case migrationID
      case sourceFormat
      case sourceSHA256
      case sourceByteCount
      case targetSHA256
      case createdAt
      case applicationMappings
      case mappings
    }

    init(
      schemaVersion: Int,
      migrationID: UUID,
      sourceFormat: String,
      sourceSHA256: String,
      sourceByteCount: Int,
      targetSHA256: String,
      createdAt: Date,
      applicationMappings: [LibraryMigrationApplicationMapping],
      mappings: [LibraryMigrationPathMapping]
    ) {
      self.schemaVersion = schemaVersion
      self.migrationID = migrationID
      self.sourceFormat = sourceFormat
      self.sourceSHA256 = sourceSHA256
      self.sourceByteCount = sourceByteCount
      self.targetSHA256 = targetSHA256
      self.createdAt = createdAt
      self.applicationMappings = applicationMappings
      self.mappings = mappings
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
      let migrationString = try container.decode(String.self, forKey: .migrationID)
      guard let migrationID = UUID(uuidString: migrationString) else {
        throw LibraryMigrationError.invalidJournal
      }
      self.migrationID = migrationID
      sourceFormat = try container.decode(String.self, forKey: .sourceFormat)
      sourceSHA256 = try container.decode(String.self, forKey: .sourceSHA256)
      sourceByteCount = try container.decode(Int.self, forKey: .sourceByteCount)
      targetSHA256 = try container.decode(String.self, forKey: .targetSHA256)
      createdAt = try container.decode(Date.self, forKey: .createdAt)
      applicationMappings = try container.decode(
        [LibraryMigrationApplicationMapping].self,
        forKey: .applicationMappings
      )
      mappings = try container.decode(
        [LibraryMigrationPathMapping].self,
        forKey: .mappings
      )
    }

    func encode(to encoder: Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(schemaVersion, forKey: .schemaVersion)
      try container.encode(
        migrationID.uuidString.lowercased(),
        forKey: .migrationID
      )
      try container.encode(sourceFormat, forKey: .sourceFormat)
      try container.encode(sourceSHA256, forKey: .sourceSHA256)
      try container.encode(sourceByteCount, forKey: .sourceByteCount)
      try container.encode(targetSHA256, forKey: .targetSHA256)
      try container.encode(createdAt, forKey: .createdAt)
      try container.encode(applicationMappings, forKey: .applicationMappings)
      try container.encode(mappings, forKey: .mappings)
    }
  }

  struct PublicationRecord: Codable, Hashable, Sendable {
    enum State: String, Codable, Hashable, Sendable {
      case prepared
      case published
    }

    let migrationID: String
    let applicationStorageID: String
    let profileStorageID: String
    let profileOccurrence: Int
    let manifestSHA256: String
    let state: State
  }

  struct RollbackRequiredRecord: Codable, Hashable, Sendable {
    let migrationID: String
    let reason: String
  }

  struct ControlPaths {
    let directory: URL
    let backup: URL
    let journal: URL
    let receipt: URL
    let pendingReceipt: URL
    let pendingLibrary: URL
  }

  var parallaxURL: URL {
    applicationSupportURL.appendingPathComponent("Parallax", isDirectory: true)
  }

  var libraryURL: URL {
    parallaxURL.appendingPathComponent("library.json")
  }

  var migrationsRootURL: URL {
    parallaxURL.appendingPathComponent("Migrations", isDirectory: true)
  }

  func controlPaths(for migrationID: UUID) -> ControlPaths {
    let directory = migrationsRootURL.appendingPathComponent(
      migrationID.uuidString.lowercased(),
      isDirectory: true
    )
    return ControlPaths(
      directory: directory,
      backup: directory.appendingPathComponent("library-v1.backup.json"),
      journal: directory.appendingPathComponent("journal.json"),
      receipt: directory.appendingPathComponent("receipt.json"),
      pendingReceipt: directory.appendingPathComponent("receipt.pending.json"),
      pendingLibrary: directory.appendingPathComponent("library-v2.pending.json")
    )
  }

  func publicationURL(
    migrationID: UUID,
    mapping: LibraryMigrationPathMapping
  ) -> URL {
    controlPaths(for: migrationID).directory.appendingPathComponent(
      "publication-\(mapping.profileOccurrence).json",
      isDirectory: false
    )
  }

  func publicationRecord(
    journal: MigrationJournal,
    mapping: LibraryMigrationPathMapping,
    state: PublicationRecord.State
  ) throws -> PublicationRecord {
    guard let manifest = mapping.sourceManifestSHA256 else {
      throw LibraryMigrationError.invalidJournal
    }
    return PublicationRecord(
      migrationID: journal.migrationID.uuidString.lowercased(),
      applicationStorageID:
        mapping.applicationStorageID.uuidString.lowercased(),
      profileStorageID: mapping.profileStorageID.uuidString.lowercased(),
      profileOccurrence: mapping.profileOccurrence,
      manifestSHA256: manifest,
      state: state
    )
  }
}
