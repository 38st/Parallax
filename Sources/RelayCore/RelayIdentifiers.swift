import Foundation

public enum RelayTaskIDTag: Sendable {}
public enum RelayStageIDTag: Sendable {}
public enum RelayAttemptIDTag: Sendable {}
public enum RelayBatonIDTag: Sendable {}
public enum RelayFindingIDTag: Sendable {}
public enum RelayEvidenceIDTag: Sendable {}
public enum RelayDecisionIDTag: Sendable {}
public enum RelayArtifactIDTag: Sendable {}
public enum RelayWorkspaceProvisioningIntentIDTag: Sendable {}
public enum RelayAcceptanceCriterionIDTag: Sendable {}

public typealias RelayTaskID = RelayID<RelayTaskIDTag>
public typealias RelayStageID = RelayID<RelayStageIDTag>
public typealias RelayAttemptID = RelayID<RelayAttemptIDTag>
public typealias RelayBatonID = RelayID<RelayBatonIDTag>
public typealias RelayFindingID = RelayID<RelayFindingIDTag>
public typealias RelayEvidenceID = RelayID<RelayEvidenceIDTag>
public typealias RelayDecisionID = RelayID<RelayDecisionIDTag>
public typealias RelayArtifactID = RelayID<RelayArtifactIDTag>
public typealias RelayWorkspaceProvisioningIntentID =
    RelayID<RelayWorkspaceProvisioningIntentIDTag>
public typealias RelayAcceptanceCriterionID = RelayID<RelayAcceptanceCriterionIDTag>

public struct RelayID<Tag: Sendable>: Hashable, Comparable, Codable, Sendable,
    CustomStringConvertible
{
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public init?(uuidString: String) {
        guard let value = UUID(uuidString: uuidString) else { return nil }
        rawValue = value
    }

    public var description: String {
        rawValue.uuidString.lowercased()
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.description < rhs.description
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let value = UUID(uuidString: encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a UUID string."
            )
        }
        rawValue = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

public struct RelayInstant: RawRepresentable, Hashable, Comparable, Codable,
    Sendable
{
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public init(date: Date) {
        rawValue = Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct RelayDigest: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init?(rawValue: String) {
        let normalized = rawValue.lowercased()
        guard normalized.count == 64,
              normalized.utf8.allSatisfy(Self.isLowercaseHex)
        else { return nil }
        self.rawValue = normalized
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let value = Self(rawValue: encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a lowercase SHA-256 digest."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}

public struct RelayGitOID: RawRepresentable, Hashable, Codable, Sendable,
    CustomStringConvertible
{
    public let rawValue: String

    public init?(rawValue: String) {
        let normalized = rawValue.lowercased()
        guard [40, 64].contains(normalized.count),
              normalized.utf8.allSatisfy(Self.isLowercaseHex)
        else { return nil }
        self.rawValue = normalized
    }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let encoded = try container.decode(String.self)
        guard let value = Self(rawValue: encoded) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a full Git object ID."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (97...102).contains(byte)
    }
}

public struct RelayJournalHead: Hashable, Codable, Sendable {
    public let sequence: UInt64
    public let digest: RelayDigest

    public init(sequence: UInt64, digest: RelayDigest) {
        self.sequence = sequence
        self.digest = digest
    }
}
