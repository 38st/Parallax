import Foundation

enum SettingsDocumentCodecIssue: Error, Equatable, Sendable {
    case inputTooLarge(actual: Int, maximum: Int)
    case encodedOutputTooLarge(actual: Int, maximum: Int)
    case malformedJSON
    case excessiveNesting(maximum: Int)
    case tooManyTokens(maximum: Int)
    case duplicateKey(path: String, key: String)
    case invalidTopLevel
    case missingKey(path: String)
    case unknownKey(path: String)
    case invalidType(path: String)
    case invalidValue(path: String)
    case numericTokenTooLong(path: String, maximum: Int)
    case stringTooLong(path: String, maximum: Int)
    case tooManyItems(path: String, maximum: Int)
    case duplicateTemplateID(String)
    case duplicateVisualProfileID(String)
}

struct SettingsDocumentCodecFailure: Error, Equatable, Sendable {
    let issue: SettingsDocumentCodecIssue
    let originalBytes: Data
}

enum SettingsDocumentDecodeResult: Equatable, Sendable {
    case current(SettingsDocument)
    case future(schemaVersion: UInt64, originalBytes: Data)
    case invalid(SettingsDocumentCodecFailure)
}

struct SettingsDocumentCodec: Sendable {
    struct Limits: Equatable, Sendable {
        var maximumBytes = 4 * 1_024 * 1_024
        var maximumTemplates = 4_096
        var maximumVisualIdentities = 4_096
        var maximumNameUTF8Bytes = 256
        var maximumPathUTF8Bytes = 4_096
        var maximumTextUTF8Bytes = 64 * 1_024
        var maximumUnknownArrayItems = 4_096
        var maximumUnknownObjectMembers = 256
        var maximumKeyUTF8Bytes = 256
        var maximumUnknownStringUTF8Bytes = 64 * 1_024
        var maximumUnknownNumberBytes = 128
        var maximumNestingDepth = 32
        var maximumTokenCount = 200_000
    }

    private let limits: Limits

    init(limits: Limits = Limits()) {
        self.limits = limits
    }

    func decode(_ data: Data) -> SettingsDocumentDecodeResult {
        guard data.count <= limits.maximumBytes else {
            return invalid(
                .inputTooLarge(
                    actual: data.count,
                    maximum: limits.maximumBytes
                ),
                data
            )
        }
        let schemaVersion: UInt64
        let preflight = StrictJSONPreflight(
            limits: .init(
                maximumBytes: limits.maximumBytes,
                maximumArrayItems: limits.maximumUnknownArrayItems,
                maximumObjectMembers:
                    limits.maximumUnknownObjectMembers,
                maximumKeyUTF8Bytes: limits.maximumKeyUTF8Bytes,
                maximumStringUTF8Bytes:
                    limits.maximumUnknownStringUTF8Bytes,
                maximumNumberBytes: limits.maximumUnknownNumberBytes,
                maximumNestingDepth: limits.maximumNestingDepth,
                maximumTokenCount: limits.maximumTokenCount
            ),
            rootRequirement: .object,
            topLevelProbe: .init(key: "schemaVersion")
        )
        switch preflight.scan(data) {
        case .failure(let issue):
            return invalid(codecIssue(issue), data)
        case .success(let evidence):
            switch evidence.probe {
            case .numberToken(let raw):
                guard raw.allSatisfy(\.isNumber),
                      let version = UInt64(raw),
                      version > 0
                else {
                    return invalid(
                        .invalidValue(path: "$.schemaVersion"),
                        data
                    )
                }
                schemaVersion = version
            case .missing:
                return invalid(
                    .missingKey(path: "$.schemaVersion"),
                    data
                )
            case .other:
                return invalid(
                    .invalidType(path: "$.schemaVersion"),
                    data
                )
            case .notRequested:
                return invalid(.malformedJSON, data)
            }
        }
        if schemaVersion > SettingsDocument.currentSchemaVersion {
            return .future(
                schemaVersion: schemaVersion,
                originalBytes: data
            )
        }
        guard schemaVersion == SettingsDocument.currentSchemaVersion else {
            return invalid(
                .invalidValue(path: "$.schemaVersion"),
                data
            )
        }
        let value: StrictJSONValue
        do {
            var parser = StrictJSONParser(
                data: data,
                limits: limits
            )
            value = try parser.parse()
        } catch let issue as SettingsDocumentCodecIssue {
            return invalid(issue, data)
        } catch {
            return invalid(.malformedJSON, data)
        }
        guard case let .object(object) = value else {
            return invalid(.invalidTopLevel, data)
        }
        do {
            return .current(
                try currentDocument(
                    object,
                    schemaVersion: schemaVersion
                )
            )
        } catch let issue as SettingsDocumentCodecIssue {
            return invalid(issue, data)
        } catch {
            return invalid(.malformedJSON, data)
        }
    }

    func encode(_ document: SettingsDocument) throws -> Data {
        let canonical = try validated(document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        let data = try encoder.encode(canonical)
        guard data.count <= limits.maximumBytes else {
            throw SettingsDocumentCodecIssue.encodedOutputTooLarge(
                actual: data.count,
                maximum: limits.maximumBytes
            )
        }
        return data
    }

    private func invalid(
        _ issue: SettingsDocumentCodecIssue,
        _ data: Data
    ) -> SettingsDocumentDecodeResult {
        .invalid(
            SettingsDocumentCodecFailure(
                issue: issue,
                originalBytes: data
            )
        )
    }

    private func codecIssue(
        _ issue: StrictJSONPreflightIssue
    ) -> SettingsDocumentCodecIssue {
        switch issue {
        case .inputTooLarge(let actual, let maximum):
            return .inputTooLarge(actual: actual, maximum: maximum)
        case .probeKeyTooLong, .malformedJSON:
            return .malformedJSON
        case .excessiveNesting(let maximum):
            return .excessiveNesting(maximum: maximum)
        case .tooManyTokens(let maximum):
            return .tooManyTokens(maximum: maximum)
        case .duplicateKey(let path, let key):
            return .duplicateKey(path: path, key: key)
        case .invalidRoot:
            return .invalidTopLevel
        case .numericTokenTooLong(let path, let maximum):
            return .numericTokenTooLong(path: path, maximum: maximum)
        case .stringTooLong(let path, let maximum):
            return .stringTooLong(path: path, maximum: maximum)
        case .tooManyItems(let path, let maximum):
            return .tooManyItems(path: path, maximum: maximum)
        }
    }

    private func currentDocument(
        _ object: StrictJSONObject,
        schemaVersion: UInt64
    ) throws -> SettingsDocument {
        try exactKeys(
            object,
            allowed: [
                "schemaVersion",
                "revision",
                "profileTemplates",
                "defaultBaseStoragePath",
                "confirmBeforeLaunch",
                "automaticallyRecoverCrashedApps",
                "appearance",
                "profileVisualIdentities",
            ],
            path: "$"
        )
        let revision = SettingsRevision(
            rawValue: try unsignedInteger(
                object[exact: "revision"],
                path: "$.revision"
            )
        )
        let templates = try templateArray(
            object[exact: "profileTemplates"],
            path: "$.profileTemplates"
        )
        let basePath = try string(
            object[exact: "defaultBaseStoragePath"],
            path: "$.defaultBaseStoragePath",
            maximum: limits.maximumPathUTF8Bytes
        )
        let confirm = try boolean(
            object[exact: "confirmBeforeLaunch"],
            path: "$.confirmBeforeLaunch"
        )
        let recover = try boolean(
            object[exact: "automaticallyRecoverCrashedApps"],
            path: "$.automaticallyRecoverCrashedApps"
        )
        let appearance = try string(
            object[exact: "appearance"],
            path: "$.appearance",
            maximum: limits.maximumNameUTF8Bytes
        )
        guard Self.appearances.contains(appearance) else {
            throw SettingsDocumentCodecIssue.invalidValue(
                path: "$.appearance"
            )
        }
        let visuals = try visualArray(
            object[exact: "profileVisualIdentities"],
            path: "$.profileVisualIdentities"
        )
        return SettingsDocument(
            schemaVersion: schemaVersion,
            revision: revision,
            profileTemplates: templates,
            defaultBaseStoragePath: basePath,
            confirmBeforeLaunch: confirm,
            automaticallyRecoverCrashedApps: recover,
            appearance: appearance,
            profileVisualIdentities: visuals
        )
    }

    private func validated(
        _ document: SettingsDocument
    ) throws -> SettingsDocument {
        guard
            document.schemaVersion
                == SettingsDocument.currentSchemaVersion
        else {
            throw SettingsDocumentCodecIssue.invalidValue(
                path: "$.schemaVersion"
            )
        }
        let templates = try validateTemplates(
            document.profileTemplates,
            path: "$.profileTemplates"
        )
        try validateString(
            document.defaultBaseStoragePath,
            path: "$.defaultBaseStoragePath",
            maximum: limits.maximumPathUTF8Bytes
        )
        guard Self.appearances.contains(document.appearance) else {
            throw SettingsDocumentCodecIssue.invalidValue(
                path: "$.appearance"
            )
        }
        let visuals = try validateVisuals(
            document.profileVisualIdentities,
            path: "$.profileVisualIdentities"
        )
        let canonical = SettingsDocument(
            revision: document.revision,
            profileTemplates: templates,
            defaultBaseStoragePath: document.defaultBaseStoragePath,
            confirmBeforeLaunch: document.confirmBeforeLaunch,
            automaticallyRecoverCrashedApps:
                document.automaticallyRecoverCrashedApps,
            appearance: document.appearance,
            profileVisualIdentities: visuals
        )
        try validateAggregateStringBytes(canonical)
        return canonical
    }

    private func templateArray(
        _ value: StrictJSONValue?,
        path: String
    ) throws -> [SettingsDocument.Template] {
        guard let value else {
            throw SettingsDocumentCodecIssue.missingKey(path: path)
        }
        guard case let .array(values) = value else {
            throw SettingsDocumentCodecIssue.invalidType(path: path)
        }
        var templates: [SettingsDocument.Template] = []
        templates.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            let itemPath = "\(path)[\(index)]"
            guard case let .object(object) = value else {
                throw SettingsDocumentCodecIssue.invalidType(
                    path: itemPath
                )
            }
            try exactKeys(
                object,
                allowed: [
                    "id",
                    "name",
                    "argumentsText",
                    "environmentText",
                    "notes",
                ],
                path: itemPath
            )
            templates.append(
                SettingsDocument.Template(
                    id: try string(
                        object[exact: "id"],
                        path: "\(itemPath).id",
                        maximum: 36
                    ),
                    name: try string(
                        object[exact: "name"],
                        path: "\(itemPath).name",
                        maximum: limits.maximumNameUTF8Bytes
                    ),
                    argumentsText: try string(
                        object[exact: "argumentsText"],
                        path: "\(itemPath).argumentsText",
                        maximum: limits.maximumTextUTF8Bytes
                    ),
                    environmentText: try string(
                        object[exact: "environmentText"],
                        path: "\(itemPath).environmentText",
                        maximum: limits.maximumTextUTF8Bytes
                    ),
                    notes: try string(
                        object[exact: "notes"],
                        path: "\(itemPath).notes",
                        maximum: limits.maximumTextUTF8Bytes
                    )
                )
            )
        }
        return try validateTemplates(templates, path: path)
    }

    private func validateTemplates(
        _ templates: [SettingsDocument.Template],
        path: String
    ) throws -> [SettingsDocument.Template] {
        guard templates.count <= limits.maximumTemplates else {
            throw SettingsDocumentCodecIssue.tooManyItems(
                path: path,
                maximum: limits.maximumTemplates
            )
        }
        var ids = Set<UUID>()
        return try templates.enumerated().map { index, template in
            let itemPath = "\(path)[\(index)]"
            let id = try canonicalUUID(
                template.id,
                path: "\(itemPath).id"
            )
            guard ids.insert(id.uuid).inserted else {
                throw SettingsDocumentCodecIssue.duplicateTemplateID(
                    id.string
                )
            }
            try validateTemplateName(
                template.name,
                path: "\(itemPath).name"
            )
            try validateString(
                template.argumentsText,
                path: "\(itemPath).argumentsText",
                maximum: limits.maximumTextUTF8Bytes
            )
            try validateString(
                template.environmentText,
                path: "\(itemPath).environmentText",
                maximum: limits.maximumTextUTF8Bytes
            )
            try validateString(
                template.notes,
                path: "\(itemPath).notes",
                maximum: limits.maximumTextUTF8Bytes
            )
            return SettingsDocument.Template(
                id: id.string,
                name: template.name,
                argumentsText: template.argumentsText,
                environmentText: template.environmentText,
                notes: template.notes
            )
        }
    }

    private func visualArray(
        _ value: StrictJSONValue?,
        path: String
    ) throws -> [SettingsDocument.VisualIdentity] {
        guard let value else {
            throw SettingsDocumentCodecIssue.missingKey(path: path)
        }
        guard case let .array(values) = value else {
            throw SettingsDocumentCodecIssue.invalidType(path: path)
        }
        var visuals: [SettingsDocument.VisualIdentity] = []
        visuals.reserveCapacity(values.count)
        for (index, value) in values.enumerated() {
            let itemPath = "\(path)[\(index)]"
            guard case let .object(object) = value else {
                throw SettingsDocumentCodecIssue.invalidType(
                    path: itemPath
                )
            }
            try exactKeys(
                object,
                allowed: ["profileID", "symbol", "color"],
                path: itemPath
            )
            visuals.append(
                SettingsDocument.VisualIdentity(
                    profileID: try string(
                        object[exact: "profileID"],
                        path: "\(itemPath).profileID",
                        maximum: 36
                    ),
                    symbol: try string(
                        object[exact: "symbol"],
                        path: "\(itemPath).symbol",
                        maximum: limits.maximumNameUTF8Bytes
                    ),
                    color: try string(
                        object[exact: "color"],
                        path: "\(itemPath).color",
                        maximum: limits.maximumNameUTF8Bytes
                    )
                )
            )
        }
        return try validateVisuals(visuals, path: path)
    }

    private func validateVisuals(
        _ visuals: [SettingsDocument.VisualIdentity],
        path: String
    ) throws -> [SettingsDocument.VisualIdentity] {
        guard visuals.count <= limits.maximumVisualIdentities else {
            throw SettingsDocumentCodecIssue.tooManyItems(
                path: path,
                maximum: limits.maximumVisualIdentities
            )
        }
        var ids = Set<UUID>()
        var canonical: [SettingsDocument.VisualIdentity] = []
        canonical.reserveCapacity(visuals.count)
        for (index, visual) in visuals.enumerated() {
            let itemPath = "\(path)[\(index)]"
            let id = try canonicalUUID(
                visual.profileID,
                path: "\(itemPath).profileID"
            )
            guard ids.insert(id.uuid).inserted else {
                throw SettingsDocumentCodecIssue
                    .duplicateVisualProfileID(id.string)
            }
            guard Self.symbols.contains(visual.symbol) else {
                throw SettingsDocumentCodecIssue.invalidValue(
                    path: "\(itemPath).symbol"
                )
            }
            guard Self.colors.contains(visual.color) else {
                throw SettingsDocumentCodecIssue.invalidValue(
                    path: "\(itemPath).color"
                )
            }
            canonical.append(
                SettingsDocument.VisualIdentity(
                    profileID: id.string,
                    symbol: visual.symbol,
                    color: visual.color
                )
            )
        }
        return canonical.sorted {
            $0.profileID < $1.profileID
        }
    }

    private func exactKeys(
        _ object: StrictJSONObject,
        allowed: Set<String>,
        path: String
    ) throws {
        let exactAllowed = Set(allowed.map(StrictJSONKey.init))
        for key in object.keys where !exactAllowed.contains(key) {
            throw SettingsDocumentCodecIssue.unknownKey(
                path: "\(path).\(key.value)"
            )
        }
        for key in allowed where object[exact: key] == nil {
            throw SettingsDocumentCodecIssue.missingKey(
                path: "\(path).\(key)"
            )
        }
    }

    private func string(
        _ value: StrictJSONValue?,
        path: String,
        maximum: Int
    ) throws -> String {
        guard let value else {
            throw SettingsDocumentCodecIssue.missingKey(path: path)
        }
        guard case let .string(string) = value else {
            throw SettingsDocumentCodecIssue.invalidType(path: path)
        }
        try validateString(string, path: path, maximum: maximum)
        return string
    }

    private func boolean(
        _ value: StrictJSONValue?,
        path: String
    ) throws -> Bool {
        guard let value else {
            throw SettingsDocumentCodecIssue.missingKey(path: path)
        }
        guard case let .boolean(boolean) = value else {
            throw SettingsDocumentCodecIssue.invalidType(path: path)
        }
        return boolean
    }

    private func unsignedInteger(
        _ value: StrictJSONValue?,
        path: String,
        positive: Bool = false
    ) throws -> UInt64 {
        guard let value else {
            throw SettingsDocumentCodecIssue.missingKey(path: path)
        }
        guard case let .number(raw) = value else {
            throw SettingsDocumentCodecIssue.invalidType(path: path)
        }
        guard !raw.isEmpty,
              raw.allSatisfy(\.isNumber),
              let number = UInt64(raw),
              !positive || number > 0
        else {
            throw SettingsDocumentCodecIssue.invalidValue(path: path)
        }
        return number
    }

    /// The wire format preserves historical template labels byte-for-byte.
    /// New and edited labels are normalized by runtime mutation boundaries,
    /// but decoding or republishing an unrelated setting must not rewrite or
    /// reject a previously persisted label solely because policy evolved.
    private func validateTemplateName(
        _ value: String,
        path: String
    ) throws {
        try validateString(
            value,
            path: path,
            maximum: limits.maximumNameUTF8Bytes
        )
    }

    private func validateString(
        _ value: String,
        path: String,
        maximum: Int
    ) throws {
        guard value.utf8.count <= maximum else {
            throw SettingsDocumentCodecIssue.stringTooLong(
                path: path,
                maximum: maximum
            )
        }
    }

    private func validateAggregateStringBytes(
        _ document: SettingsDocument
    ) throws {
        var byteCount = 0
        func add(_ value: String) throws {
            let addition = value.utf8.count
            let (next, overflow) = byteCount.addingReportingOverflow(
                addition
            )
            guard !overflow, next <= limits.maximumBytes else {
                throw SettingsDocumentCodecIssue
                    .encodedOutputTooLarge(
                        actual: overflow ? .max : next,
                        maximum: limits.maximumBytes
                    )
            }
            byteCount = next
        }
        try add(document.defaultBaseStoragePath)
        try add(document.appearance)
        for template in document.profileTemplates {
            try add(template.id)
            try add(template.name)
            try add(template.argumentsText)
            try add(template.environmentText)
            try add(template.notes)
        }
        for visual in document.profileVisualIdentities {
            try add(visual.profileID)
            try add(visual.symbol)
            try add(visual.color)
        }
    }

    private func canonicalUUID(
        _ raw: String,
        path: String
    ) throws -> (uuid: UUID, string: String) {
        guard let uuid = UUID(uuidString: raw) else {
            throw SettingsDocumentCodecIssue.invalidValue(path: path)
        }
        return (uuid, uuid.uuidString.lowercased())
    }

    private static let appearances: Set<String> = [
        "system", "light", "dark",
    ]
    private static let colors: Set<String> = [
        "blue", "purple", "orange", "pink", "teal", "green",
        "indigo", "cyan", "brown", "gray",
    ]
    private static let symbols: Set<String> = [
        "briefcase.fill", "person.crop.circle.fill", "flask.fill",
        "terminal.fill", "book.closed.fill", "paintpalette.fill",
        "globe", "lightbulb.fill", "hammer.fill", "camera.fill",
        "music.note", "leaf.fill", "app.dashed",
    ]
}

private struct StrictJSONKey: Hashable {
    let value: String
    private let scalars: [UInt32]

    init(_ value: String) {
        self.value = value
        scalars = value.unicodeScalars.map(\.value)
    }

    static func == (
        lhs: StrictJSONKey,
        rhs: StrictJSONKey
    ) -> Bool {
        lhs.scalars == rhs.scalars
    }

    func hash(into hasher: inout Hasher) {
        for scalar in scalars {
            hasher.combine(scalar)
        }
    }
}

private typealias StrictJSONObject = [
    StrictJSONKey: StrictJSONValue
]

private extension Dictionary
where Key == StrictJSONKey, Value == StrictJSONValue {
    subscript(exact key: String) -> StrictJSONValue? {
        self[StrictJSONKey(key)]
    }
}

private enum StrictJSONContext {
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

    func child(for key: StrictJSONKey) -> Self {
        switch self {
        case .root:
            if key == StrictJSONKey("profileTemplates") {
                return .templates
            }
            if key == StrictJSONKey("profileVisualIdentities") {
                return .visuals
            }
            if key == StrictJSONKey("defaultBaseStoragePath") {
                return .basePath
            }
            if key == StrictJSONKey("appearance") {
                return .appearance
            }
            if key == StrictJSONKey("schemaVersion")
                || key == StrictJSONKey("revision")
            {
                return .unsignedInteger
            }
        case .template:
            if key == StrictJSONKey("id") {
                return .identifier
            }
            if key == StrictJSONKey("name") {
                return .name
            }
            if key == StrictJSONKey("argumentsText")
                || key == StrictJSONKey("environmentText")
                || key == StrictJSONKey("notes")
            {
                return .text
            }
        case .visual:
            if key == StrictJSONKey("profileID") {
                return .identifier
            }
            if key == StrictJSONKey("symbol") {
                return .symbol
            }
            if key == StrictJSONKey("color") {
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
        _ limits: SettingsDocumentCodec.Limits
    ) -> Int {
        switch self {
        case .templates: limits.maximumTemplates
        case .visuals: limits.maximumVisualIdentities
        default: limits.maximumUnknownArrayItems
        }
    }

    func maximumObjectMembers(
        _ limits: SettingsDocumentCodec.Limits
    ) -> Int {
        limits.maximumUnknownObjectMembers
    }

    func maximumStringUTF8Bytes(
        _ limits: SettingsDocumentCodec.Limits
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
        _ limits: SettingsDocumentCodec.Limits
    ) -> Int {
        switch self {
        case .unsignedInteger: 20
        default: limits.maximumUnknownNumberBytes
        }
    }
}

private indirect enum StrictJSONValue {
    case object(StrictJSONObject)
    case array([StrictJSONValue])
    case string(String)
    case number(String)
    case boolean(Bool)
    case null
}

private struct StrictJSONParser {
    private let bytes: [UInt8]
    private let limits: SettingsDocumentCodec.Limits
    private var index = 0
    private var tokenCount = 0

    init(
        data: Data,
        limits: SettingsDocumentCodec.Limits
    ) {
        bytes = Array(data)
        self.limits = limits
    }

    mutating func parse() throws -> StrictJSONValue {
        skipWhitespace()
        let value = try parseValue(
            path: "$",
            depth: 0,
            context: .root
        )
        skipWhitespace()
        guard index == bytes.count else {
            throw SettingsDocumentCodecIssue.malformedJSON
        }
        return value
    }

    private mutating func parseValue(
        path: String,
        depth: Int,
        context: StrictJSONContext
    ) throws -> StrictJSONValue {
        try consumeToken()
        guard index < bytes.count else {
            throw SettingsDocumentCodecIssue.malformedJSON
        }
        switch bytes[index] {
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
            throw SettingsDocumentCodecIssue.malformedJSON
        }
    }

    private mutating func parseObject(
        path: String,
        depth: Int,
        context: StrictJSONContext
    ) throws -> StrictJSONValue {
        try enter(depth)
        index += 1
        skipWhitespace()
        var object: StrictJSONObject = [:]
        if consume(0x7D) {
            return .object(object)
        }
        while true {
            let maximum = context.maximumObjectMembers(limits)
            guard object.count < maximum else {
                throw SettingsDocumentCodecIssue.tooManyItems(
                    path: path,
                    maximum: maximum
                )
            }
            guard index < bytes.count, bytes[index] == 0x22 else {
                throw SettingsDocumentCodecIssue.malformedJSON
            }
            try consumeToken()
            let key = StrictJSONKey(
                try parseString(
                    maximumUTF8Bytes: limits.maximumKeyUTF8Bytes,
                    path: "\(path).<key>"
                )
            )
            guard object[key] == nil else {
                throw SettingsDocumentCodecIssue.duplicateKey(
                    path: path,
                    key: key.value
                )
            }
            skipWhitespace()
            guard consume(0x3A) else {
                throw SettingsDocumentCodecIssue.malformedJSON
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
                throw SettingsDocumentCodecIssue.malformedJSON
            }
            skipWhitespace()
        }
    }

    private mutating func parseArray(
        path: String,
        depth: Int,
        context: StrictJSONContext
    ) throws -> StrictJSONValue {
        try enter(depth)
        index += 1
        skipWhitespace()
        var array: [StrictJSONValue] = []
        if consume(0x5D) {
            return .array(array)
        }
        while true {
            let maximum = context.maximumArrayItems(limits)
            guard array.count < maximum else {
                throw SettingsDocumentCodecIssue.tooManyItems(
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
                throw SettingsDocumentCodecIssue.malformedJSON
            }
            skipWhitespace()
        }
    }

    private mutating func parseString(
        maximumUTF8Bytes: Int,
        path: String
    ) throws -> String {
        guard consume(0x22) else {
            throw SettingsDocumentCodecIssue.malformedJSON
        }
        var result = ""
        var decodedUTF8Bytes = 0
        var segmentStart = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x22 || byte == 0x5C {
                try appendUTF8(
                    segmentStart..<index,
                    to: &result,
                    decodedUTF8Bytes: &decodedUTF8Bytes,
                    maximumUTF8Bytes: maximumUTF8Bytes,
                    path: path
                )
                if byte == 0x22 {
                    index += 1
                    return result
                }
                index += 1
                guard index < bytes.count else {
                    throw SettingsDocumentCodecIssue.malformedJSON
                }
                try appendEscape(
                    to: &result,
                    decodedUTF8Bytes: &decodedUTF8Bytes,
                    maximumUTF8Bytes: maximumUTF8Bytes,
                    path: path
                )
                segmentStart = index
            } else {
                guard byte >= 0x20 else {
                    throw SettingsDocumentCodecIssue.malformedJSON
                }
                index += 1
            }
        }
        throw SettingsDocumentCodecIssue.malformedJSON
    }

    private mutating func appendEscape(
        to result: inout String,
        decodedUTF8Bytes: inout Int,
        maximumUTF8Bytes: Int,
        path: String
    ) throws {
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
            if (0xD800...0xDBFF).contains(first) {
                guard index + 2 <= bytes.count,
                      bytes[index] == 0x5C,
                      bytes[index + 1] == 0x75
                else {
                    throw SettingsDocumentCodecIssue.malformedJSON
                }
                index += 2
                let second = try unicodeEscape()
                guard (0xDC00...0xDFFF).contains(second) else {
                    throw SettingsDocumentCodecIssue.malformedJSON
                }
                scalar = 0x10000
                    + ((first - 0xD800) << 10)
                    + (second - 0xDC00)
            } else {
                guard !(0xDC00...0xDFFF).contains(first) else {
                    throw SettingsDocumentCodecIssue.malformedJSON
                }
                scalar = first
            }
        default:
            throw SettingsDocumentCodecIssue.malformedJSON
        }
        try appendScalar(
            scalar,
            to: &result,
            decodedUTF8Bytes: &decodedUTF8Bytes,
            maximumUTF8Bytes: maximumUTF8Bytes,
            path: path
        )
    }

    private mutating func unicodeEscape() throws -> UInt32 {
        guard index + 4 <= bytes.count else {
            throw SettingsDocumentCodecIssue.malformedJSON
        }
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let nibble = hex(bytes[index]) else {
                throw SettingsDocumentCodecIssue.malformedJSON
            }
            value = (value << 4) | nibble
            index += 1
        }
        return value
    }

    private mutating func parseNumber(
        maximumBytes: Int,
        path: String
    ) throws -> String {
        let start = index
        _ = consume(0x2D)
        guard index < bytes.count else {
            throw SettingsDocumentCodecIssue.malformedJSON
        }
        if consume(0x30) {
            guard index == bytes.count
                    || !(0x30...0x39).contains(bytes[index])
            else {
                throw SettingsDocumentCodecIssue.malformedJSON
            }
        } else {
            guard index < bytes.count,
                  (0x31...0x39).contains(bytes[index])
            else {
                throw SettingsDocumentCodecIssue.malformedJSON
            }
            while index < bytes.count,
                  (0x30...0x39).contains(bytes[index])
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
            throw SettingsDocumentCodecIssue.numericTokenTooLong(
                path: path,
                maximum: maximumBytes
            )
        }
        guard let raw = String(
            bytes: bytes[start..<index],
            encoding: .utf8
        ) else {
            throw SettingsDocumentCodecIssue.malformedJSON
        }
        return raw
    }

    private mutating func consumeDigits() throws {
        let start = index
        while index < bytes.count,
              (0x30...0x39).contains(bytes[index])
        {
            index += 1
        }
        guard index > start else {
            throw SettingsDocumentCodecIssue.malformedJSON
        }
    }

    private mutating func consumeLiteral(
        _ literal: StaticString
    ) throws {
        let expected = Array(
            String(describing: literal).utf8
        )
        guard index + expected.count <= bytes.count,
              Array(bytes[index..<(index + expected.count)])
                == expected
        else {
            throw SettingsDocumentCodecIssue.malformedJSON
        }
        index += expected.count
    }

    private mutating func appendUTF8(
        _ range: Range<Int>,
        to result: inout String,
        decodedUTF8Bytes: inout Int,
        maximumUTF8Bytes: Int,
        path: String
    ) throws {
        try addDecodedUTF8Bytes(
            range.count,
            to: &decodedUTF8Bytes,
            maximum: maximumUTF8Bytes,
            path: path
        )
        guard let segment = String(
            bytes: bytes[range],
            encoding: .utf8
        ) else {
            throw SettingsDocumentCodecIssue.malformedJSON
        }
        result.append(segment)
    }

    private func appendScalar(
        _ value: UInt32,
        to result: inout String,
        decodedUTF8Bytes: inout Int,
        maximumUTF8Bytes: Int,
        path: String
    ) throws {
        guard let scalar = Unicode.Scalar(value) else {
            throw SettingsDocumentCodecIssue.malformedJSON
        }
        try addDecodedUTF8Bytes(
            scalar.utf8.count,
            to: &decodedUTF8Bytes,
            maximum: maximumUTF8Bytes,
            path: path
        )
        result.unicodeScalars.append(scalar)
    }

    private func addDecodedUTF8Bytes(
        _ addition: Int,
        to count: inout Int,
        maximum: Int,
        path: String
    ) throws {
        let (next, overflow) = count.addingReportingOverflow(
            addition
        )
        guard !overflow, next <= maximum else {
            throw SettingsDocumentCodecIssue.stringTooLong(
                path: path,
                maximum: maximum
            )
        }
        count = next
    }

    private mutating func consumeToken() throws {
        tokenCount += 1
        guard tokenCount <= limits.maximumTokenCount else {
            throw SettingsDocumentCodecIssue.tooManyTokens(
                maximum: limits.maximumTokenCount
            )
        }
    }

    private func enter(_ depth: Int) throws {
        guard depth < limits.maximumNestingDepth else {
            throw SettingsDocumentCodecIssue.excessiveNesting(
                maximum: limits.maximumNestingDepth
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
        case 0x30...0x39: UInt32(byte - 0x30)
        case 0x41...0x46: UInt32(byte - 0x41 + 10)
        case 0x61...0x66: UInt32(byte - 0x61 + 10)
        default: nil
        }
    }
}
