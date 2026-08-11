import Foundation

/// A JSON object key whose identity is based on its exact Unicode-scalar
/// spelling. Swift `String` equality intentionally treats canonically
/// equivalent spellings as equal, which is not strict enough for duplicate-key
/// detection in persisted settings documents.
struct StrictJSONExactKey: Hashable {
    let value: String
    private let scalars: [UInt32]

    init(_ value: String) {
        self.value = value
        scalars = value.unicodeScalars.map(\.value)
    }

    static func == (
        lhs: StrictJSONExactKey,
        rhs: StrictJSONExactKey
    ) -> Bool {
        lhs.scalars == rhs.scalars
    }

    func hash(into hasher: inout Hasher) {
        for scalar in scalars {
            hasher.combine(scalar)
        }
    }
}

enum StrictJSONLexicalIssue: Error, Equatable {
    case malformedJSON
    case stringTooLong
    case numericTokenTooLong
}

enum StrictJSONRawStringValidationOrder {
    /// Validate each scalar before accounting for its decoded byte length.
    /// This preserves the preflight scanner's hostile-input precedence.
    case scalarBeforeLength

    /// Account for a raw segment's byte length before validating its UTF-8.
    /// This preserves the materializing codec parser's historical precedence.
    case lengthBeforeScalarValidation
}

/// Shared byte-level JSON lexical machinery. Structural traversal, path
/// construction, limits, token accounting, and value materialization stay in
/// the callers because they have deliberately different responsibilities.
struct StrictJSONByteCursor {
    let bytes: [UInt8]
    private(set) var index = 0

    init(data: Data) {
        bytes = Array(data)
    }

    var currentByte: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    var isAtEnd: Bool {
        index == bytes.count
    }

    mutating func advance() {
        index += 1
    }

    func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < bytes.count else {
            return nil
        }
        return bytes[offset]
    }

    mutating func skipWhitespace() {
        while let byte = currentByte,
              byte == 0x20
                || byte == 0x09
                || byte == 0x0A
                || byte == 0x0D
        {
            index += 1
        }
    }

    mutating func consume(_ byte: UInt8) -> Bool {
        guard currentByte == byte else {
            return false
        }
        index += 1
        return true
    }

    mutating func consumeLiteral(_ literal: StaticString) throws {
        let expected = Array(String(describing: literal).utf8)
        guard index + expected.count <= bytes.count,
              bytes[index ..< (index + expected.count)]
                .elementsEqual(expected)
        else {
            throw StrictJSONLexicalIssue.malformedJSON
        }
        index += expected.count
    }

    mutating func scanNumber(
        maximumBytes: Int,
        materialize: Bool
    ) throws -> String? {
        let start = index
        _ = consume(0x2D)
        guard currentByte != nil else {
            throw StrictJSONLexicalIssue.malformedJSON
        }
        if consume(0x30) {
            guard currentByte.map({ !(0x30 ... 0x39).contains($0) })
                    ?? true
            else {
                throw StrictJSONLexicalIssue.malformedJSON
            }
        } else {
            guard let byte = currentByte,
                  (0x31 ... 0x39).contains(byte)
            else {
                throw StrictJSONLexicalIssue.malformedJSON
            }
            while let byte = currentByte,
                  (0x30 ... 0x39).contains(byte)
            {
                index += 1
            }
        }
        if consume(0x2E) {
            try consumeDigits()
        }
        if let byte = currentByte, byte == 0x65 || byte == 0x45 {
            index += 1
            if let sign = currentByte, sign == 0x2B || sign == 0x2D {
                index += 1
            }
            try consumeDigits()
        }
        guard index - start <= maximumBytes else {
            throw StrictJSONLexicalIssue.numericTokenTooLong
        }
        guard materialize else {
            return nil
        }
        guard let raw = String(
            bytes: bytes[start ..< index],
            encoding: .utf8
        ) else {
            throw StrictJSONLexicalIssue.malformedJSON
        }
        return raw
    }

    mutating func scanString(
        maximumUTF8Bytes: Int,
        materialize: Bool,
        validationOrder: StrictJSONRawStringValidationOrder
    ) throws -> String? {
        switch validationOrder {
        case .scalarBeforeLength:
            return try scanStringByScalar(
                maximumUTF8Bytes: maximumUTF8Bytes,
                materialize: materialize
            )
        case .lengthBeforeScalarValidation:
            return try scanStringBySegment(
                maximumUTF8Bytes: maximumUTF8Bytes,
                materialize: materialize
            )
        }
    }

    private mutating func scanStringByScalar(
        maximumUTF8Bytes: Int,
        materialize: Bool
    ) throws -> String? {
        guard consume(0x22) else {
            throw StrictJSONLexicalIssue.malformedJSON
        }
        var result = materialize ? "" : nil
        var observedUTF8Bytes = 0
        while let byte = currentByte {
            if byte == 0x22 {
                guard maximumUTF8Bytes >= 0 else {
                    throw StrictJSONLexicalIssue.stringTooLong
                }
                index += 1
                return result
            }
            let scalar: UInt32
            let byteCount: Int
            if byte == 0x5C {
                index += 1
                (scalar, byteCount) = try scanEscape()
            } else if byte < 0x20 {
                throw StrictJSONLexicalIssue.malformedJSON
            } else if byte < 0x80 {
                scalar = UInt32(byte)
                byteCount = 1
                index += 1
            } else {
                (scalar, byteCount) = try scanRawUTF8Scalar()
            }
            try addDecodedUTF8Bytes(
                byteCount,
                to: &observedUTF8Bytes,
                maximum: maximumUTF8Bytes
            )
            if materialize {
                guard let unicode = Unicode.Scalar(scalar) else {
                    throw StrictJSONLexicalIssue.malformedJSON
                }
                result?.unicodeScalars.append(unicode)
            }
        }
        throw StrictJSONLexicalIssue.malformedJSON
    }

    private mutating func scanStringBySegment(
        maximumUTF8Bytes: Int,
        materialize: Bool
    ) throws -> String? {
        guard consume(0x22) else {
            throw StrictJSONLexicalIssue.malformedJSON
        }
        var result = materialize ? "" : nil
        var decodedUTF8Bytes = 0
        var segmentStart = index
        while let byte = currentByte {
            if byte == 0x22 || byte == 0x5C {
                let range = segmentStart ..< index
                try addDecodedUTF8Bytes(
                    range.count,
                    to: &decodedUTF8Bytes,
                    maximum: maximumUTF8Bytes
                )
                guard let segment = String(
                    bytes: bytes[range],
                    encoding: .utf8
                ) else {
                    throw StrictJSONLexicalIssue.malformedJSON
                }
                if materialize {
                    result?.append(segment)
                }
                if byte == 0x22 {
                    index += 1
                    return result
                }
                index += 1
                guard currentByte != nil else {
                    throw StrictJSONLexicalIssue.malformedJSON
                }
                let (scalar, byteCount) = try scanEscape()
                try addDecodedUTF8Bytes(
                    byteCount,
                    to: &decodedUTF8Bytes,
                    maximum: maximumUTF8Bytes
                )
                if materialize {
                    guard let unicode = Unicode.Scalar(scalar) else {
                        throw StrictJSONLexicalIssue.malformedJSON
                    }
                    result?.unicodeScalars.append(unicode)
                }
                segmentStart = index
            } else {
                guard byte >= 0x20 else {
                    throw StrictJSONLexicalIssue.malformedJSON
                }
                index += 1
            }
        }
        throw StrictJSONLexicalIssue.malformedJSON
    }

    private mutating func scanEscape() throws -> (
        scalar: UInt32,
        byteCount: Int
    ) {
        guard let escapedByte = currentByte else {
            throw StrictJSONLexicalIssue.malformedJSON
        }
        index += 1
        let scalar: UInt32
        switch escapedByte {
        case 0x22, 0x5C, 0x2F:
            scalar = UInt32(escapedByte)
        case 0x62:
            scalar = 0x08
        case 0x66:
            scalar = 0x0C
        case 0x6E:
            scalar = 0x0A
        case 0x72:
            scalar = 0x0D
        case 0x74:
            scalar = 0x09
        case 0x75:
            let first = try unicodeEscape()
            if (0xD800 ... 0xDBFF).contains(first) {
                guard byte(at: index) == 0x5C,
                      byte(at: index + 1) == 0x75
                else {
                    throw StrictJSONLexicalIssue.malformedJSON
                }
                index += 2
                let second = try unicodeEscape()
                guard (0xDC00 ... 0xDFFF).contains(second) else {
                    throw StrictJSONLexicalIssue.malformedJSON
                }
                scalar = 0x10000
                    + ((first - 0xD800) << 10)
                    + (second - 0xDC00)
            } else {
                guard !(0xDC00 ... 0xDFFF).contains(first) else {
                    throw StrictJSONLexicalIssue.malformedJSON
                }
                scalar = first
            }
        default:
            throw StrictJSONLexicalIssue.malformedJSON
        }
        guard let unicode = Unicode.Scalar(scalar) else {
            throw StrictJSONLexicalIssue.malformedJSON
        }
        return (scalar, unicode.utf8.count)
    }

    private mutating func scanRawUTF8Scalar() throws -> (
        scalar: UInt32,
        byteCount: Int
    ) {
        guard let first = currentByte else {
            throw StrictJSONLexicalIssue.malformedJSON
        }
        let length: Int
        let minimumSecond: UInt8
        let maximumSecond: UInt8
        switch first {
        case 0xC2 ... 0xDF:
            length = 2
            minimumSecond = 0x80
            maximumSecond = 0xBF
        case 0xE0:
            length = 3
            minimumSecond = 0xA0
            maximumSecond = 0xBF
        case 0xE1 ... 0xEC, 0xEE ... 0xEF:
            length = 3
            minimumSecond = 0x80
            maximumSecond = 0xBF
        case 0xED:
            length = 3
            minimumSecond = 0x80
            maximumSecond = 0x9F
        case 0xF0:
            length = 4
            minimumSecond = 0x90
            maximumSecond = 0xBF
        case 0xF1 ... 0xF3:
            length = 4
            minimumSecond = 0x80
            maximumSecond = 0xBF
        case 0xF4:
            length = 4
            minimumSecond = 0x80
            maximumSecond = 0x8F
        default:
            throw StrictJSONLexicalIssue.malformedJSON
        }
        guard let second = byte(at: index + 1),
              (minimumSecond ... maximumSecond).contains(second)
        else {
            throw StrictJSONLexicalIssue.malformedJSON
        }
        for offset in 2 ..< length {
            guard let continuation = byte(at: index + offset),
                  (0x80 ... 0xBF).contains(continuation)
            else {
                throw StrictJSONLexicalIssue.malformedJSON
            }
        }
        var scalar = UInt32(first & (0x7F >> length))
        for offset in 1 ..< length {
            scalar = (scalar << 6)
                | UInt32(bytes[index + offset] & 0x3F)
        }
        index += length
        guard Unicode.Scalar(scalar) != nil else {
            throw StrictJSONLexicalIssue.malformedJSON
        }
        return (scalar, length)
    }

    private mutating func unicodeEscape() throws -> UInt32 {
        guard index + 4 <= bytes.count else {
            throw StrictJSONLexicalIssue.malformedJSON
        }
        var value: UInt32 = 0
        for _ in 0 ..< 4 {
            guard let nibble = hex(bytes[index]) else {
                throw StrictJSONLexicalIssue.malformedJSON
            }
            value = (value << 4) | nibble
            index += 1
        }
        return value
    }

    private mutating func consumeDigits() throws {
        let start = index
        while let byte = currentByte,
              (0x30 ... 0x39).contains(byte)
        {
            index += 1
        }
        guard index > start else {
            throw StrictJSONLexicalIssue.malformedJSON
        }
    }

    private func addDecodedUTF8Bytes(
        _ addition: Int,
        to count: inout Int,
        maximum: Int
    ) throws {
        let (next, overflow) = count.addingReportingOverflow(addition)
        guard !overflow, next <= maximum else {
            throw StrictJSONLexicalIssue.stringTooLong
        }
        count = next
    }

    private func hex(_ byte: UInt8) -> UInt32? {
        switch byte {
        case 0x30 ... 0x39: UInt32(byte - 0x30)
        case 0x41 ... 0x46: UInt32(byte - 0x41 + 10)
        case 0x61 ... 0x66: UInt32(byte - 0x61 + 10)
        default: nil
        }
    }
}
