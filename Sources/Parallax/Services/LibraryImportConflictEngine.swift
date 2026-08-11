import Foundation

/// An import candidate whose application path has already been canonicalized by
/// structural validation. The conflict engine is pure and never touches disk.
struct LibraryImportApplication: Sendable, Equatable {
  let application: ManagedApplication
  let canonicalApplicationPath: String
}

enum LibraryImportApplicationField: String, Sendable, Hashable, CaseIterable {
  case displayName
  case bundleIdentifier
  case applicationPath
  case preset
  case baseStoragePath
}

enum LibraryImportProfileField: String, Sendable, Hashable, CaseIterable {
  case name
  case arguments
  case environment
  case notes
  case isolationOwnership
  case childEnvironmentPolicy
  case sensitiveEnvironmentKeys
  case launchConfigurationTrust
  case lastLaunchedAt
}

enum LibraryImportConflictReason: Sendable, Hashable {
  case applicationIdentity
  case applicationStorageIdentity
  case canonicalApplicationPath
  case bundleIdentifierRelocation
  case normalizedApplicationName
  case applicationFields(Set<LibraryImportApplicationField>)
  case profileIdentity
  case profileStorageIdentity
  case normalizedProfileName
  case profileFields(Set<LibraryImportProfileField>)
  case ambiguousApplicationMatch
  case ambiguousProfileMatch
}

struct LibraryImportConflictID: Sendable, Hashable {
  let importedApplicationID: UUID
  let importedProfileID: UUID?
  let existingApplicationIDs: [UUID]
  let existingProfileIDs: [UUID]
}

enum LibraryImportConflictScope: Sendable, Equatable {
  case application
  case profile
}

struct LibraryImportConflict: Sendable, Equatable {
  let id: LibraryImportConflictID
  let scope: LibraryImportConflictScope
  let importedApplicationID: UUID
  let importedProfileID: UUID?
  let existingApplicationIDs: [UUID]
  let existingProfileIDs: [UUID]
  let reasons: Set<LibraryImportConflictReason>
}

struct LibraryImportFreshProfileIdentity: Sendable, Equatable, Hashable {
  let id: UUID
  let storageID: UUID
}

struct LibraryImportFreshApplicationIdentity: Sendable, Equatable {
  let id: UUID
  let storageID: UUID
  let profileIdentities: [UUID: LibraryImportFreshProfileIdentity]
}

enum LibraryImportKeepBoth: Sendable, Equatable {
  case application(
    renamedTo: String,
    identity: LibraryImportFreshApplicationIdentity
  )
  case profile(
    renamedTo: String,
    identity: LibraryImportFreshProfileIdentity
  )
}

enum LibraryImportConflictResolution: Sendable, Equatable {
  case keepExisting(
    applicationID: UUID,
    profileID: UUID? = nil
  )
  case useImported(
    applicationID: UUID,
    profileID: UUID? = nil
  )
  case keepBoth(LibraryImportKeepBoth)
  case skip
}

struct LibraryImportResolutionResult: Sendable, Equatable {
  /// Ordered exactly as encountered in the imported batch.
  let conflicts: [LibraryImportConflict]
  let unresolvedConflictIDs: [LibraryImportConflictID]
  /// Nil until every conflict has an explicit decision. This prevents callers
  /// from accidentally persisting a preview's provisional comparison state.
  let applications: [ManagedApplication]?
  /// Replay state for presentation only. This may contain provisional choices
  /// and must never be persisted while `applications` is nil.
  let projectedApplications: [ManagedApplication]

  var isFullyResolved: Bool {
    unresolvedConflictIDs.isEmpty
  }
}

enum LibraryImportConflictEngineError: Error, Sendable, Equatable {
  case conflictResolutionDoesNotMatch
  case wrongKeepBothScope
  case missingFreshProfileIdentity(UUID)
  case freshIdentityCollision
  case emptyRename
  case renameCollision
}

/// Compatibility facade for the import flow. Components behind this boundary
/// are pure and keep discovery, decisions, identity checks, and content copying
/// independently testable without changing callers.
enum LibraryImportConflictEngine {
  static func resolve(
    existing: [LibraryImportApplication],
    imported: [LibraryImportApplication],
    resolutions: [
      LibraryImportConflictID: LibraryImportConflictResolution
    ] = [:]
  ) throws -> LibraryImportResolutionResult {
    try LibraryImportConflictResolver.resolve(
      existing: existing,
      imported: imported,
      resolutions: resolutions
    )
  }
}
