import Foundation

enum StrictJSONRootRequirement: Equatable, Sendable {
    case any
    case object
    case array
}

enum StrictJSONRootKind: Equatable, Sendable {
    case object
    case array
    case scalar
}

enum StrictJSONProbeState: Equatable, Sendable {
    case notRequested
    case missing
    case numberToken(String)
    case other
}

struct StrictJSONPreflightEvidence: Equatable, Sendable {
    let root: StrictJSONRootKind
    let probe: StrictJSONProbeState
}

enum StrictJSONPreflightIssue: Error, Equatable, Sendable {
    case inputTooLarge(actual: Int, maximum: Int)
    case probeKeyTooLong(actual: Int, maximum: Int)
    case malformedJSON
    case excessiveNesting(maximum: Int)
    case tooManyTokens(maximum: Int)
    case duplicateKey(path: String, key: String)
    case invalidRoot(
        required: StrictJSONRootRequirement,
        actual: StrictJSONRootKind
    )
    case numericTokenTooLong(path: String, maximum: Int)
    case stringTooLong(path: String, maximum: Int)
    case tooManyItems(path: String, maximum: Int)
}

struct StrictJSONPreflight: Sendable {
    // Bounds recursive stack and path growth independently of caller input.
    static let implementationMaximumNestingDepth = 256
    static let implementationMaximumProbeKeyUTF8Bytes = 256

    struct Limits: Equatable, Sendable {
        let maximumBytes: Int
        let maximumArrayItems: Int
        let maximumObjectMembers: Int
        let maximumKeyUTF8Bytes: Int
        let maximumStringUTF8Bytes: Int
        let maximumNumberBytes: Int
        let maximumNestingDepth: Int
        let maximumTokenCount: Int
    }

    struct TopLevelProbe: Equatable, Sendable {
        let key: String
    }

    let limits: Limits
    let rootRequirement: StrictJSONRootRequirement
    let topLevelProbe: TopLevelProbe?

    func scan(
        _ data: Data
    ) -> Result<StrictJSONPreflightEvidence, StrictJSONPreflightIssue> {
        guard data.count <= limits.maximumBytes else {
            return .failure(
                .inputTooLarge(
                    actual: data.count,
                    maximum: limits.maximumBytes
                )
            )
        }
        if let probe = topLevelProbe {
            let probeBytes = probe.key.utf8.count
            guard probeBytes <= Self.implementationMaximumProbeKeyUTF8Bytes
            else {
                return .failure(
                    .probeKeyTooLong(
                        actual: probeBytes,
                        maximum:
                            Self.implementationMaximumProbeKeyUTF8Bytes
                    )
                )
            }
        }
        do {
            var engine = StrictJSONPreflightEngine(
                data: data,
                limits: limits,
                probe: topLevelProbe
            )
            let evidence = try engine.scan()
            switch rootRequirement {
            case .any:
                break
            case .object where evidence.root != .object:
                return .failure(
                    .invalidRoot(
                        required: .object,
                        actual: evidence.root
                    )
                )
            case .array where evidence.root != .array:
                return .failure(
                    .invalidRoot(
                        required: .array,
                        actual: evidence.root
                    )
                )
            case .object, .array:
                break
            }
            return .success(evidence)
        } catch let issue as StrictJSONPreflightIssue {
            return .failure(issue)
        } catch {
            return .failure(.malformedJSON)
        }
    }
}

private struct StrictJSONPreflightKey: Hashable {
    let value: String
    private let scalars: [UInt32]

    init(_ value: String) {
        self.value = value
        scalars = value.unicodeScalars.map(\.value)
    }

    static func == (
        lhs: StrictJSONPreflightKey,
        rhs: StrictJSONPreflightKey
    ) -> Bool {
        lhs.scalars == rhs.scalars
    }

    func hash(into hasher: inout Hasher) {
        for scalar in scalars {
            hasher.combine(scalar)
        }
    }
}

private struct StrictJSONPreflightEngine {
    private enum ProbeCandidate {
        case number(String)
        case other
    }

    private let bytes: [UInt8]
    private let limits: StrictJSONPreflight.Limits
    private let probe: StrictJSONPreflight.TopLevelProbe?
    private var index = 0
    private var tokenCount = 0
    private var probeCandidate: ProbeCandidate?

    init(
        data: Data,
        limits: StrictJSONPreflight.Limits,
        probe: StrictJSONPreflight.TopLevelProbe?
    ) {
        bytes = Array(data)
        self.limits = limits
        self.probe = probe
    }

    mutating func scan() throws -> StrictJSONPreflightEvidence {
        skipWhitespace()
        guard index < bytes.count else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        let root = try scanValue(
            path: "$",
            depth: 0,
            isTopLevel: true
        )
        skipWhitespace()
        guard index == bytes.count else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        let state: StrictJSONProbeState
        if probe == nil {
            state = .notRequested
        } else {
            switch probeCandidate {
            case .none:
                state = .missing
            case .number(let raw):
                state = .numberToken(raw)
            case .other:
                state = .other
            }
        }
        return .init(root: root, probe: state)
    }

    private mutating func scanValue(
        path: String,
        depth: Int,
        isTopLevel: Bool = false
    ) throws -> StrictJSONRootKind {
        try consumeToken()
        return try scanValueBody(
            path: path,
            depth: depth,
            isTopLevel: isTopLevel
        )
    }

    private mutating func scanValueBody(
        path: String,
        depth: Int,
        isTopLevel: Bool = false
    ) throws -> StrictJSONRootKind {
        guard index < bytes.count else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        switch bytes[index] {
        case 0x7B:
            try scanObject(
                path: path,
                depth: depth,
                isTopLevel: isTopLevel
            )
            return .object
        case 0x5B:
            try scanArray(path: path, depth: depth)
            return .array
        case 0x22:
            _ = try scanString(
                maximumUTF8Bytes: limits.maximumStringUTF8Bytes,
                path: path,
                materialize: false
            )
        case 0x74:
            try consumeLiteral("true")
        case 0x66:
            try consumeLiteral("false")
        case 0x6E:
            try consumeLiteral("null")
        case 0x2D, 0x30 ... 0x39:
            _ = try scanNumber(
                maximumBytes: limits.maximumNumberBytes,
                path: path,
                materialize: false
            )
        default:
            throw StrictJSONPreflightIssue.malformedJSON
        }
        return .scalar
    }

    private mutating func scanObject(
        path: String,
        depth: Int,
        isTopLevel: Bool
    ) throws {
        try enter(depth)
        guard consume(0x7B) else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        guard limits.maximumObjectMembers >= 0 else {
            throw StrictJSONPreflightIssue.tooManyItems(
                path: path,
                maximum: limits.maximumObjectMembers
            )
        }
        skipWhitespace()
        var keys = Set<StrictJSONPreflightKey>()
        if consume(0x7D) {
            return
        }
        while true {
            guard keys.count < limits.maximumObjectMembers else {
                throw StrictJSONPreflightIssue.tooManyItems(
                    path: path,
                    maximum: limits.maximumObjectMembers
                )
            }
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw StrictJSONPreflightIssue.malformedJSON
            }
            try consumeToken()
            let key = StrictJSONPreflightKey(
                try scanString(
                    maximumUTF8Bytes: limits.maximumKeyUTF8Bytes,
                    path: "\(path).<key>",
                    materialize: true
                ) ?? ""
            )
            guard keys.insert(key).inserted else {
                throw StrictJSONPreflightIssue.duplicateKey(
                    path: path,
                    key: key.value
                )
            }
            skipWhitespace()
            guard consume(0x3A) else {
                throw StrictJSONPreflightIssue.malformedJSON
            }
            skipWhitespace()
            if isTopLevel,
               let probe,
               key == StrictJSONPreflightKey(probe.key)
            {
                probeCandidate = try scanProbeCandidate(
                    path: "$.\(probe.key)",
                    depth: depth + 1
                )
            } else {
                _ = try scanValue(
                    path: "\(path).\(key.value)",
                    depth: depth + 1
                )
            }
            skipWhitespace()
            if consume(0x7D) {
                return
            }
            guard consume(0x2C) else {
                throw StrictJSONPreflightIssue.malformedJSON
            }
            skipWhitespace()
        }
    }

    private mutating func scanProbeCandidate(
        path: String,
        depth: Int
    ) throws -> ProbeCandidate {
        try consumeToken()
        guard index < bytes.count else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        if bytes[index] == 0x2D
            || (0x30 ... 0x39).contains(bytes[index])
        {
            return .number(
                try scanNumber(
                    maximumBytes: limits.maximumNumberBytes,
                    path: path,
                    materialize: true
                ) ?? ""
            )
        }
        _ = try scanValueBody(path: path, depth: depth)
        return .other
    }

    private mutating func scanArray(
        path: String,
        depth: Int
    ) throws {
        try enter(depth)
        guard consume(0x5B) else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        guard limits.maximumArrayItems >= 0 else {
            throw StrictJSONPreflightIssue.tooManyItems(
                path: path,
                maximum: limits.maximumArrayItems
            )
        }
        skipWhitespace()
        var count = 0
        if consume(0x5D) {
            return
        }
        while true {
            guard count < limits.maximumArrayItems else {
                throw StrictJSONPreflightIssue.tooManyItems(
                    path: path,
                    maximum: limits.maximumArrayItems
                )
            }
            _ = try scanValue(
                path: "\(path)[\(count)]",
                depth: depth + 1
            )
            count += 1
            skipWhitespace()
            if consume(0x5D) {
                return
            }
            guard consume(0x2C) else {
                throw StrictJSONPreflightIssue.malformedJSON
            }
            skipWhitespace()
        }
    }

    private mutating func scanString(
        maximumUTF8Bytes: Int,
        path: String,
        materialize: Bool
    ) throws -> String? {
        guard consume(0x22) else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        var result = materialize ? "" : nil
        var observedUTF8Bytes = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 {
                guard maximumUTF8Bytes >= 0 else {
                    throw StrictJSONPreflightIssue.stringTooLong(
                        path: path,
                        maximum: maximumUTF8Bytes
                    )
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
                throw StrictJSONPreflightIssue.malformedJSON
            } else if byte < 0x80 {
                scalar = UInt32(byte)
                byteCount = 1
                index += 1
            } else {
                (scalar, byteCount) = try scanRawUTF8Scalar()
            }
            let (next, overflow) =
                observedUTF8Bytes.addingReportingOverflow(byteCount)
            guard !overflow, next <= maximumUTF8Bytes else {
                throw StrictJSONPreflightIssue.stringTooLong(
                    path: path,
                    maximum: maximumUTF8Bytes
                )
            }
            observedUTF8Bytes = next
            if materialize {
                guard let unicode = Unicode.Scalar(scalar) else {
                    throw StrictJSONPreflightIssue.malformedJSON
                }
                result?.unicodeScalars.append(unicode)
            }
        }
        throw StrictJSONPreflightIssue.malformedJSON
    }

    private mutating func scanEscape() throws -> (
        scalar: UInt32,
        byteCount: Int
    ) {
        guard index < bytes.count else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        let byte = bytes[index]
        index += 1
        let scalar: UInt32
        switch byte {
        case 0x22, 0x5C, 0x2F:
            scalar = UInt32(byte)
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
                guard index + 2 <= bytes.count,
                      bytes[index] == 0x5C,
                      bytes[index + 1] == 0x75
                else {
                    throw StrictJSONPreflightIssue.malformedJSON
                }
                index += 2
                let second = try unicodeEscape()
                guard (0xDC00 ... 0xDFFF).contains(second) else {
                    throw StrictJSONPreflightIssue.malformedJSON
                }
                scalar = 0x10000
                    + ((first - 0xD800) << 10)
                    + (second - 0xDC00)
            } else {
                guard !(0xDC00 ... 0xDFFF).contains(first) else {
                    throw StrictJSONPreflightIssue.malformedJSON
                }
                scalar = first
            }
        default:
            throw StrictJSONPreflightIssue.malformedJSON
        }
        guard let unicode = Unicode.Scalar(scalar) else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        return (scalar, unicode.utf8.count)
    }

    private mutating func scanRawUTF8Scalar() throws -> (
        scalar: UInt32,
        byteCount: Int
    ) {
        let first = bytes[index]
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
            throw StrictJSONPreflightIssue.malformedJSON
        }
        guard index + length <= bytes.count,
              (minimumSecond ... maximumSecond)
                .contains(bytes[index + 1])
        else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        for offset in 2 ..< length
        where !(0x80 ... 0xBF).contains(bytes[index + offset]) {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        var scalar = UInt32(first & (0x7F >> length))
        for offset in 1 ..< length {
            scalar = (scalar << 6)
                | UInt32(bytes[index + offset] & 0x3F)
        }
        index += length
        guard Unicode.Scalar(scalar) != nil else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        return (scalar, length)
    }

    private mutating func unicodeEscape() throws -> UInt32 {
        guard index + 4 <= bytes.count else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        var value: UInt32 = 0
        for _ in 0 ..< 4 {
            guard let nibble = hex(bytes[index]) else {
                throw StrictJSONPreflightIssue.malformedJSON
            }
            value = (value << 4) | nibble
            index += 1
        }
        return value
    }

    private mutating func scanNumber(
        maximumBytes: Int,
        path: String,
        materialize: Bool
    ) throws -> String? {
        let start = index
        _ = consume(0x2D)
        guard index < bytes.count else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        if consume(0x30) {
            guard index == bytes.count
                    || !(0x30 ... 0x39).contains(bytes[index])
            else {
                throw StrictJSONPreflightIssue.malformedJSON
            }
        } else {
            guard index < bytes.count,
                  (0x31 ... 0x39).contains(bytes[index])
            else {
                throw StrictJSONPreflightIssue.malformedJSON
            }
            while index < bytes.count,
                  (0x30 ... 0x39).contains(bytes[index])
            {
                index += 1
            }
        }
        if consume(0x2E) {
            try consumeDigits()
        }
        if index < bytes.count,
           bytes[index] == 0x65 || bytes[index] == 0x45
        {
            index += 1
            if index < bytes.count,
               bytes[index] == 0x2B || bytes[index] == 0x2D
            {
                index += 1
            }
            try consumeDigits()
        }
        guard index - start <= maximumBytes else {
            throw StrictJSONPreflightIssue.numericTokenTooLong(
                path: path,
                maximum: maximumBytes
            )
        }
        guard materialize else {
            return nil
        }
        guard let raw = String(
            bytes: bytes[start ..< index],
            encoding: .utf8
        ) else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        return raw
    }

    private mutating func consumeDigits() throws {
        let start = index
        while index < bytes.count,
              (0x30 ... 0x39).contains(bytes[index])
        {
            index += 1
        }
        guard index > start else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
    }

    private mutating func consumeLiteral(
        _ literal: StaticString
    ) throws {
        let expected = Array(String(describing: literal).utf8)
        guard index + expected.count <= bytes.count,
              Array(bytes[index ..< (index + expected.count)])
                == expected
        else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        index += expected.count
    }

    private mutating func consumeToken() throws {
        tokenCount += 1
        guard tokenCount <= limits.maximumTokenCount else {
            throw StrictJSONPreflightIssue.tooManyTokens(
                maximum: limits.maximumTokenCount
            )
        }
    }

    private func enter(_ depth: Int) throws {
        let effectiveMaximum = min(
            limits.maximumNestingDepth,
            StrictJSONPreflight.implementationMaximumNestingDepth
        )
        guard depth < effectiveMaximum else {
            throw StrictJSONPreflightIssue.excessiveNesting(
                maximum: effectiveMaximum
            )
        }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count,
              bytes[index] == 0x20
                || bytes[index] == 0x09
                || bytes[index] == 0x0A
                || bytes[index] == 0x0D
        {
            index += 1
        }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else {
            return false
        }
        index += 1
        return true
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
