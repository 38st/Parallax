import Foundation

struct LibraryRevision: RawRepresentable, Codable, Hashable, Sendable, Comparable {
    static let initial = LibraryRevision(rawValue: 0)

    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(UInt64.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static func < (lhs: LibraryRevision, rhs: LibraryRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct LibraryDocument: Codable, Hashable, Sendable {
    static let currentVersion = 2

    let version: Int
    let revision: LibraryRevision
    var applications: [ManagedApplication]

    init(
        revision: LibraryRevision = .initial,
        applications: [ManagedApplication]
    ) {
        version = Self.currentVersion
        self.revision = revision
        self.applications = applications
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case revision
        case applications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        revision = try container.decodeIfPresent(
            LibraryRevision.self,
            forKey: .revision
        ) ?? .initial
        applications = try container.decode(
            [ManagedApplication].self,
            forKey: .applications
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(revision, forKey: .revision)
        try container.encode(applications, forKey: .applications)
    }
}
