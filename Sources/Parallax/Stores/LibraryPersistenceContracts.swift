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

struct LibraryPersistenceFailure: Error, @unchecked Sendable {
    let originalBytes: Data?
    let error: any Error
}

enum LibraryPersistenceInspection: @unchecked Sendable {
    case missing
    case current(CurrentLibrarySnapshot)
    case legacy(LegacyLibrarySnapshot)
    case recoveryRequired(LibraryPersistenceFailure)
}

enum LibraryPreparedWriteResult: @unchecked Sendable {
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
