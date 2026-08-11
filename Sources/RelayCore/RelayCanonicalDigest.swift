import CryptoKit
import Foundation

public enum RelayCanonicalEncoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func digest<T: Encodable>(_ value: T) throws -> RelayDigest {
        let bytes = try encode(value)
        let value = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        guard let digest = RelayDigest(rawValue: value) else {
            preconditionFailure("CryptoKit returned a malformed SHA-256 digest.")
        }
        return digest
    }
}

public extension RelayID where Tag == RelayAcceptanceCriterionIDTag {
    /// A stable identifier for compatibility callers that provide criterion
    /// statements rather than explicit IDs. New callers should persist their
    /// own explicit IDs, but repeated construction of the same immutable task
    /// definition must not silently produce different criterion identities.
    static func derived(
        taskID: RelayTaskID,
        index: Int,
        statement: String
    ) -> RelayAcceptanceCriterionID {
        var seed = Data("relay-acceptance-criterion-v1".utf8)
        for component in [taskID.description, String(index), statement] {
            var count = UInt64(component.utf8.count).bigEndian
            withUnsafeBytes(of: &count) { seed.append(contentsOf: $0) }
            seed.append(contentsOf: component.utf8)
        }
        var bytes = Array(SHA256.hash(data: seed).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return RelayAcceptanceCriterionID(uuid)
    }
}
