import Darwin
import Foundation

// MARK: - Inventory and planning

extension LibraryMigrationCoordinator {
  struct SourceRecord: Sendable {
    let applicationOccurrence: Int
    let profileOccurrence: Int
    let legacyApplication: LegacyManagedApplication
    let legacyProfile: LegacyLaunchProfile
    let baseRoot: URL
    let canonicalBaseRoot: URL
    let applicationRoot: URL
    let sourceURL: URL
    let canonicalSourceURL: URL
    let sourceExists: Bool
    let sourceIdentity: FileSystemObjectIdentity?
    let sourceManifest: DirectoryManifest?
  }

  struct SourceInventory {
    let profiles: [SourceRecord]
    let blockers: [LibraryMigrationBlocker]
  }

  struct PlannedRecord: Sendable {
    let source: SourceRecord
    let paths: ResolvedProfilePaths
    let mapping: LibraryMigrationPathMapping
  }

  struct Allocation {
    let applications: [ManagedApplication]
    let records: [PlannedRecord]
    let journal: MigrationJournal
    let blockers: [LibraryMigrationBlocker]
  }

  func inventorySources(in legacy: LegacyLibrary) throws -> SourceInventory {
    var records: [SourceRecord] = []
    var blockers: [LibraryMigrationBlocker] = []
    var applicationRootGroups: [String: [Int]] = [:]
    var profileOccurrence = 0

    for (applicationOccurrence, application) in legacy.applications.enumerated() {
      let basePath = legacyBasePath(for: application)
      let baseResolution: (configured: URL, canonical: URL)
      do {
        let paths = try ManagedPathResolver(fileSystem: fileSystem).resolve(
          configuredBaseRoot: basePath,
          applicationStorageID: Self.applicationUUID,
          profileStorageID: Self.profileUUID
        )
        guard
          try attributesIfExists(
            at: paths.profileRoot.validationContext.configuredBaseRootURL
          ) != nil
        else {
          throw ManagedPathError(
            .baseRootUnavailable,
            path: basePath
          )
        }
        baseResolution = (
          paths.profileRoot.validationContext.configuredBaseRootURL,
          paths.profileRoot.validationContext.canonicalBaseRootURL
        )
      } catch {
        blockers.append(
          LibraryMigrationBlocker(
            kind: .invalidBaseStorageRoot,
            recordOccurrences: [applicationOccurrence],
            canonicalPaths: [basePath]
          )
        )
        profileOccurrence += application.profiles.count
        continue
      }

      let applicationComponent = legacySanitizedComponent(application.displayName)
      let applicationRoot = baseResolution.configured.appendingPathComponent(
        applicationComponent,
        isDirectory: true
      )
      let canonicalApplicationRoot = canonicalExistingOrExpected(
        applicationRoot,
        canonicalBase: baseResolution.canonical,
        relativeComponents: [applicationComponent]
      )
      if try attributesIfExists(at: applicationRoot) != nil {
        let applicationRootKey = compatibilityKey(canonicalApplicationRoot.path)
        applicationRootGroups[applicationRootKey, default: []].append(
          applicationOccurrence
        )
      }

      for profile in application.profiles {
        defer { profileOccurrence += 1 }
        let rawComponent =
          profile.storageName
          ?? legacySanitizedComponent(profile.name)
        guard isSafeLegacyComponent(rawComponent) else {
          blockers.append(
            LibraryMigrationBlocker(
              kind: .unsafeLegacyStorageName,
              recordOccurrences: [profileOccurrence],
              canonicalPaths: []
            )
          )
          continue
        }

        if compatibilityKey(rawComponent) == compatibilityKey("Archives") {
          blockers.append(
            LibraryMigrationBlocker(
              kind: .reservedArchiveAmbiguity,
              recordOccurrences: [profileOccurrence],
              canonicalPaths: [applicationRoot.path]
            )
          )
          continue
        }

        let sourceURL = applicationRoot.appendingPathComponent(
          rawComponent,
          isDirectory: true
        )
        let sourceAttributes: FileSystemItemAttributes?
        do {
          sourceAttributes = try attributesIfExists(at: sourceURL)
        } catch {
          blockers.append(
            LibraryMigrationBlocker(
              kind: .unsupportedSourceItem,
              recordOccurrences: [profileOccurrence],
              canonicalPaths: [sourceURL.path]
            )
          )
          continue
        }
        let sourceExists = sourceAttributes != nil
        var canonicalSourceURL = baseResolution.canonical
          .appendingPathComponent(applicationComponent, isDirectory: true)
          .appendingPathComponent(rawComponent, isDirectory: true)
        var manifest: DirectoryManifest?
        var sourceIdentity: FileSystemObjectIdentity?

        if sourceExists {
          do {
            guard let sourceAttributes,
              sourceAttributes.kind == .directory
            else {
              blockers.append(
                LibraryMigrationBlocker(
                  kind: .unsupportedSourceItem,
                  recordOccurrences: [profileOccurrence],
                  canonicalPaths: [sourceURL.path]
                )
              )
              continue
            }
            canonicalSourceURL =
              try fileSystem
              .canonicalURL(for: sourceURL)
              .standardizedFileURL
            sourceIdentity = sourceAttributes.identity
          } catch {
            blockers.append(
              LibraryMigrationBlocker(
                kind: .unsupportedSourceItem,
                recordOccurrences: [profileOccurrence],
                canonicalPaths: [sourceURL.path]
              )
            )
            continue
          }

          guard contains(canonicalSourceURL, within: baseResolution.canonical) else {
            blockers.append(
              LibraryMigrationBlocker(
                kind: .sourceOutsideManagedRoot,
                recordOccurrences: [profileOccurrence],
                canonicalPaths: [canonicalSourceURL.path]
              )
            )
            continue
          }
          do {
            manifest = try directoryManifest(at: sourceURL)
          } catch {
            blockers.append(
              LibraryMigrationBlocker(
                kind: .unsupportedSourceItem,
                recordOccurrences: [profileOccurrence],
                canonicalPaths: [sourceURL.path]
              )
            )
            continue
          }
        }

        records.append(
          SourceRecord(
            applicationOccurrence: applicationOccurrence,
            profileOccurrence: profileOccurrence,
            legacyApplication: application,
            legacyProfile: profile,
            baseRoot: baseResolution.configured,
            canonicalBaseRoot: baseResolution.canonical,
            applicationRoot: canonicalApplicationRoot,
            sourceURL: sourceURL,
            canonicalSourceURL: canonicalSourceURL,
            sourceExists: sourceExists,
            sourceIdentity: sourceIdentity,
            sourceManifest: manifest
          )
        )
      }
    }

    for (key, occurrences) in applicationRootGroups
    where Set(occurrences).count > 1 {
      blockers.append(
        LibraryMigrationBlocker(
          kind: .sharedApplicationRoot,
          recordOccurrences: occurrences.sorted(),
          canonicalPaths: [key]
        )
      )
    }

    let existingRecords = records.filter(\.sourceExists)
    let exactGroups = Dictionary(grouping: existingRecords) {
      $0.canonicalSourceURL.standardizedFileURL.path
    }
    for (path, group) in exactGroups where group.count > 1 {
      blockers.append(
        LibraryMigrationBlocker(
          kind: .canonicalSourceCollision,
          recordOccurrences: group.map(\.profileOccurrence).sorted(),
          canonicalPaths: [path]
        )
      )
    }

    let identityGroups = Dictionary(
      grouping: existingRecords.compactMap {
        record in record.sourceIdentity.map { ($0, record) }
      }, by: \.0)
    for (_, identified) in identityGroups where identified.count > 1 {
      let group = identified.map(\.1)
      blockers.append(
        LibraryMigrationBlocker(
          kind: .canonicalSourceCollision,
          recordOccurrences: group.map(\.profileOccurrence).sorted(),
          canonicalPaths: Set(group.map(\.canonicalSourceURL.path)).sorted()
        )
      )
    }

    let compatibilityGroups = Dictionary(grouping: existingRecords) {
      compatibilityKey($0.sourceURL.standardizedFileURL.path)
    }
    for (_, group) in compatibilityGroups where group.count > 1 {
      let exactPaths = Set(group.map { $0.sourceURL.standardizedFileURL.path })
      if exactPaths.count > 1 {
        blockers.append(
          LibraryMigrationBlocker(
            kind: .caseInsensitiveSourceCollision,
            recordOccurrences: group.map(\.profileOccurrence).sorted(),
            canonicalPaths: exactPaths.sorted()
          )
        )
      }
    }

    for leftIndex in existingRecords.indices {
      for rightIndex in existingRecords.indices where rightIndex > leftIndex {
        let left = existingRecords[leftIndex]
        let right = existingRecords[rightIndex]
        if contains(left.canonicalSourceURL, within: right.canonicalSourceURL)
          || contains(right.canonicalSourceURL, within: left.canonicalSourceURL)
        {
          blockers.append(
            LibraryMigrationBlocker(
              kind: .canonicalSourceCollision,
              recordOccurrences: [
                left.profileOccurrence,
                right.profileOccurrence,
              ].sorted(),
              canonicalPaths: [
                left.canonicalSourceURL.path,
                right.canonicalSourceURL.path,
              ].sorted()
            )
          )
        }
      }
    }

    return SourceInventory(
      profiles: records,
      blockers: uniqueBlockers(blockers)
    )
  }

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
      blockers: uniqueBlockers(blockers)
    )
  }
}
