import Foundation

/// Materializes a bounded JSON value tree after the shared lexical preflight.
///
/// This parser is intentionally schema-aware only for resource limits. Settings
/// document validation and future-schema handling remain in
/// `SettingsDocumentCodec`.
struct SettingsStrictJSONParser {
    struct Limits: Equatable, Sendable {
        let maximumTemplates: Int
        let maximumVisualIdentities: Int
        let maximumNameUTF8Bytes: Int
        let maximumPathUTF8Bytes: Int
        let maximumTextUTF8Bytes: Int
        let maximumUnknownArrayItems: Int
        let maximumUnknownObjectMembers: Int
        let maximumKeyUTF8Bytes: Int
        let maximumUnknownStringUTF8Bytes: Int
        let maximumUnknownNumberBytes: Int
        let maximumNestingDepth: Int
        let maximumTokenCount: Int
    }

    enum Issue: Error, Equatable, Sendable {
        case malformedJSON
        case excessiveNesting(maximum: Int)
        case tooManyTokens(maximum: Int)
        case duplicateKey(path: String, key: String)
        case numericTokenTooLong(path: String, maximum: Int)
        case stringTooLong(path: String, maximum: Int)
        case tooManyItems(path: String, maximum: Int)
    }

    indirect enum Value {
        case object(SettingsStrictJSONObject)
        case array([Value])
        case string(String)
        case number(String)
        case boolean(Bool)
        case null
    }

    private var cursor: StrictJSONByteCursor
    private let limits: Limits
    private var tokenCount = 0

    init(
        data: Data,
        limits: Limits
    ) {
        cursor = StrictJSONByteCursor(data: data)
        self.limits = limits
    }

    mutating func parse() throws -> Value {
        skipWhitespace()
        let value = try parseValue(
            path: "$",
            depth: 0,
            context: .root
        )
        skipWhitespace()
        guard cursor.isAtEnd else {
            throw Issue.malformedJSON
        }
        return value
    }

    private mutating func parseValue(
        path: String,
        depth: Int,
        context: SettingsStrictJSONContext
    ) throws -> Value {
        try consumeToken()
        guard let currentByte = cursor.currentByte else {
            throw Issue.malformedJSON
        }
        switch currentByte {
        case 0x7B:
            return try parseObject(
                path: path,
                depth: depth,
                context: context
            )
        case 0x5B:
            return try parseArray(
                path: path,
                depth: depth,
                context: context
            )
        case 0x22:
            return .string(
                try parseString(
                    maximumUTF8Bytes:
                        context.maximumStringUTF8Bytes(limits),
                    path: path
                )
            )
        case 0x74:
            try consumeLiteral("true")
            return .boolean(true)
        case 0x66:
            try consumeLiteral("false")
            return .boolean(false)
        case 0x6E:
            try consumeLiteral("null")
            return .null
        case 0x2D, 0x30...0x39:
            return .number(
                try parseNumber(
                    maximumBytes:
                        context.maximumNumberBytes(limits),
                    path: path
                )
            )
        default:
            throw Issue.malformedJSON
        }
    }

    private mutating func parseObject(
        path: String,
        depth: Int,
        context: SettingsStrictJSONContext
    ) throws -> Value {
        try enter(depth)
        cursor.advance()
        skipWhitespace()
        var object: SettingsStrictJSONObject = [:]
        if consume(0x7D) {
            return .object(object)
        }
        while true {
            let maximum = context.maximumObjectMembers(limits)
            guard object.count < maximum else {
                throw Issue.tooManyItems(
                    path: path,
                    maximum: maximum
                )
            }
            guard cursor.currentByte == 0x22 else {
                throw Issue.malformedJSON
            }
            try consumeToken()
            let key = StrictJSONExactKey(
                try parseString(
                    maximumUTF8Bytes: limits.maximumKeyUTF8Bytes,
                    path: "\(path).<key>"
                )
            )
            guard object[key] == nil else {
                throw Issue.duplicateKey(
                    path: path,
                    key: key.value
                )
            }
            skipWhitespace()
            guard consume(0x3A) else {
                throw Issue.malformedJSON
            }
            skipWhitespace()
            object[key] = try parseValue(
                path: "\(path).\(key.value)",
                depth: depth + 1,
                context: context.child(for: key)
            )
            skipWhitespace()
            if consume(0x7D) {
                return .object(object)
            }
            guard consume(0x2C) else {
                throw Issue.malformedJSON
            }
            skipWhitespace()
        }
    }

    private mutating func parseArray(
        path: String,
        depth: Int,
        context: SettingsStrictJSONContext
    ) throws -> Value {
        try enter(depth)
        cursor.advance()
        skipWhitespace()
        var array: [Value] = []
        if consume(0x5D) {
            return .array(array)
        }
        while true {
            let maximum = context.maximumArrayItems(limits)
            guard array.count < maximum else {
                throw Issue.tooManyItems(
                    path: path,
                    maximum: maximum
                )
            }
            array.append(
                try parseValue(
                    path: "\(path)[\(array.count)]",
                    depth: depth + 1,
                    context: context.arrayElement
                )
            )
            skipWhitespace()
            if consume(0x5D) {
                return .array(array)
            }
            guard consume(0x2C) else {
                throw Issue.malformedJSON
            }
            skipWhitespace()
        }
    }

    private mutating func parseString(
        maximumUTF8Bytes: Int,
        path: String
    ) throws -> String {
        do {
            return try cursor.scanString(
                maximumUTF8Bytes: maximumUTF8Bytes,
                materialize: true,
                validationOrder: .lengthBeforeScalarValidation
            ) ?? ""
        } catch StrictJSONLexicalIssue.stringTooLong {
            throw Issue.stringTooLong(
                path: path,
                maximum: maximumUTF8Bytes
            )
        } catch {
            throw Issue.malformedJSON
        }
    }

    private mutating func parseNumber(
        maximumBytes: Int,
        path: String
    ) throws -> String {
        do {
            return try cursor.scanNumber(
                maximumBytes: maximumBytes,
                materialize: true
            ) ?? ""
        } catch StrictJSONLexicalIssue.numericTokenTooLong {
            throw Issue.numericTokenTooLong(
                path: path,
                maximum: maximumBytes
            )
        } catch {
            throw Issue.malformedJSON
        }
    }

    private mutating func consumeLiteral(
        _ literal: StaticString
    ) throws {
        do {
            try cursor.consumeLiteral(literal)
        } catch {
            throw Issue.malformedJSON
        }
    }

    private mutating func consumeToken() throws {
        tokenCount += 1
        guard tokenCount <= limits.maximumTokenCount else {
            throw Issue.tooManyTokens(
                maximum: limits.maximumTokenCount
            )
        }
    }

    private func enter(_ depth: Int) throws {
        guard depth < limits.maximumNestingDepth else {
            throw Issue.excessiveNesting(
                maximum: limits.maximumNestingDepth
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

typealias SettingsStrictJSONObject = [
    StrictJSONExactKey: SettingsStrictJSONParser.Value
]

extension Dictionary
where Key == StrictJSONExactKey, Value == SettingsStrictJSONParser.Value {
    subscript(exact key: String) -> SettingsStrictJSONParser.Value? {
        self[StrictJSONExactKey(key)]
    }
}

private enum SettingsStrictJSONContext {
    case root
    case templates
    case template
    case visuals
    case visual
    case basePath
    case name
    case identifier
    case text
    case appearance
    case symbol
    case color
    case unsignedInteger
    case unknown

    func child(for key: StrictJSONExactKey) -> Self {
        switch self {
        case .root:
            if key == StrictJSONExactKey("profileTemplates") {
                return .templates
            }
            if key == StrictJSONExactKey("profileVisualIdentities") {
                return .visuals
            }
            if key == StrictJSONExactKey("defaultBaseStoragePath") {
                return .basePath
            }
            if key == StrictJSONExactKey("appearance") {
                return .appearance
            }
            if key == StrictJSONExactKey("schemaVersion")
                || key == StrictJSONExactKey("revision")
            {
                return .unsignedInteger
            }
        case .template:
            if key == StrictJSONExactKey("id") {
                return .identifier
            }
            if key == StrictJSONExactKey("name") {
                return .name
            }
            if key == StrictJSONExactKey("argumentsText")
                || key == StrictJSONExactKey("environmentText")
                || key == StrictJSONExactKey("notes")
            {
                return .text
            }
        case .visual:
            if key == StrictJSONExactKey("profileID") {
                return .identifier
            }
            if key == StrictJSONExactKey("symbol") {
                return .symbol
            }
            if key == StrictJSONExactKey("color") {
                return .color
            }
        default:
            break
        }
        return .unknown
    }

    var arrayElement: Self {
        switch self {
        case .templates: .template
        case .visuals: .visual
        default: .unknown
        }
    }

    func maximumArrayItems(
        _ limits: SettingsStrictJSONParser.Limits
    ) -> Int {
        switch self {
        case .templates: limits.maximumTemplates
        case .visuals: limits.maximumVisualIdentities
        default: limits.maximumUnknownArrayItems
        }
    }

    func maximumObjectMembers(
        _ limits: SettingsStrictJSONParser.Limits
    ) -> Int {
        limits.maximumUnknownObjectMembers
    }

    func maximumStringUTF8Bytes(
        _ limits: SettingsStrictJSONParser.Limits
    ) -> Int {
        switch self {
        case .identifier: 36
        case .name: limits.maximumNameUTF8Bytes
        case .basePath: limits.maximumPathUTF8Bytes
        case .text: limits.maximumTextUTF8Bytes
        case .appearance, .color: 16
        case .symbol: 64
        default: limits.maximumUnknownStringUTF8Bytes
        }
    }

    func maximumNumberBytes(
        _ limits: SettingsStrictJSONParser.Limits
    ) -> Int {
        switch self {
        case .unsignedInteger: 20
        default: limits.maximumUnknownNumberBytes
        }
    }
}
