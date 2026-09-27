import Darwin
import Foundation

extension LibraryMigrationCoordinator {
  @discardableResult
  func validateRetainedLegacySources(
    for journal: MigrationJournal
  ) throws -> LegacyLibrary {
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
    return legacy
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
    try validateCommittedJournal(journal, against: legacy)
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
        source.canonicalSourceURL.path == mapping.oldCanonicalPath
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
      if source.sourceExists != (mapping.disposition == .retainedInPlace)
        || source.sourceManifest.map(manifestSHA256) != mapping.sourceManifestSHA256
      {
        // Only this mapping's owned state can make refreshing its manifest
        // unsafe. Other unchanged sources can still be rolled back normally.
        guard try !hasOwnedState(for: mapping, journal: journal) else {
          throw LibraryMigrationError.invalidJournal
        }
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

}
