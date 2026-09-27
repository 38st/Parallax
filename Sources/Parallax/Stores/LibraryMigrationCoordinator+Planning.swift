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
    var existingApplicationRoots: [
      LibraryMigrationInventoryAnalysis.ApplicationRoot
    ] = []
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
          try application.profiles.isEmpty
            || basePath == parallaxURL.appendingPathComponent("Profiles", isDirectory: true).path
            || attributesIfExists(
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
        existingApplicationRoots.append(
          LibraryMigrationInventoryAnalysis.ApplicationRoot(
            applicationOccurrence: applicationOccurrence,
            canonicalURL: canonicalApplicationRoot
          )
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

    let existingRecords = records.filter(\.sourceExists)
    blockers.append(
      contentsOf: LibraryMigrationInventoryAnalysis.collisionBlockers(
        applicationRoots: existingApplicationRoots,
        existingSources: existingRecords.map {
          LibraryMigrationInventoryAnalysis.ExistingSource(
            profileOccurrence: $0.profileOccurrence,
            sourceURL: $0.sourceURL,
            canonicalSourceURL: $0.canonicalSourceURL,
            sourceIdentity: $0.sourceIdentity
          )
        }
      )
    )

    return SourceInventory(
      profiles: records,
      blockers: LibraryMigrationInventoryAnalysis
        .orderedUniqueBlockers(blockers)
    )
  }

}
