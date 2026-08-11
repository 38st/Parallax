import CryptoKit
import Foundation

/// Builds a domain-separated SHA-256 digest from labeled, length-prefixed UTF-8
/// fields. Labels and values are encoded independently so neither delimiters in
/// user-controlled values nor adjacent variable-length sequences are ambiguous.
struct LengthPrefixedSHA256FingerprintBuilder {
    private static let formatIdentifier =
        "com.parallax.length-prefixed-sha256"

    private var canonical = Data()

    init(domain: String, version: UInt64) {
        appendRecord(label: "format", value: Self.formatIdentifier)
        appendRecord(label: "domain", value: domain)
        appendRecord(label: "version", value: String(version))
    }

    mutating func append(_ value: String, for field: String) {
        appendRecord(label: field, value: value)
    }

    func finalizeHexDigest() -> String {
        SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private mutating func appendRecord(label: String, value: String) {
        appendLengthPrefixed(Data(label.utf8))
        appendLengthPrefixed(Data(value.utf8))
    }

    private mutating func appendLengthPrefixed(_ bytes: Data) {
        canonical.append(
            contentsOf: withUnsafeBytes(
                of: UInt64(bytes.count).bigEndian,
                Array.init
            )
        )
        canonical.append(bytes)
    }
}
