import Darwin
import Foundation

// MARK: - Recovery

extension LibraryMigrationCoordinator {
  func recoverCommittedMigrationIfNeeded(
    applications: [ManagedApplication]
  ) throws -> LibraryMigrationOutcome? {
    let primaryData = try fileSystem.readData(at: libraryURL)
    let primaryHash = LibraryPersistence.sha256(primaryData)
    let incomplete = try allIncompleteJournals()
    guard !incomplete.isEmpty else { return nil }
    let matching = incomplete.filter { $0.targetSHA256 == primaryHash }
    guard matching.count == 1, incomplete.count == 1,
      let journal = matching.first
    else {
      throw LibraryMigrationError.recoveryConflict
    }
    try validateRetainedLegacySources(for: journal)
    try validate(journal: journal, against: applications)
    try verifyPublishedDestinations(journal)
    let receipt = try finalizeCommittedMigration(journal: journal)
    return .migrated(applications, receipt)
  }

  func validateRetainedLegacySources(
    for journal: MigrationJournal
  ) throws {
    let backup = controlPaths(for: journal.migrationID).backup
    guard let attributes = try attributesIfExists(at: backup),
      attributes.kind == .regularFile
    else {
      throw LibraryMigrationError.recoveryConflict
    }
    let bytes = try fileSystem.readData(at: backup)
    guard
      bytes.count == journal.sourceByteCount,
      LibraryPersistence.sha256(bytes) == journal.sourceSHA256,
      case .migrationRequired(let legacy) =
        try LibraryPersistence.decodeLibrary(from: bytes)
    else {
      throw LibraryMigrationError.recoveryConflict
    }
    do {
      try validateCommittedJournal(journal, against: legacy)
    } catch {
      throw LibraryMigrationError.recoveryConflict
    }
  }

  func validateCommittedJournal(
    _ journal: MigrationJournal,
    against legacy: LegacyLibrary
  ) throws {
    guard
      journal.sourceFormat == sourceFormat(legacy.format),
      journal.applicationMappings.count == legacy.applications.count,
      journal.mappings.count == legacy.applications.flatMap(\.profiles).count
    else {
      throw LibraryMigrationError.invalidJournal
    }

    for applicationMapping in journal.applicationMappings {
      guard
        legacy.applications.indices.contains(
          applicationMapping.applicationOccurrence
        ),
        legacy.applications[applicationMapping.applicationOccurrence].id
          == applicationMapping.oldApplicationID
      else {
        throw LibraryMigrationError.invalidJournal
      }
    }

    let flattened = legacy.applications.enumerated().flatMap {
      applicationOccurrence, application in
      application.profiles.map { (applicationOccurrence, application, $0) }
    }
    for mapping in journal.mappings {
      guard
        flattened.indices.contains(mapping.profileOccurrence),
        journal.applicationMappings.indices.contains(
          mapping.applicationOccurrence
        )
      else {
        throw LibraryMigrationError.invalidJournal
      }
      let expected = flattened[mapping.profileOccurrence]
      let applicationMapping =
        journal.applicationMappings[mapping.applicationOccurrence]
      guard
        expected.0 == mapping.applicationOccurrence,
        expected.1.id == mapping.oldApplicationID,
        expected.2.id == mapping.oldProfileID,
        applicationMapping.oldApplicationID == mapping.oldApplicationID,
        applicationMapping.newApplicationID == mapping.newApplicationID,
        applicationMapping.applicationStorageID
          == mapping.applicationStorageID,
        !mapping.oldCanonicalPath.isEmpty,
        mapping.oldCanonicalPath.hasPrefix("/"),
        (mapping.disposition == .retainedInPlace)
          == (mapping.sourceManifestSHA256 != nil)
      else {
        throw LibraryMigrationError.invalidJournal
      }
    }
  }

  func verifyPublishedDestinations(
    _ journal: MigrationJournal
  ) throws {
    for mapping in journal.mappings {
      let resolved = try resolvedPaths(for: mapping)
      let attributes = try attributesIfExists(at: resolved.profileRoot.url)
      switch mapping.disposition {
      case .missing:
        guard attributes == nil else {
          throw LibraryMigrationError.recoveryConflict
        }
      case .retainedInPlace:
        guard
          attributes?.kind == .directory,
          let expected = mapping.sourceManifestSHA256,
          manifestSHA256(
            try directoryManifest(at: resolved.profileRoot.url)
          ) == expected
        else {
          throw LibraryMigrationError.recoveryConflict
        }
      }
    }
  }

  func validate(
    journal: MigrationJournal,
    against legacy: LegacyLibrary,
    sources: [SourceRecord]
  ) throws {
    guard
      journal.sourceFormat == sourceFormat(legacy.format),
      journal.applicationMappings.count == legacy.applications.count,
      journal.mappings.count == legacy.applications.flatMap(\.profiles).count
    else {
      throw LibraryMigrationError.invalidJournal
    }

    for applicationMapping in journal.applicationMappings {
      guard
        legacy.applications.indices.contains(
          applicationMapping.applicationOccurrence
        ),
        legacy.applications[applicationMapping.applicationOccurrence].id
          == applicationMapping.oldApplicationID
      else {
        throw LibraryMigrationError.invalidJournal
      }
    }

    let flattened = legacy.applications.enumerated().flatMap {
      applicationOccurrence, application in
      application.profiles.map { (applicationOccurrence, application, $0) }
    }
    for mapping in journal.mappings {
      guard
        flattened.indices.contains(mapping.profileOccurrence),
        journal.applicationMappings.indices.contains(
          mapping.applicationOccurrence
        ),
        let source = sources.first(where: {
          $0.profileOccurrence == mapping.profileOccurrence
        })
      else {
        throw LibraryMigrationError.invalidJournal
      }
      let expected = flattened[mapping.profileOccurrence]
      let applicationMapping =
        journal.applicationMappings[mapping.applicationOccurrence]
      guard
        expected.0 == mapping.applicationOccurrence,
        expected.1.id == mapping.oldApplicationID,
        expected.2.id == mapping.oldProfileID,
        applicationMapping.oldApplicationID == mapping.oldApplicationID,
        applicationMapping.newApplicationID == mapping.newApplicationID,
        applicationMapping.applicationStorageID
          == mapping.applicationStorageID,
        source.canonicalSourceURL.path == mapping.oldCanonicalPath,
        source.sourceExists == (mapping.disposition == .retainedInPlace),
        source.sourceManifest.map(manifestSHA256)
          == mapping.sourceManifestSHA256
      else {
        throw LibraryMigrationError.invalidJournal
      }

      let resolved = try ManagedPathResolver(fileSystem: fileSystem).resolve(
        baseRootURL: source.baseRoot,
        applicationStorageID: mapping.applicationStorageID,
        profileStorageID: mapping.profileStorageID
      )
      guard
        resolved.profileRoot.url.path
          == mapping.newCanonicalPath
      else {
        throw LibraryMigrationError.invalidJournal
      }
    }
  }

  func validate(
    journal: MigrationJournal,
    against applications: [ManagedApplication]
  ) throws {
    guard
      journal.applicationMappings.count == applications.count,
      journal.mappings.count == applications.flatMap(\.profiles).count
    else {
      throw LibraryMigrationError.invalidJournal
    }
    for mapping in journal.applicationMappings {
      guard applications.indices.contains(mapping.applicationOccurrence) else {
        throw LibraryMigrationError.invalidJournal
      }
      let application = applications[mapping.applicationOccurrence]
      guard
        application.id == mapping.newApplicationID,
        application.storageID == mapping.applicationStorageID
      else {
        throw LibraryMigrationError.invalidJournal
      }
    }

    let flattened = applications.enumerated().flatMap {
      applicationOccurrence, application in
      application.profiles.map { (applicationOccurrence, application, $0) }
    }
    for mapping in journal.mappings {
      guard flattened.indices.contains(mapping.profileOccurrence) else {
        throw LibraryMigrationError.invalidJournal
      }
      let expected = flattened[mapping.profileOccurrence]
      guard
        expected.0 == mapping.applicationOccurrence,
        expected.1.id == mapping.newApplicationID,
        expected.1.storageID == mapping.applicationStorageID,
        expected.2.id == mapping.newProfileID,
        expected.2.storageID == mapping.profileStorageID
      else {
        throw LibraryMigrationError.invalidJournal
      }
      let basePath =
        expected.1.baseStoragePath?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      guard !basePath.isEmpty else {
        throw LibraryMigrationError.invalidJournal
      }
      let resolved = try ManagedPathResolver(fileSystem: fileSystem).resolve(
        configuredBaseRoot: basePath,
        applicationStorageID: mapping.applicationStorageID,
        profileStorageID: mapping.profileStorageID
      )
      guard
        resolved.profileRoot.url.path
          == mapping.newCanonicalPath
      else {
        throw LibraryMigrationError.invalidJournal
      }
    }
  }

  func journal(matchingSourceHash hash: String) throws -> MigrationJournal? {
    let incomplete = try allIncompleteJournals()
    let matches = incomplete.filter { $0.sourceSHA256 == hash }
    guard matches.count <= 1, matches.count == incomplete.count else {
      throw LibraryMigrationError.recoveryConflict
    }
    return matches.first
  }

  func allIncompleteJournals() throws -> [MigrationJournal] {
    let root = migrationsRootURL
    guard fileSystem.fileExists(at: root) else { return [] }
    var result: [MigrationJournal] = []
    for directory in try fileSystem.contentsOfDirectory(at: root)
      .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    {
      guard try fileSystem.attributesOfItem(at: directory).kind == .directory else {
        throw LibraryMigrationError.recoveryConflict
      }
      let receipt = directory.appendingPathComponent("receipt.json")
      let pending = directory.appendingPathComponent("receipt.pending.json")
      let journalURL = directory.appendingPathComponent("journal.json")
      guard fileSystem.fileExists(at: journalURL) else {
        throw LibraryMigrationError.recoveryConflict
      }
      let journal = try JSONDecoder().decode(
        MigrationJournal.self,
        from: fileSystem.readData(at: journalURL)
      )
      guard
        journal.schemaVersion == Self.schemaVersion,
        directory.lastPathComponent
          == journal.migrationID.uuidString.lowercased()
      else {
        throw LibraryMigrationError.invalidJournal
      }
      if fileSystem.fileExists(at: receipt),
        !fileSystem.fileExists(at: pending)
      {
        continue
      }
      result.append(journal)
    }
    return result
  }

  func rollbackOwnedState(
    for journal: MigrationJournal,
    sourceRecords: [SourceRecord]
  ) throws {
    for mapping in journal.mappings {
      guard
        let sourceRecord = sourceRecords.first(where: {
          $0.profileOccurrence == mapping.profileOccurrence
        })
      else {
        throw LibraryMigrationError.invalidJournal
      }
      let resolved = try ManagedPathResolver(fileSystem: fileSystem).resolve(
        baseRootURL: sourceRecord.baseRoot,
        applicationStorageID: mapping.applicationStorageID,
        profileStorageID: mapping.profileStorageID
      )
      guard
        resolved.profileRoot.url.path
          == mapping.newCanonicalPath
      else {
        throw LibraryMigrationError.invalidJournal
      }
      let ownerURL = ownerMarkerURL(
        destination: resolved.profileRoot.url,
        mapping: mapping
      )
      let ownerExists = fileSystem.fileExists(at: ownerURL)
      if ownerExists {
        guard
          try fileSystem.readData(at: ownerURL)
            == ownerData(for: journal, mapping: mapping)
        else {
          throw LibraryMigrationError.recoveryConflict
        }
      }
      let publication = try readPublicationState(
        journal: journal,
        mapping: mapping
      )
      let destination = resolved.profileRoot.url
      if fileSystem.fileExists(at: destination) {
        guard
          ownerExists || publication != nil,
          let expectedDigest = mapping.sourceManifestSHA256,
          sourceRecord.sourceExists,
          let sourceManifest = sourceRecord.sourceManifest,
          manifestSHA256(sourceManifest) == expectedDigest,
          manifestSHA256(try directoryManifest(at: destination))
            == expectedDigest
        else {
          throw LibraryMigrationError.recoveryConflict
        }
        if !ownerExists, publication != nil {
          try writePublicationState(
            journal: journal,
            mapping: mapping,
            state: .published
          )
          continue
        }
        _ = try ManagedPathResolver(fileSystem: fileSystem)
          .revalidateForMutation(resolved.profileRoot)
        try fileSystem.removeItem(at: destination)
      }
      if ownerExists {
        _ = try ManagedPathResolver(fileSystem: fileSystem)
          .revalidateForMutation(resolved.profileRoot)
        try fileSystem.removeItem(at: ownerURL)
      }
      if publication != nil {
        let publicationURL = publicationURL(
          migrationID: journal.migrationID,
          mapping: mapping
        )
        try fileSystem.removeItem(at: publicationURL)
      }
    }
    try removeStagingRoots(for: journal)
    let pending = controlPaths(for: journal.migrationID).pendingReceipt
    if fileSystem.fileExists(at: pending) {
      try fileSystem.removeItem(at: pending)
    }
    let pendingLibrary = controlPaths(for: journal.migrationID).pendingLibrary
    if fileSystem.fileExists(at: pendingLibrary) {
      try fileSystem.removeItem(at: pendingLibrary)
    }
    let rollbackRequired = controlPaths(for: journal.migrationID).directory
      .appendingPathComponent("rollback-required.json")
    if fileSystem.fileExists(at: rollbackRequired) {
      try fileSystem.removeItem(at: rollbackRequired)
    }
  }

  func cleanUnjournaledControlStateIfNeeded(
    journal: MigrationJournal
  ) throws {
    let paths = controlPaths(for: journal.migrationID)
    guard
      fileSystem.fileExists(at: paths.directory),
      !fileSystem.fileExists(at: paths.journal)
    else {
      return
    }
    try fileSystem.removeItem(at: paths.directory)
    if fileSystem.fileExists(at: migrationsRootURL),
      (try? fileSystem.contentsOfDirectory(at: migrationsRootURL).isEmpty) == true
    {
      try fileSystem.removeItem(at: migrationsRootURL)
    }
  }

  func removeStagingRoots(for journal: MigrationJournal) throws {
    var roots: [ManagedStagingRootPath] = []
    for mapping in journal.mappings {
      let resolved = try resolvedPaths(for: mapping)
      let staging = try resolved.stagingRoot(
        transactionID: journal.migrationID
      )
      if !roots.contains(where: { $0.url == staging.url }) {
        roots.append(staging)
      }
    }
    for root in roots where fileSystem.fileExists(at: root.url) {
      let validated = try ManagedPathResolver(fileSystem: fileSystem)
        .revalidateForMutation(root)
      guard validated == root.url else {
        throw LibraryMigrationError.recoveryConflict
      }
      try fileSystem.removeItem(at: validated)
    }
  }
}
