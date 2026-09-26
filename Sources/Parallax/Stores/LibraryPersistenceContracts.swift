import Foundation

protocol LibraryPersisting {
    func load() throws -> [ManagedApplication]
    func loadResult() throws -> LibraryLoadResult
    func save(_ applications: [ManagedApplication]) throws
}

extension LibraryPersisting {
    func loadResult() throws -> LibraryLoadResult {
        .current(try load())
    }
}

/// The persistence operations needed by repository-backed loading. The lock
/// capability keeps migration and finalization on the repository's own root.
protocol LibraryRepositoryPersistence: LibraryPersisting, Sendable {
    func resolvedApplicationSupportURL() throws -> URL
    func loadResultWhileLocked(access: LibraryExclusiveAccess) throws -> LibraryLoadResult
    func finalizeCommittedMigrationIfNeeded(
        applications: [ManagedApplication],
        access: LibraryExclusiveAccess
    ) -> String?
}

enum LibraryPersistenceError: LocalizedError, Equatable {
    case unsupportedVersion(found: Int, supported: Int)
    case invalidVersion(found: Int)
    case migrationRequired(format: LegacyLibrary.Format)
    case invalidTopLevel
    case duplicateApplicationID(UUID)
    case duplicateApplicationStorageID(UUID)
    case duplicateProfileID(UUID)
    case duplicateProfileStorageID(UUID)
    case sharedStorageID(UUID)

    var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(found, supported):
            String(localized: "The library was written by a newer version of Parallax (format v\(found)). This build supports up to v\(supported).")
        case let .invalidVersion(found):
            String(localized: "The library has an invalid format version (\(found)).")
        case .migrationRequired:
            String(localized: "This library uses the legacy v1 format and must be migrated before it can be edited.")
        case .invalidTopLevel:
            String(localized: "The library must contain a versioned document or a legacy application array.")
        case let .duplicateApplicationID(id):
            String(localized: "The library contains duplicate application identity \(id.uuidString).")
        case let .duplicateApplicationStorageID(id):
            String(localized: "The library contains duplicate application storage identity \(id.uuidString).")
        case let .duplicateProfileID(id):
            String(localized: "The library contains duplicate profile identity \(id.uuidString).")
        case let .duplicateProfileStorageID(id):
            String(localized: "The library contains duplicate profile storage identity \(id.uuidString).")
        case let .sharedStorageID(id):
            String(localized: "The library reuses storage identity \(id.uuidString) for different record types.")
        }
    }
}

struct LegacyLibrarySnapshot: Hashable, Sendable {
    let originalBytes: Data
    let sourceByteCount: Int
    let sourceSHA256: String
    let library: LegacyLibrary
}

struct CurrentLibrarySnapshot: Hashable, Sendable {
    let document: LibraryDocument
    let originalBytes: Data
    let sourceSHA256: String
}

struct LibraryPersistenceFailure: Error, Sendable {
    let originalBytes: Data?
    let error: any Error
}

enum LibraryPersistenceInspection: Sendable {
    case missing
    case current(CurrentLibrarySnapshot)
    case legacy(LegacyLibrarySnapshot)
    case recoveryRequired(LibraryPersistenceFailure)
}

enum LibraryPreparedWriteResult: Sendable {
    case target(
        CurrentLibrarySnapshot,
        failure: LibraryPersistenceFailure?
    )
    case stale(LibraryVersionToken)
    case prior(LibraryPersistenceFailure)
    case neither(LibraryPersistenceFailure)
}

enum LibraryPersistenceSnapshot: Hashable, Sendable {
    case missing
    case current([ManagedApplication])
    case legacy(LegacyLibrarySnapshot)
}

struct LibraryOperationInProgressError: LocalizedError {
    var errorDescription: String? {
        String(localized: "Another Parallax operation is in progress. Parallax will check again automatically.")
    }
}

struct LibraryMigrationResolutionRequired: LocalizedError {
    let library: LegacyLibrary
    let blockers: [LibraryMigrationBlocker]

    var errorDescription: String? {
        let details: String = blockers.map { blocker in
            let reason: String = blocker.localizedReason
            guard !blocker.canonicalPaths.isEmpty else { return reason }
            let paths: String = LibraryLocalizedList.string(from: blocker.canonicalPaths)
            return String(localized: "\(reason) Paths: \(paths)")
        }.joined(separator: "\n")
        return String(localized: "Library migration needs attention:\n\(details)")
    }
}

extension LibraryMigrationBlocker {
    var localizedReason: String {
        switch kind {
        case .reservedArchiveAmbiguity:
            String(localized: "A reserved archive path is ambiguous.")
        case .caseInsensitiveSourceCollision:
            String(localized: "Legacy paths differ only by letter case.")
        case .canonicalSourceCollision:
            String(localized: "Legacy paths resolve to the same location.")
        case .unsafeLegacyStorageName:
            String(localized: "A legacy storage name is unsafe.")
        case .sharedApplicationRoot:
            String(localized: "Applications share a legacy storage root.")
        case .unexpectedDestination:
            String(localized: "A migration destination already exists.")
        case .invalidBaseStorageRoot:
            String(localized: "The legacy storage root is invalid.")
        case .sourceOutsideManagedRoot:
            String(localized: "A legacy path is outside its managed root.")
        case .unsupportedSourceItem:
            String(localized: "Legacy data contains an unsupported filesystem item.")
        }
    }
}
