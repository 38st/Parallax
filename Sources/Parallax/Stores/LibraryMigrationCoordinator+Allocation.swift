import Darwin
import Foundation

extension LibraryMigrationCoordinator {
  func allocate(
    snapshot: LegacyLibrarySnapshot,
    sources: [SourceRecord],
    existingJournal: MigrationJournal?
  ) throws -> Allocation {
    if let existingJournal {
      return try allocation(
        snapshot: snapshot,
        sources: sources,
        journal: existingJournal
      )
    }

    var occupied = Set(snapshot.library.applications.map(\.id))
    occupied.formUnion(snapshot.library.applications.flatMap(\.profiles).map(\.id))
    let migrationID = nextUniqueUUID(occupied: &occupied)

    var applicationStorageIDs: [UUID] = []
    for _ in snapshot.library.applications {
      applicationStorageIDs.append(nextUniqueUUID(occupied: &occupied))
    }

    var profileStorageIDs: [UUID] = []
    for _ in snapshot.library.applications.flatMap(\.profiles) {
      profileStorageIDs.append(nextUniqueUUID(occupied: &occupied))
    }

    let duplicateApplicationIDs = duplicateValues(
      snapshot.library.applications.map(\.id)
    )
    let duplicateProfileIDs = duplicateValues(
      snapshot.library.applications.flatMap(\.profiles).map(\.id)
    )
    let newApplicationIDs = snapshot.library.applications.map { application in
      duplicateApplicationIDs.contains(application.id)
        ? nextUniqueUUID(occupied: &occupied)
        : application.id
    }
    let newProfileIDs = snapshot.library.applications
      .flatMap(\.profiles)
      .map { profile in
        duplicateProfileIDs.contains(profile.id)
          ? nextUniqueUUID(occupied: &occupied)
          : profile.id
      }

    let provisionalJournal = MigrationJournal(
      schemaVersion: Self.schemaVersion,
      migrationID: migrationID,
      sourceFormat: sourceFormat(snapshot.library.format),
      sourceSHA256: snapshot.sourceSHA256,
      sourceByteCount: snapshot.sourceByteCount,
      targetSHA256: "",
      createdAt: now(),
      applicationMappings: [],
      mappings: []
    )
    return try allocation(
      snapshot: snapshot,
      sources: sources,
      journal: provisionalJournal,
      applicationStorageIDs: applicationStorageIDs,
      profileStorageIDs: profileStorageIDs,
      applicationIDs: newApplicationIDs,
      profileIDs: newProfileIDs
    )
  }

  func allocation(
    snapshot: LegacyLibrarySnapshot,
    sources: [SourceRecord],
    journal: MigrationJournal
  ) throws -> Allocation {
    let applicationMappings = journal.applicationMappings.sorted {
      $0.applicationOccurrence < $1.applicationOccurrence
    }
    let mappings = journal.mappings.sorted { $0.profileOccurrence < $1.profileOccurrence }
    guard applicationMappings.count == snapshot.library.applications.count else {
      throw LibraryMigrationError.invalidJournal
    }
    guard mappings.count == snapshot.library.applications.flatMap(\.profiles).count else {
      throw LibraryMigrationError.invalidJournal
    }

    let applicationStorageIDs = applicationMappings.map(\.applicationStorageID)
    let applicationIDs = applicationMappings.map(\.newApplicationID)
    var profileStorageIDs = Array(
      repeating: Self.profileUUID,
      count: mappings.count
    )
    var profileIDs = snapshot.library.applications.flatMap(\.profiles).map(\.id)
    for mapping in mappings {
      guard
        mapping.applicationOccurrence < applicationStorageIDs.count,
        mapping.profileOccurrence < profileStorageIDs.count
      else {
        throw LibraryMigrationError.invalidJournal
      }
      profileStorageIDs[mapping.profileOccurrence] = mapping.profileStorageID
      profileIDs[mapping.profileOccurrence] = mapping.newProfileID
    }

    return try allocation(
      snapshot: snapshot,
      sources: sources,
      journal: journal,
      applicationStorageIDs: applicationStorageIDs,
      profileStorageIDs: profileStorageIDs,
      applicationIDs: applicationIDs,
      profileIDs: profileIDs
    )
  }

  func allocation(
    snapshot: LegacyLibrarySnapshot,
    sources: [SourceRecord],
    journal: MigrationJournal,
    applicationStorageIDs: [UUID],
    profileStorageIDs: [UUID],
    applicationIDs: [UUID],
    profileIDs: [UUID]
  ) throws -> Allocation {
    var plannedRecords: [PlannedRecord] = []
    var applications: [ManagedApplication] = []
    var blockers: [LibraryMigrationBlocker] = []
    var globalProfileOccurrence = 0

    for (applicationOccurrence, legacyApplication) in snapshot.library.applications.enumerated() {
      var profiles: [LaunchProfile] = []
      for legacyProfile in legacyApplication.profiles {
        guard
          let source = sources.first(where: {
            $0.profileOccurrence == globalProfileOccurrence
          })
        else {
          throw LibraryMigrationError.invalidJournal
        }
        let paths = try ManagedPathResolver(fileSystem: fileSystem).resolve(
          baseRootURL: source.baseRoot,
          applicationStorageID: applicationStorageIDs[applicationOccurrence],
          profileStorageID: profileStorageIDs[globalProfileOccurrence]
        )
        let isolation = isolationConfiguration(
          profile: legacyProfile,
          source: source
        )
        let mapping = LibraryMigrationPathMapping(
          applicationOccurrence: applicationOccurrence,
          profileOccurrence: globalProfileOccurrence,
          oldApplicationID: legacyApplication.id,
          newApplicationID: applicationIDs[applicationOccurrence],
          applicationStorageID: applicationStorageIDs[applicationOccurrence],
          oldProfileID: legacyProfile.id,
          newProfileID: profileIDs[globalProfileOccurrence],
          profileStorageID: profileStorageIDs[globalProfileOccurrence],
          oldCanonicalPath: source.canonicalSourceURL.path,
          newCanonicalPath: paths.profileRoot.url.path,
          disposition: source.sourceExists ? .retainedInPlace : .missing,
          isolationConfiguration: isolation,
          sourceManifestSHA256: source.sourceManifest.map(
            manifestSHA256
          )
        )
        if try attributesIfExists(at: paths.profileRoot.url) != nil {
          let ownedPublication = try readPublicationState(
            journal: journal,
            mapping: mapping
          )
          let matchesOwnedManifest: Bool
          if let expected = mapping.sourceManifestSHA256,
            ownedPublication != nil
          {
            matchesOwnedManifest =
              manifestSHA256(
                try directoryManifest(at: paths.profileRoot.url)
              ) == expected
          } else {
            matchesOwnedManifest = false
          }
          if !matchesOwnedManifest {
            blockers.append(
              LibraryMigrationBlocker(
                kind: .unexpectedDestination,
                recordOccurrences: [globalProfileOccurrence],
                canonicalPaths: [paths.profileRoot.url.path]
              )
            )
          }
        }

        let rewritten = rewrittenConfiguration(
          profile: legacyProfile,
          source: source,
          destination: paths
        )
        profiles.append(
          LaunchProfile(
            id: profileIDs[globalProfileOccurrence],
            storageID: profileStorageIDs[globalProfileOccurrence],
            name: legacyProfile.name,
            argumentsText: rewritten.arguments,
            environmentText: rewritten.environment,
            notes: legacyProfile.notes,
            // Legacy records never stored provenance. Relocation classifies an
            // exact generated path as Parallax-owned and keeps any other value.
            isolationOwnership: .legacyUnknown,
            lastLaunchedAt: legacyProfile.lastLaunchedAt
          )
        )
        plannedRecords.append(
          PlannedRecord(source: source, paths: paths, mapping: mapping)
        )
        globalProfileOccurrence += 1
      }

      applications.append(
        ManagedApplication(
          id: applicationIDs[applicationOccurrence],
          storageID: applicationStorageIDs[applicationOccurrence],
          displayName: legacyApplication.displayName,
          bundleIdentifier: legacyApplication.bundleIdentifier,
          appPath: legacyApplication.appPath,
          preset: legacyApplication.preset,
          baseStoragePath: try canonicalBasePath(
            for: legacyApplication,
            applicationOccurrence: applicationOccurrence,
            sources: sources
          ),
          profiles: profiles
        )
      )
    }

    try LibraryPersistence.validateCurrentApplications(applications)
    let targetData = try encodedLibrary(applications)
    let completeJournal = MigrationJournal(
      schemaVersion: journal.schemaVersion,
      migrationID: journal.migrationID,
      sourceFormat: journal.sourceFormat,
      sourceSHA256: journal.sourceSHA256,
      sourceByteCount: journal.sourceByteCount,
      targetSHA256: LibraryPersistence.sha256(targetData),
      createdAt: journal.createdAt,
      applicationMappings: snapshot.library.applications.enumerated().map {
        occurrence, legacyApplication in
        LibraryMigrationApplicationMapping(
          applicationOccurrence: occurrence,
          oldApplicationID: legacyApplication.id,
          newApplicationID: applicationIDs[occurrence],
          applicationStorageID: applicationStorageIDs[occurrence]
        )
      },
      mappings: plannedRecords.map(\.mapping)
    )
    return Allocation(
      applications: applications,
      records: plannedRecords,
      journal: completeJournal,
      blockers: LibraryMigrationInventoryAnalysis
        .orderedUniqueBlockers(blockers)
    )
  }
}
