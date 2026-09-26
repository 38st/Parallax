import AppKit
import Foundation
import Observation

enum GeneratedDisplayNameError: LocalizedError, Equatable {
  case importedCopyUnavailable

  var errorDescription: String? {
    switch self {
    case .importedCopyUnavailable:
      String(
        localized:
          "Parallax could not create a unique valid name for the imported copy."
      )
    }
  }
}
// MARK: - Import session support

extension LibraryStore {
  func continueMergeImport(
    _ pending: PreparedLibraryImport,
    resolutions: [
      LibraryImportConflictID: LibraryImportConflictResolution
    ]
  ) throws {
    try validatePendingImportVersion(pending)
    let existing = applications.map {
      LibraryImportApplication(
        application: $0,
        canonicalApplicationPath: URL(
          fileURLWithPath: $0.appPath
        ).standardizedFileURL.path
      )
    }
    let result = try LibraryImportConflictEngine.resolve(
      existing: existing,
      imported: pending.canonicalApplications,
      resolutions: resolutions
    )
    if let conflict = result.conflicts.first(where: {
      result.unresolvedConflictIDs.contains($0.id)
    }) {
      libraryImportFlowState = .resolving(
        LibraryImportMergeSession(
          preparedImport: pending,
          resolutions: resolutions,
          conflict: conflict,
          projectedApplications: result.projectedApplications
        )
      )
      return
    }
    guard let candidate = result.applications else {
      throw LibraryImportStoreError.unresolvedConflict
    }
    let selection = importSelection(in: candidate)
    let overwritesMetadata = resolutions.values.contains {
      if case .useImported = $0 { return true }
      return false
    }
    if candidate != applications {
      guard commit(
        candidate,
        selectedApplicationID: selection.applicationID,
        selectedProfileID: selection.profileID,
        backupReason: overwritesMetadata ? .destructiveRewrite : nil
      ) else { return }
    }
    finishImport()
    launchStatusMessage = String(localized: "Imported library metadata")
  }

  func validatePendingImportVersion(
    _ pending: PreparedLibraryImport
  ) throws {
    guard pending.expectedVersion == libraryVersionToken else {
      finishImport()
      throw LibraryImportStoreError.staleImportSession
    }
  }

  func importSelection(
    in candidate: [ManagedApplication]
  ) -> (applicationID: UUID?, profileID: UUID?) {
    guard let application = candidate.first(where: {
      $0.id == selectedApplicationID
    }) else { return (nil, nil) }
    return (
      application.id,
      application.profiles.contains { $0.id == selectedProfileID }
        ? selectedProfileID : nil
    )
  }

  func handleImportReplacementFailure(_ error: Error) {
    switch error {
    case let failure as LibraryImportReplacementError
      where failure.code == .replacementFailedAndRolledBack
        || failure.code == .recoveryRequired:
      break
    case LibraryRepositoryError.commitFailed(let state, _) where state != .prior:
      break
    default:
      return
    }
    finishImport()
    lastImportReplacement = nil
    if case .migrationRequired(let snapshot) = repository?.load() {
      // Preserve the legacy bytes and migration actions without starting a
      // second disk mutation while handling the failed replacement.
      applications = []
      selectedApplicationID = nil
      selectedProfileID = nil
      libraryVersionToken = nil
      migrationRequiredLibrary = snapshot.library
      loadState = .recoveryRequired(
        originalBytes: snapshot.originalBytes,
        message: LibraryPersistenceError.migrationRequired(
          format: snapshot.library.format
        ).localizedDescription
      )
    } else {
      libraryVersionToken = nil
      migrationRequiredLibrary = nil
      // The repository's current outcome owns readable, recovery, and
      // newer-version presentation, even when the failed write was observed.
      reloadFromSharedRepository()
    }
    publishLibraryChange()
  }

  func finishImport() {
    libraryImportFlowState = .idle
  }

  func encodedImportApplications(
    _ applications: [ManagedApplication]
  ) throws -> Data {
    try encodedImportDocument(
      LibraryDocument(applications: applications)
    )
  }

  func encodedImportDocument(
    _ document: LibraryDocument
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(document)
  }

  func keepBothResolution(
    for conflict: LibraryImportConflict,
    pending: PreparedLibraryImport,
    resolutions: [
      LibraryImportConflictID: LibraryImportConflictResolution
    ] = [:],
    projectedApplications: [ManagedApplication]? = nil
  ) throws -> LibraryImportConflictResolution {
    let projectedApplications = projectedApplications ?? applications
    if conflict.scope == .application {
      guard
        let application = pending.applications.first(where: {
          $0.id == conflict.importedApplicationID
        })
      else {
        throw LibraryImportStoreError.unresolvedConflict
      }
      let occupiedNames = Set(
        projectedApplications.map {
          Self.normalizedImportName($0.displayName)
        }
      ).union(
        resolutions.values.compactMap {
          guard
            case .keepBoth(.application(let name, _)) = $0
          else { return nil }
          return Self.normalizedImportName(name)
        }
      )
      guard let rename = Self.uniqueImportedName(
        application.displayName,
        occupied: occupiedNames
      ) else {
        throw GeneratedDisplayNameError.importedCopyUnavailable
      }
      let identities = Dictionary(
        uniqueKeysWithValues: application.profiles.map {
          (
            $0.id,
            LibraryImportFreshProfileIdentity(
              id: UUID(),
              storageID: UUID()
            )
          )
        }
      )
      return .keepBoth(
        .application(
          renamedTo: rename,
          identity: LibraryImportFreshApplicationIdentity(
            id: UUID(),
            storageID: UUID(),
            profileIdentities: identities
          )
        )
      )
    }
    guard
      let importedProfileID = conflict.importedProfileID,
      let profile = pending.applications
        .flatMap(\.profiles)
        .first(where: { $0.id == importedProfileID })
    else {
      throw LibraryImportStoreError.unresolvedConflict
    }
    let occupiedNames = Set(
      projectedApplications.flatMap(\.profiles).map {
        Self.normalizedImportName($0.name)
      }
    ).union(
      resolutions.values.compactMap {
        guard
          case .keepBoth(.profile(let name, _)) = $0
        else { return nil }
        return Self.normalizedImportName(name)
      }
    )
    guard let rename = Self.uniqueImportedName(
      profile.name,
      occupied: occupiedNames
    ) else {
      throw GeneratedDisplayNameError.importedCopyUnavailable
    }
    return .keepBoth(
      .profile(
        renamedTo: rename,
        identity: LibraryImportFreshProfileIdentity(
          id: UUID(),
          storageID: UUID()
        )
      )
    )
  }

}
