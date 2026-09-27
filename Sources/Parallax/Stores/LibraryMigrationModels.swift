import Foundation
import Darwin

struct LibraryMigrationBlocker: Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        case reservedArchiveAmbiguity
        case caseInsensitiveSourceCollision
        case canonicalSourceCollision
        case unsafeLegacyStorageName
        case sharedApplicationRoot
        case unexpectedDestination
        case invalidBaseStorageRoot
        case sourceOutsideManagedRoot
        case unsupportedSourceItem
    }

    let kind: Kind
    let recordOccurrences: [Int]
    let canonicalPaths: [String]
}

struct LibraryMigrationPlan: Hashable, Sendable {
    let blockers: [LibraryMigrationBlocker]
}

struct LibraryMigrationReceipt: Hashable, Sendable, Codable {
    let schemaVersion: Int
    let migrationID: UUID
    let sourceFormat: String
    let sourceSHA256: String
    let sourceByteCount: Int
    let targetSHA256: String
    let backupRelativePath: String
    let startedAt: Date
    let completedAt: Date
    let committedAt: Date
    let legacyDataRetention: String
    let applicationMappings: [LibraryMigrationApplicationMapping]
    let mappings: [LibraryMigrationPathMapping]

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case migrationID
        case sourceFormat
        case sourceSHA256
        case sourceByteCount
        case targetSHA256
        case backupRelativePath
        case startedAt
        case completedAt
        case committedAt
        case legacyDataRetention
        case applicationMappings
        case mappings
    }

    init(
        schemaVersion: Int,
        migrationID: UUID,
        sourceFormat: String,
        sourceSHA256: String,
        sourceByteCount: Int,
        targetSHA256: String,
        backupRelativePath: String,
        startedAt: Date,
        completedAt: Date,
        committedAt: Date,
        legacyDataRetention: String,
        applicationMappings: [LibraryMigrationApplicationMapping],
        mappings: [LibraryMigrationPathMapping]
    ) {
        self.schemaVersion = schemaVersion
        self.migrationID = migrationID
        self.sourceFormat = sourceFormat
        self.sourceSHA256 = sourceSHA256
        self.sourceByteCount = sourceByteCount
        self.targetSHA256 = targetSHA256
        self.backupRelativePath = backupRelativePath
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.committedAt = committedAt
        self.legacyDataRetention = legacyDataRetention
        self.applicationMappings = applicationMappings
        self.mappings = mappings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let migrationString = try container.decode(String.self, forKey: .migrationID)
        guard let migrationID = UUID(uuidString: migrationString) else {
            throw LibraryMigrationError.invalidJournal
        }
        self.migrationID = migrationID
        sourceFormat = try container.decode(String.self, forKey: .sourceFormat)
        sourceSHA256 = try container.decode(String.self, forKey: .sourceSHA256)
        sourceByteCount = try container.decode(Int.self, forKey: .sourceByteCount)
        targetSHA256 = try container.decode(String.self, forKey: .targetSHA256)
        backupRelativePath = try container.decode(
            String.self,
            forKey: .backupRelativePath
        )
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        completedAt = try container.decode(Date.self, forKey: .completedAt)
        committedAt = try container.decode(Date.self, forKey: .committedAt)
        legacyDataRetention = try container.decode(
            String.self,
            forKey: .legacyDataRetention
        )
        applicationMappings = try container.decode(
            [LibraryMigrationApplicationMapping].self,
            forKey: .applicationMappings
        )
        mappings = try container.decode(
            [LibraryMigrationPathMapping].self,
            forKey: .mappings
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(
            migrationID.uuidString.lowercased(),
            forKey: .migrationID
        )
        try container.encode(sourceFormat, forKey: .sourceFormat)
        try container.encode(sourceSHA256, forKey: .sourceSHA256)
        try container.encode(sourceByteCount, forKey: .sourceByteCount)
        try container.encode(targetSHA256, forKey: .targetSHA256)
        try container.encode(backupRelativePath, forKey: .backupRelativePath)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(completedAt, forKey: .completedAt)
        try container.encode(committedAt, forKey: .committedAt)
        try container.encode(legacyDataRetention, forKey: .legacyDataRetention)
        try container.encode(applicationMappings, forKey: .applicationMappings)
        try container.encode(mappings, forKey: .mappings)
    }
}

struct LibraryMigrationApplicationMapping: Hashable, Sendable, Codable {
    let applicationOccurrence: Int
    let oldApplicationID: UUID
    let newApplicationID: UUID
    let applicationStorageID: UUID

    enum CodingKeys: String, CodingKey {
        case applicationOccurrence
        case oldApplicationID
        case newApplicationID
        case applicationStorageID
    }

    init(
        applicationOccurrence: Int,
        oldApplicationID: UUID,
        newApplicationID: UUID,
        applicationStorageID: UUID
    ) {
        self.applicationOccurrence = applicationOccurrence
        self.oldApplicationID = oldApplicationID
        self.newApplicationID = newApplicationID
        self.applicationStorageID = applicationStorageID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        applicationOccurrence = try container.decode(
            Int.self,
            forKey: .applicationOccurrence
        )
        oldApplicationID = try Self.uuid(
            try container.decode(String.self, forKey: .oldApplicationID)
        )
        newApplicationID = try Self.uuid(
            try container.decode(String.self, forKey: .newApplicationID)
        )
        applicationStorageID = try Self.uuid(
            try container.decode(String.self, forKey: .applicationStorageID)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(applicationOccurrence, forKey: .applicationOccurrence)
        try container.encode(
            oldApplicationID.uuidString.lowercased(),
            forKey: .oldApplicationID
        )
        try container.encode(
            newApplicationID.uuidString.lowercased(),
            forKey: .newApplicationID
        )
        try container.encode(
            applicationStorageID.uuidString.lowercased(),
            forKey: .applicationStorageID
        )
    }

    static func uuid(_ value: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw LibraryMigrationError.invalidJournal
        }
        return uuid
    }
}

struct LibraryMigrationPathMapping: Hashable, Sendable, Codable {
    enum Disposition: String, Hashable, Sendable, Codable {
        case retainedInPlace
        case missing
    }

    enum IsolationConfiguration: String, Hashable, Sendable, Codable {
        case generated
        case external
        case none
        case requiresReview
    }

    let applicationOccurrence: Int
    let profileOccurrence: Int
    let oldApplicationID: UUID
    let newApplicationID: UUID
    let applicationStorageID: UUID
    let oldProfileID: UUID
    let newProfileID: UUID
    let profileStorageID: UUID
    let oldCanonicalPath: String
    let newCanonicalPath: String
    let disposition: Disposition
    let isolationConfiguration: IsolationConfiguration
    let sourceManifestSHA256: String?

    enum CodingKeys: String, CodingKey {
        case applicationOccurrence
        case profileOccurrence
        case oldApplicationID
        case newApplicationID
        case applicationStorageID
        case oldProfileID
        case newProfileID
        case profileStorageID
        case oldCanonicalPath
        case newCanonicalPath
        case disposition
        case isolationConfiguration
        case sourceManifestSHA256
    }

    init(
        applicationOccurrence: Int,
        profileOccurrence: Int,
        oldApplicationID: UUID,
        newApplicationID: UUID,
        applicationStorageID: UUID,
        oldProfileID: UUID,
        newProfileID: UUID,
        profileStorageID: UUID,
        oldCanonicalPath: String,
        newCanonicalPath: String,
        disposition: Disposition,
        isolationConfiguration: IsolationConfiguration,
        sourceManifestSHA256: String?
    ) {
        self.applicationOccurrence = applicationOccurrence
        self.profileOccurrence = profileOccurrence
        self.oldApplicationID = oldApplicationID
        self.newApplicationID = newApplicationID
        self.applicationStorageID = applicationStorageID
        self.oldProfileID = oldProfileID
        self.newProfileID = newProfileID
        self.profileStorageID = profileStorageID
        self.oldCanonicalPath = oldCanonicalPath
        self.newCanonicalPath = newCanonicalPath
        self.disposition = disposition
        self.isolationConfiguration = isolationConfiguration
        self.sourceManifestSHA256 = sourceManifestSHA256
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        applicationOccurrence = try container.decode(
            Int.self,
            forKey: .applicationOccurrence
        )
        profileOccurrence = try container.decode(Int.self, forKey: .profileOccurrence)
        oldApplicationID = try Self.decodeUUID(
            from: container,
            key: .oldApplicationID
        )
        newApplicationID = try Self.decodeUUID(
            from: container,
            key: .newApplicationID
        )
        applicationStorageID = try Self.decodeUUID(
            from: container,
            key: .applicationStorageID
        )
        oldProfileID = try Self.decodeUUID(from: container, key: .oldProfileID)
        newProfileID = try Self.decodeUUID(from: container, key: .newProfileID)
        profileStorageID = try Self.decodeUUID(
            from: container,
            key: .profileStorageID
        )
        oldCanonicalPath = try container.decode(String.self, forKey: .oldCanonicalPath)
        newCanonicalPath = try container.decode(String.self, forKey: .newCanonicalPath)
        disposition = try container.decode(Disposition.self, forKey: .disposition)
        isolationConfiguration = try container.decode(
            IsolationConfiguration.self,
            forKey: .isolationConfiguration
        )
        sourceManifestSHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .sourceManifestSHA256
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(applicationOccurrence, forKey: .applicationOccurrence)
        try container.encode(profileOccurrence, forKey: .profileOccurrence)
        try Self.encode(oldApplicationID, to: &container, key: .oldApplicationID)
        try Self.encode(newApplicationID, to: &container, key: .newApplicationID)
        try Self.encode(applicationStorageID, to: &container, key: .applicationStorageID)
        try Self.encode(oldProfileID, to: &container, key: .oldProfileID)
        try Self.encode(newProfileID, to: &container, key: .newProfileID)
        try Self.encode(profileStorageID, to: &container, key: .profileStorageID)
        try container.encode(oldCanonicalPath, forKey: .oldCanonicalPath)
        try container.encode(newCanonicalPath, forKey: .newCanonicalPath)
        try container.encode(disposition, forKey: .disposition)
        try container.encode(isolationConfiguration, forKey: .isolationConfiguration)
        try container.encodeIfPresent(
            sourceManifestSHA256,
            forKey: .sourceManifestSHA256
        )
    }

    static func decodeUUID(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> UUID {
        let value = try container.decode(String.self, forKey: key)
        guard let uuid = UUID(uuidString: value) else {
            throw LibraryMigrationError.invalidJournal
        }
        return uuid
    }

    static func encode(
        _ uuid: UUID,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws {
        try container.encode(uuid.uuidString.lowercased(), forKey: key)
    }
}

enum LibraryMigrationOutcome: Hashable, Sendable {
    case current([ManagedApplication])
    case migrated([ManagedApplication], LibraryMigrationReceipt)
    case requiresResolution(LibraryMigrationPlan)
}
