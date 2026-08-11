import CryptoKit
import Foundation

enum LibraryDocumentCodec {
    static func encodeDocument(_ document: LibraryDocument) throws -> Data {
        guard document.version == LibraryDocument.currentVersion else {
            throw LibraryPersistenceError.invalidVersion(found: document.version)
        }
        try validateCurrentApplications(document.applications)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    static func decodeApplications(
        from data: Data,
        decoder: JSONDecoder = JSONDecoder()
    ) throws -> [ManagedApplication] {
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
            let applications = try decoder.decode(
                [LegacyManagedApplication].self,
                from: data
            )
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
            let document = try decoder.decode(
                LegacyLibraryDocument.self,
                from: data
            )
            return .migrationRequired(
                LegacyLibrary(
                    format: .versioned(document.version),
                    applications: document.applications
                )
            )
        case LibraryDocument.currentVersion:
            let document = try decodeCurrentDocument(
                from: data,
                decoder: decoder
            )
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
                throw LibraryPersistenceError.duplicateApplicationID(
                    application.id
                )
            }
            guard applicationStorageIDs.insert(application.storageID).inserted
            else {
                throw LibraryPersistenceError.duplicateApplicationStorageID(
                    application.storageID
                )
            }

            for profile in application.profiles {
                guard profileIDs.insert(profile.id).inserted else {
                    throw LibraryPersistenceError.duplicateProfileID(
                        profile.id
                    )
                }
                guard profileStorageIDs.insert(profile.storageID).inserted else {
                    throw LibraryPersistenceError.duplicateProfileStorageID(
                        profile.storageID
                    )
                }
            }
        }

        if let sharedStorageID = applicationStorageIDs
            .intersection(profileStorageIDs).first
        {
            throw LibraryPersistenceError.sharedStorageID(sharedStorageID)
        }
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}
