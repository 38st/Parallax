import Foundation
import CryptoKit

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

enum LibraryPersistenceSnapshot: Hashable, Sendable {
    case missing
    case current([ManagedApplication])
    case legacy(LegacyLibrarySnapshot)
}

struct LibraryPersistence: LibraryPersisting {
    private let fileSystem: any FileSystem
    private let applicationSupportURL: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        fileSystem: any FileSystem = LocalFileSystem(),
        applicationSupportURL: URL? = nil
    ) {
        self.fileSystem = fileSystem
        self.applicationSupportURL = applicationSupportURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    init(fileManager: FileManager, applicationSupportURL: URL? = nil) {
        self.init(
            fileSystem: LocalFileSystem(fileManager: fileManager),
            applicationSupportURL: applicationSupportURL
        )
    }

    func load() throws -> [ManagedApplication] {
        switch try loadResult() {
        case let .current(applications):
            return applications
        case let .migrationRequired(legacy):
            throw LibraryPersistenceError.migrationRequired(format: legacy.format)
        }
    }

    func loadResult() throws -> LibraryLoadResult {
        switch try loadSnapshot() {
        case .missing:
            return .current([])
        case let .current(applications):
            return .current(applications)
        case let .legacy(snapshot):
            let outcome = try LibraryMigrationCoordinator(
                fileSystem: fileSystem,
                applicationSupportURL: try resolvedApplicationSupportURL()
            ).migrateIfNeeded()
            switch outcome {
            case let .current(applications), let .migrated(applications, _):
                return .current(applications)
            case .requiresResolution:
                return .migrationRequired(snapshot.library)
            }
        }
    }

    func loadSnapshot() throws -> LibraryPersistenceSnapshot {
        let url = try libraryURL()
        guard fileSystem.fileExists(at: url) else { return .missing }
        let originalBytes = try fileSystem.readData(at: url)
        switch try Self.decodeLibrary(from: originalBytes, decoder: decoder) {
        case let .current(applications):
            return .current(applications)
        case let .migrationRequired(library):
            return .legacy(
                LegacyLibrarySnapshot(
                    originalBytes: originalBytes,
                    sourceByteCount: originalBytes.count,
                    sourceSHA256: Self.sha256(originalBytes),
                    library: library
                )
            )
        }
    }

    func save(_ applications: [ManagedApplication]) throws {
        try Self.validateCurrentApplications(applications)
        let url = try libraryURL()
        let parentURL = url.deletingLastPathComponent()
        try fileSystem.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        let temporaryURL = parentURL.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let data = try encoder.encode(LibraryDocument(applications: applications))

        do {
            try fileSystem.writeData(data, to: temporaryURL)
            try fileSystem.replaceItem(at: url, withItemAt: temporaryURL)
        } catch {
            if fileSystem.fileExists(at: temporaryURL) {
                do {
                    try fileSystem.removeItem(at: temporaryURL)
                } catch {
                    AppLog.persistence.error(
                        "Failed to remove temporary library file: \(error.localizedDescription)"
                    )
                }
            }
            throw error
        }
    }

    static func decodeApplications(from data: Data, decoder: JSONDecoder = JSONDecoder()) throws -> [ManagedApplication] {
        switch try decodeLibrary(from: data, decoder: decoder) {
        case let .current(applications):
            return applications
        case let .migrationRequired(legacy):
            throw LibraryPersistenceError.migrationRequired(format: legacy.format)
        }
    }

    static func decodeLibrary(
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> LibraryLoadResult {
        let object = try JSONSerialization.jsonObject(with: data)

        if object is [Any] {
            let applications = try decoder.decode([LegacyManagedApplication].self, from: data)
            return .migrationRequired(
                LegacyLibrary(
                    format: .rawApplicationArray,
                    applications: applications
                )
            )
        }

        guard
            let dictionary = object as? [String: Any],
            let version = dictionary["version"] as? Int
        else {
            throw LibraryPersistenceError.invalidTopLevel
        }

        guard version > 0 else {
            throw LibraryPersistenceError.invalidVersion(found: version)
        }

        guard version <= LibraryDocument.currentVersion else {
            throw LibraryPersistenceError.unsupportedVersion(
                found: version,
                supported: LibraryDocument.currentVersion
            )
        }

        switch version {
        case 1:
            let document = try decoder.decode(LegacyLibraryDocument.self, from: data)
            return .migrationRequired(
                LegacyLibrary(
                    format: .versioned(document.version),
                    applications: document.applications
                )
            )
        case LibraryDocument.currentVersion:
            let document = try decoder.decode(LibraryDocument.self, from: data)
            guard document.version == LibraryDocument.currentVersion else {
                throw LibraryPersistenceError.invalidVersion(found: document.version)
            }
            try validateCurrentApplications(document.applications)
            return .current(document.applications)
        default:
            throw LibraryPersistenceError.invalidVersion(found: version)
        }
    }

    static func validateCurrentApplications(
        _ applications: [ManagedApplication]
    ) throws {
        var applicationIDs = Set<UUID>()
        var applicationStorageIDs = Set<UUID>()
        var profileIDs = Set<UUID>()
        var profileStorageIDs = Set<UUID>()

        for application in applications {
            guard applicationIDs.insert(application.id).inserted else {
                throw LibraryPersistenceError.duplicateApplicationID(application.id)
            }
            guard applicationStorageIDs.insert(application.storageID).inserted else {
                throw LibraryPersistenceError.duplicateApplicationStorageID(application.storageID)
            }

            for profile in application.profiles {
                guard profileIDs.insert(profile.id).inserted else {
                    throw LibraryPersistenceError.duplicateProfileID(profile.id)
                }
                guard profileStorageIDs.insert(profile.storageID).inserted else {
                    throw LibraryPersistenceError.duplicateProfileStorageID(profile.storageID)
                }
            }
        }

        if let sharedStorageID = applicationStorageIDs.intersection(profileStorageIDs).first {
            throw LibraryPersistenceError.sharedStorageID(sharedStorageID)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func libraryURL() throws -> URL {
        try resolvedApplicationSupportURL()
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
    }

    private func resolvedApplicationSupportURL() throws -> URL {
        if let applicationSupportURL {
            return applicationSupportURL
        }
        return try fileSystem.applicationSupportURL(create: true)
    }
}
