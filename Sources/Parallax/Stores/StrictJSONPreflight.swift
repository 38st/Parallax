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
    let rootItemCount: Int?
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

private struct StrictJSONPreflightEngine {
    private enum ProbeCandidate {
        case number(String)
        case other
    }

    private var cursor: StrictJSONByteCursor
    private let limits: StrictJSONPreflight.Limits
    private let probe: StrictJSONPreflight.TopLevelProbe?
    private var tokenCount = 0
    private var probeCandidate: ProbeCandidate?
    private var rootItemCount: Int?

    init(
        data: Data,
        limits: StrictJSONPreflight.Limits,
        probe: StrictJSONPreflight.TopLevelProbe?
    ) {
        cursor = StrictJSONByteCursor(data: data)
        self.limits = limits
        self.probe = probe
    }

    mutating func scan() throws -> StrictJSONPreflightEvidence {
        skipWhitespace()
        guard cursor.currentByte != nil else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        let root = try scanValue(
            path: "$",
            depth: 0,
            isTopLevel: true
        )
        skipWhitespace()
        guard cursor.isAtEnd else {
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
        return .init(
            root: root,
            probe: state,
            rootItemCount: rootItemCount
        )
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
        guard let currentByte = cursor.currentByte else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        switch currentByte {
        case 0x7B:
            try scanObject(
                path: path,
                depth: depth,
                isTopLevel: isTopLevel
            )
            return .object
        case 0x5B:
            try scanArray(
                path: path,
                depth: depth,
                isTopLevel: isTopLevel
            )
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
        var keys = Set<StrictJSONExactKey>()
        if consume(0x7D) {
            if isTopLevel {
                rootItemCount = 0
            }
            return
        }
        while true {
            guard keys.count < limits.maximumObjectMembers else {
                throw StrictJSONPreflightIssue.tooManyItems(
                    path: path,
                    maximum: limits.maximumObjectMembers
                )
            }
            guard cursor.currentByte == 0x22 else {
                throw StrictJSONPreflightIssue.malformedJSON
            }
            try consumeToken()
            let key = StrictJSONExactKey(
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
               key == StrictJSONExactKey(probe.key)
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
                if isTopLevel {
                    rootItemCount = keys.count
                }
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
        guard let currentByte = cursor.currentByte else {
            throw StrictJSONPreflightIssue.malformedJSON
        }
        if currentByte == 0x2D
            || (0x30 ... 0x39).contains(currentByte)
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
        depth: Int,
        isTopLevel: Bool
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
            if isTopLevel {
                rootItemCount = 0
            }
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
                if isTopLevel {
                    rootItemCount = count
                }
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
        do {
            return try cursor.scanString(
                maximumUTF8Bytes: maximumUTF8Bytes,
                materialize: materialize,
                validationOrder: .scalarBeforeLength
            )
        } catch StrictJSONLexicalIssue.stringTooLong {
            throw StrictJSONPreflightIssue.stringTooLong(
                path: path,
                maximum: maximumUTF8Bytes
            )
        } catch {
            throw StrictJSONPreflightIssue.malformedJSON
        }
    }

    private mutating func scanNumber(
        maximumBytes: Int,
        path: String,
        materialize: Bool
    ) throws -> String? {
        do {
            return try cursor.scanNumber(
                maximumBytes: maximumBytes,
                materialize: materialize
            )
        } catch StrictJSONLexicalIssue.numericTokenTooLong {
            throw StrictJSONPreflightIssue.numericTokenTooLong(
                path: path,
                maximum: maximumBytes
            )
        } catch {
            throw StrictJSONPreflightIssue.malformedJSON
        }
    }

    private mutating func consumeLiteral(
        _ literal: StaticString
    ) throws {
        do {
            try cursor.consumeLiteral(literal)
        } catch {
            throw StrictJSONPreflightIssue.malformedJSON
        }
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
        cursor.skipWhitespace()
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        cursor.consume(byte)
    }
}
