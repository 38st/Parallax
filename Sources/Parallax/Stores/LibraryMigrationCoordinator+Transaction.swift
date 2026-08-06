import Darwin
import Foundation

// MARK: - Transaction

extension LibraryMigrationCoordinator {
  func prepareControlState(
    journal: MigrationJournal,
    originalBytes: Data
  ) throws {
    let paths = controlPaths(for: journal.migrationID)
    if !fileSystem.fileExists(at: paths.directory) {
      try fileSystem.createDirectory(
        at: paths.directory,
        withIntermediateDirectories: true
      )
      try fileSystem.setPOSIXPermissions(0o700, at: migrationsRootURL)
      try fileSystem.setPOSIXPermissions(0o700, at: paths.directory)
    }

    if fileSystem.fileExists(at: paths.backup) {
      let existing = try fileSystem.readData(at: paths.backup)
      guard
        existing == originalBytes,
        LibraryPersistence.sha256(existing) == journal.sourceSHA256
      else {
        throw LibraryMigrationError.recoveryConflict
      }
    } else {
      try publishControlData(
        originalBytes,
        to: paths.backup,
        parent: paths.directory
      )
      let written = try fileSystem.readData(at: paths.backup)
      guard
        written == originalBytes,
        LibraryPersistence.sha256(written) == journal.sourceSHA256
      else {
        throw LibraryMigrationError.recoveryConflict
      }
    }

    let journalData = try encoded(journal)
    if fileSystem.fileExists(at: paths.journal) {
      let existing = try fileSystem.readData(at: paths.journal)
      guard existing == journalData else {
        throw LibraryMigrationError.invalidJournal
      }
    } else {
      try publishControlData(
        journalData,
        to: paths.journal,
        parent: paths.directory
      )
    }
  }

  func executeCopies(
    journal: MigrationJournal,
    sourceRecords: [PlannedRecord]
  ) throws {
    var stagingRoots = Set<URL>()
    for record in sourceRecords where record.source.sourceExists {
      guard let expectedManifest = record.source.sourceManifest else {
        throw LibraryMigrationError.invalidJournal
      }
      if fileSystem.fileExists(at: record.paths.profileRoot.url) {
        guard
          try readPublicationState(
            journal: journal,
            mapping: record.mapping
          ) != nil,
          try directoryManifest(at: record.paths.profileRoot.url)
            == expectedManifest
        else {
          throw LibraryMigrationError.recoveryConflict
        }
        try verifySourceUnchanged(record.source)
        continue
      }
      let staging = try record.paths.stagingRoot(
        transactionID: journal.migrationID
      )
      stagingRoots.insert(staging.url)
      if !fileSystem.fileExists(at: staging.url) {
        _ = try ManagedPathResolver(fileSystem: fileSystem)
          .revalidateForMutation(staging)
        try fileSystem.createDirectory(
          at: staging.url,
          withIntermediateDirectories: true
        )
        try fileSystem.setPOSIXPermissions(0o700, at: staging.url)
      }

      let occurrence = String(record.mapping.profileOccurrence)
      let firstCopy = staging.url
        .appendingPathComponent("SourceCopies", isDirectory: true)
        .appendingPathComponent(occurrence, isDirectory: true)
      let publishCopy = staging.url
        .appendingPathComponent("PublishCopies", isDirectory: true)
        .appendingPathComponent(occurrence, isDirectory: true)
      try fileSystem.createDirectory(
        at: firstCopy.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try fileSystem.createDirectory(
        at: publishCopy.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      guard
        !fileSystem.fileExists(at: firstCopy),
        !fileSystem.fileExists(at: publishCopy)
      else {
        throw LibraryMigrationError.recoveryConflict
      }

      try fileSystem.copyItem(
        at: record.source.canonicalSourceURL,
        to: firstCopy
      )
      try verifySourceUnchanged(record.source)
      guard try directoryManifest(at: firstCopy) == expectedManifest else {
        throw LibraryMigrationError.sourceChanged
      }

      try fileSystem.copyItem(at: firstCopy, to: publishCopy)
      guard try directoryManifest(at: publishCopy) == expectedManifest else {
        throw LibraryMigrationError.sourceChanged
      }

      try writePublicationState(
        journal: journal,
        mapping: record.mapping,
        state: .prepared
      )
      let ownerURL = ownerMarkerURL(
        destination: record.paths.profileRoot.url,
        mapping: record.mapping
      )
      try fileSystem.createDirectory(
        at: ownerURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      guard
        !fileSystem.fileExists(at: ownerURL),
        !fileSystem.fileExists(at: record.paths.profileRoot.url)
      else {
        throw LibraryMigrationError.recoveryConflict
      }
      try fileSystem.writeData(ownerData(for: journal, mapping: record.mapping), to: ownerURL)
      try fileSystem.setPOSIXPermissions(0o600, at: ownerURL)
      try fileSystem.synchronize(at: ownerURL)
      try fileSystem.synchronize(at: ownerURL.deletingLastPathComponent())

      _ = try ManagedPathResolver(fileSystem: fileSystem)
        .revalidateForMutation(record.paths.profileRoot)
      try fileSystem.moveItem(
        at: publishCopy,
        to: record.paths.profileRoot.url
      )
      try fileSystem.synchronize(at: record.paths.profileRoot.url)
      try fileSystem.synchronize(
        at: record.paths.profileRoot.url.deletingLastPathComponent()
      )
      try writePublicationState(
        journal: journal,
        mapping: record.mapping,
        state: .published
      )
      guard try directoryManifest(at: record.paths.profileRoot.url) == expectedManifest else {
        throw LibraryMigrationError.sourceChanged
      }
      try verifySourceUnchanged(record.source)
    }

    for stagingRoot in stagingRoots where fileSystem.fileExists(at: stagingRoot) {
      try fileSystem.removeItem(at: stagingRoot)
    }
  }

  func writePendingReceipt(for journal: MigrationJournal) throws {
    let paths = controlPaths(for: journal.migrationID)
    let receipt = receipt(for: journal, completedAt: now())
    let data = try encoded(receipt)
    if fileSystem.fileExists(at: paths.pendingReceipt) {
      guard try fileSystem.readData(at: paths.pendingReceipt) == data else {
        throw LibraryMigrationError.recoveryConflict
      }
    } else {
      try publishControlData(
        data,
        to: paths.pendingReceipt,
        parent: paths.directory
      )
    }
  }

  func commitLibrary(
    journal: MigrationJournal,
    applications: [ManagedApplication],
    sourceRecords: [SourceRecord]
  ) throws {
    let paths = controlPaths(for: journal.migrationID)
    let data = try encodedLibrary(applications)
    guard LibraryPersistence.sha256(data) == journal.targetSHA256 else {
      throw LibraryMigrationError.invalidJournal
    }
    guard !fileSystem.fileExists(at: paths.pendingLibrary) else {
      throw LibraryMigrationError.recoveryConflict
    }
    try fileSystem.writeData(data, to: paths.pendingLibrary)
    try fileSystem.setPOSIXPermissions(0o600, at: paths.pendingLibrary)
    try fileSystem.synchronize(at: paths.pendingLibrary)
    try fileSystem.synchronize(at: paths.directory)
    guard try currentPrimaryHash() == journal.sourceSHA256 else {
      throw LibraryMigrationError.sourceChanged
    }
    for source in sourceRecords where source.sourceExists {
      try verifySourceUnchanged(source)
    }
    try fileSystem.replaceItem(
      at: libraryURL,
      withItemAt: paths.pendingLibrary
    )
    let postReplaceHash = try currentPrimaryHash()
    guard postReplaceHash == journal.targetSHA256 else {
      if postReplaceHash == journal.sourceSHA256 {
        throw LibraryMigrationError.sourceChanged
      }
      throw LibraryMigrationError.recoveryConflict
    }
    try fileSystem.synchronize(at: libraryURL)
    try fileSystem.synchronize(at: libraryURL.deletingLastPathComponent())
  }

  func finalizeCommittedMigration(
    journal: MigrationJournal
  ) throws -> LibraryMigrationReceipt {
    let paths = controlPaths(for: journal.migrationID)
    if fileSystem.fileExists(at: paths.receipt),
      !fileSystem.fileExists(at: paths.pendingReceipt)
    {
      return try JSONDecoder().decode(
        LibraryMigrationReceipt.self,
        from: fileSystem.readData(at: paths.receipt)
      )
    }
    if !fileSystem.fileExists(at: paths.pendingReceipt) {
      let pendingReceipt = receipt(for: journal, completedAt: now())
      try publishControlData(
        try encoded(pendingReceipt),
        to: paths.pendingReceipt,
        parent: paths.directory
      )
    }

    for mapping in journal.mappings {
      let resolved = try resolvedPaths(for: mapping)
      _ = try readPublicationState(
        journal: journal,
        mapping: mapping
      )
      let ownerURL = ownerMarkerURL(
        destination: resolved.profileRoot.url,
        mapping: mapping
      )
      if fileSystem.fileExists(at: ownerURL) {
        guard
          try fileSystem.readData(at: ownerURL)
            == ownerData(for: journal, mapping: mapping)
        else {
          throw LibraryMigrationError.recoveryConflict
        }
        _ = try ManagedPathResolver(fileSystem: fileSystem)
          .revalidateForMutation(resolved.profileRoot)
        try fileSystem.removeItem(at: ownerURL)
      }
      let publicationURL = publicationURL(
        migrationID: journal.migrationID,
        mapping: mapping
      )
      if fileSystem.fileExists(at: publicationURL) {
        try fileSystem.removeItem(at: publicationURL)
      }
    }
    try removeStagingRoots(for: journal)
    if fileSystem.fileExists(at: paths.pendingLibrary) {
      try fileSystem.removeItem(at: paths.pendingLibrary)
    }
    guard !fileSystem.fileExists(at: paths.receipt) else {
      throw LibraryMigrationError.recoveryConflict
    }
    try fileSystem.moveItem(
      at: paths.pendingReceipt,
      to: paths.receipt
    )
    try fileSystem.setPOSIXPermissions(0o600, at: paths.receipt)
    try fileSystem.synchronize(at: paths.receipt)
    try fileSystem.synchronize(at: paths.directory)
    return try JSONDecoder().decode(
      LibraryMigrationReceipt.self,
      from: fileSystem.readData(at: paths.receipt)
    )
  }
}
