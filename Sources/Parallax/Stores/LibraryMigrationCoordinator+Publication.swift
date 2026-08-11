import Foundation

extension LibraryMigrationCoordinator {
  func writePublicationState(
    journal: MigrationJournal,
    mapping: LibraryMigrationPathMapping,
    state: PublicationRecord.State
  ) throws {
    let url = publicationURL(
      migrationID: journal.migrationID,
      mapping: mapping
    )
    let data = try encoded(
      publicationRecord(
        journal: journal,
        mapping: mapping,
        state: state
      )
    )
    if fileSystem.fileExists(at: url) {
      try fileSystem.writeDataAtomically(data, to: url)
      try fileSystem.setPOSIXPermissions(0o600, at: url)
      try fileSystem.synchronize(at: url)
      try fileSystem.synchronize(at: url.deletingLastPathComponent())
    } else {
      try publishControlData(
        data,
        to: url,
        parent: url.deletingLastPathComponent()
      )
    }
  }

  func readPublicationState(
    journal: MigrationJournal,
    mapping: LibraryMigrationPathMapping
  ) throws -> PublicationRecord? {
    let url = publicationURL(
      migrationID: journal.migrationID,
      mapping: mapping
    )
    guard fileSystem.fileExists(at: url) else { return nil }
    let decoded = try JSONDecoder().decode(
      PublicationRecord.self,
      from: fileSystem.readData(at: url)
    )
    let prepared = try publicationRecord(
      journal: journal,
      mapping: mapping,
      state: decoded.state
    )
    guard decoded == prepared else {
      throw LibraryMigrationError.invalidJournal
    }
    return decoded
  }

  func markRollbackRequired(
    journal: MigrationJournal,
    reason: String
  ) throws {
    let url = controlPaths(for: journal.migrationID).directory
      .appendingPathComponent("rollback-required.json")
    let data = try encoded(
      RollbackRequiredRecord(
        migrationID: journal.migrationID.uuidString.lowercased(),
        reason: reason
      )
    )
    if fileSystem.fileExists(at: url) {
      try fileSystem.writeDataAtomically(data, to: url)
      try fileSystem.synchronize(at: url)
    } else {
      try publishControlData(
        data,
        to: url,
        parent: url.deletingLastPathComponent()
      )
    }
  }

  func receipt(
    for journal: MigrationJournal,
    completedAt: Date
  ) -> LibraryMigrationReceipt {
    LibraryMigrationReceipt(
      schemaVersion: journal.schemaVersion,
      migrationID: journal.migrationID,
      sourceFormat: journal.sourceFormat,
      sourceSHA256: journal.sourceSHA256,
      sourceByteCount: journal.sourceByteCount,
      targetSHA256: journal.targetSHA256,
      backupRelativePath: "library-v1.backup.json",
      startedAt: journal.createdAt,
      completedAt: completedAt,
      committedAt: completedAt,
      legacyDataRetention: "retainedInPlace",
      applicationMappings: journal.applicationMappings,
      mappings: journal.mappings
    )
  }

  func currentPrimaryHash() throws -> String {
    LibraryPersistence.sha256(try fileSystem.readData(at: libraryURL))
  }

  func verifyPrimaryStillMatches(_ snapshot: LegacyLibrarySnapshot) throws {
    let current = try fileSystem.readData(at: libraryURL)
    guard
      current.count == snapshot.sourceByteCount,
      LibraryPersistence.sha256(current) == snapshot.sourceSHA256
    else {
      throw LibraryMigrationError.sourceChanged
    }
  }

  func encoded<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [
      .prettyPrinted,
      .sortedKeys,
      .withoutEscapingSlashes,
    ]
    return try encoder.encode(value)
  }

  func encodedLibrary(_ applications: [ManagedApplication]) throws -> Data {
    try encoded(LibraryDocument(applications: applications))
  }

  func publishControlData(
    _ data: Data,
    to destination: URL,
    parent: URL
  ) throws {
    let pending = parent.appendingPathComponent(
      ".\(destination.lastPathComponent).pending",
      isDirectory: false
    )
    if fileSystem.fileExists(at: pending) {
      guard try fileSystem.readData(at: pending) == data else {
        throw LibraryMigrationError.recoveryConflict
      }
    } else {
      try fileSystem.writeData(data, to: pending)
      try fileSystem.setPOSIXPermissions(0o600, at: pending)
      try fileSystem.synchronize(at: pending)
    }
    try fileSystem.moveItem(at: pending, to: destination)
    try fileSystem.setPOSIXPermissions(0o600, at: destination)
    try fileSystem.synchronize(at: destination)
    try fileSystem.synchronize(at: parent)
  }
}
