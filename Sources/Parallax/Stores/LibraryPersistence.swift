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

struct LibraryPersistence: LibraryPersisting {
    private let fileSystem: any FileSystem
    private let applicationSupportURL: URL?
    private var decoder: JSONDecoder { JSONDecoder() }

    init(
        fileSystem: any FileSystem = LocalFileSystem(),
        applicationSupportURL: URL? = nil
    ) {
        self.fileSystem = fileSystem
        self.applicationSupportURL = applicationSupportURL
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

    func inspect() -> LibraryPersistenceInspection {
        let url: URL
        do {
            url = try libraryURL()
        } catch {
            return .recoveryRequired(
                LibraryPersistenceFailure(originalBytes: nil, error: error)
            )
        }

        guard fileSystem.fileExists(at: url) else { return .missing }

        let originalBytes: Data
        do {
            originalBytes = try fileSystem.readData(at: url)
        } catch {
            return .recoveryRequired(
                LibraryPersistenceFailure(originalBytes: nil, error: error)
            )
        }

        do {
            switch try Self.decodeLibrary(from: originalBytes, decoder: decoder) {
            case .current:
                return .current(
                    CurrentLibrarySnapshot(
                        document: try Self.decodeCurrentDocument(
                            from: originalBytes,
                            decoder: decoder
                        ),
                        originalBytes: originalBytes,
                        sourceSHA256: Self.sha256(originalBytes)
                    )
                )
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
        } catch {
            return .recoveryRequired(
                LibraryPersistenceFailure(
                    originalBytes: originalBytes,
                    error: error
                )
            )
        }
    }

    func save(_ applications: [ManagedApplication]) throws {
        try saveDocument(LibraryDocument(applications: applications))
    }

    func saveDocument(_ document: LibraryDocument) throws {
        guard document.version == LibraryDocument.currentVersion else {
            throw LibraryPersistenceError.invalidVersion(found: document.version)
        }
        let applications = document.applications
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
        let data = try encodeDocument(document)

        do {
            try fileSystem.writeData(data, to: temporaryURL)
            try fileSystem.setPOSIXPermissions(0o600, at: temporaryURL)
            try fileSystem.synchronize(at: temporaryURL)
            try fileSystem.replaceItem(at: url, withItemAt: temporaryURL)
            try fileSystem.synchronize(at: url)
            try fileSystem.synchronize(at: parentURL)
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

    func encodeDocument(_ document: LibraryDocument) throws -> Data {
        guard document.version == LibraryDocument.currentVersion else {
            throw LibraryPersistenceError.invalidVersion(found: document.version)
        }
        try Self.validateCurrentApplications(document.applications)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// Publishes caller-prepared bytes and classifies the primary after every
    /// potentially ambiguous replacement result.
    ///
    /// The expected token is checked after the temporary file is durable and
    /// immediately before replacement. A target match is treated as committed,
    /// a prior match as not committed, and any other state as recovery-required.
    func commitPreparedDocument(
        _ targetBytes: Data,
        expectedVersion: LibraryVersionToken,
        targetVersion: LibraryVersionToken
    ) -> LibraryPreparedWriteResult {
        do {
            let document = try Self.decodeCurrentDocument(
                from: targetBytes,
                decoder: decoder
            )
            guard
                document.revision == targetVersion.revision,
                Self.sha256(targetBytes) == targetVersion.primarySHA256
            else {
                return .neither(
                    failure(
                        bytes: targetBytes,
                        error: PreparedCommitVerificationError.invalidTarget
                    )
                )
            }
        } catch {
            return .neither(failure(bytes: targetBytes, error: error))
        }

        let url: URL
        do {
            url = try libraryURL()
        } catch {
            return .prior(failure(bytes: nil, error: error))
        }
        let parentURL = url.deletingLastPathComponent()
        let temporaryURL = parentURL.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )

        do {
            try fileSystem.createDirectory(
                at: parentURL,
                withIntermediateDirectories: true
            )
            try fileSystem.writeData(targetBytes, to: temporaryURL)
            try fileSystem.setPOSIXPermissions(0o600, at: temporaryURL)
            try fileSystem.synchronize(at: temporaryURL)

            switch inspect() {
            case .missing:
                guard expectedVersion == .missing else {
                    try? removeTemporary(temporaryURL)
                    return .stale(.missing)
                }
            case let .current(snapshot):
                let actual = versionToken(for: snapshot)
                guard actual == expectedVersion else {
                    try? removeTemporary(temporaryURL)
                    return .stale(actual)
                }
            case let .legacy(snapshot):
                try? removeTemporary(temporaryURL)
                return .neither(
                    failure(
                        bytes: snapshot.originalBytes,
                        error: LibraryPersistenceError.migrationRequired(
                            format: snapshot.library.format
                        )
                    )
                )
            case let .recoveryRequired(problem):
                try? removeTemporary(temporaryURL)
                return .neither(problem)
            }

            do {
                try fileSystem.replaceItem(
                    at: url,
                    withItemAt: temporaryURL
                )
                try fileSystem.synchronize(at: url)
                try fileSystem.synchronize(at: parentURL)
                return classifyPrimary(
                    expectedVersion: expectedVersion,
                    targetVersion: targetVersion,
                    underlyingError: nil
                )
            } catch {
                let result = classifyPrimary(
                    expectedVersion: expectedVersion,
                    targetVersion: targetVersion,
                    underlyingError: error
                )
                try? removeTemporary(temporaryURL)
                return result
            }
        } catch {
            let result = classifyPrimary(
                expectedVersion: expectedVersion,
                targetVersion: targetVersion,
                underlyingError: error
            )
            try? removeTemporary(temporaryURL)
            return result
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

    static func decodeCurrentDocument(
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> LibraryDocument {
        let document = try decoder.decode(LibraryDocument.self, from: data)
        guard document.version == LibraryDocument.currentVersion else {
            if document.version > LibraryDocument.currentVersion {
                throw LibraryPersistenceError.unsupportedVersion(
                    found: document.version,
                    supported: LibraryDocument.currentVersion
                )
            }
            throw LibraryPersistenceError.invalidVersion(found: document.version)
        }
        try validateCurrentApplications(document.applications)
        return document
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
            let document = try decodeCurrentDocument(from: data, decoder: decoder)
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

    func libraryURL() throws -> URL {
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

    private func classifyPrimary(
        expectedVersion: LibraryVersionToken,
        targetVersion: LibraryVersionToken,
        underlyingError: (any Error)?
    ) -> LibraryPreparedWriteResult {
        switch inspect() {
        case .missing:
            if expectedVersion == .missing {
                return .prior(
                    failure(
                        bytes: nil,
                        error: underlyingError
                            ?? PreparedCommitVerificationError.targetNotObserved
                    )
                )
            }
            return .neither(
                failure(
                    bytes: nil,
                    error: underlyingError
                        ?? PreparedCommitVerificationError.targetNotObserved
                )
            )
        case let .current(snapshot):
            let actual = versionToken(for: snapshot)
            if actual == targetVersion {
                return .target(
                    snapshot,
                    failure: underlyingError.map {
                        failure(
                            bytes: snapshot.originalBytes,
                            error: $0
                        )
                    }
                )
            }
            if actual == expectedVersion {
                return .prior(
                    failure(
                        bytes: snapshot.originalBytes,
                        error: underlyingError
                            ?? PreparedCommitVerificationError.targetNotObserved
                    )
                )
            }
            return .neither(
                failure(
                    bytes: snapshot.originalBytes,
                    error: underlyingError
                        ?? PreparedCommitVerificationError.targetNotObserved
                )
            )
        case let .legacy(snapshot):
            return .neither(
                failure(
                    bytes: snapshot.originalBytes,
                    error: underlyingError
                        ?? PreparedCommitVerificationError.targetNotObserved
                )
            )
        case let .recoveryRequired(problem):
            return .neither(
                failure(
                    bytes: problem.originalBytes,
                    error: underlyingError
                        ?? PreparedCommitVerificationError.targetNotObserved
                )
            )
        }
    }

    private func versionToken(
        for snapshot: CurrentLibrarySnapshot
    ) -> LibraryVersionToken {
        LibraryVersionToken(
            revision: snapshot.document.revision,
            primarySHA256: snapshot.sourceSHA256
        )
    }

    private func failure(
        bytes: Data?,
        error: any Error
    ) -> LibraryPersistenceFailure {
        LibraryPersistenceFailure(originalBytes: bytes, error: error)
    }

    private func removeTemporary(_ url: URL) throws {
        if fileSystem.fileExists(at: url) {
            try fileSystem.removeItem(at: url)
        }
    }
}

private enum PreparedCommitVerificationError: LocalizedError {
    case invalidTarget
    case targetNotObserved

    var errorDescription: String? {
        switch self {
        case .invalidTarget:
            String(localized: "The prepared library bytes do not match their target token.")
        case .targetNotObserved:
            String(localized: "The prepared library replacement did not leave the expected target active.")
        }
    }
}
