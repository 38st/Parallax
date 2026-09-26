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

    let limits: Limits

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
        let value: SettingsStrictJSONParser.Value
        do {
            var parser = SettingsStrictJSONParser(
                data: data,
                limits: .init(
                    maximumTemplates: limits.maximumTemplates,
                    maximumVisualIdentities:
                        limits.maximumVisualIdentities,
                    maximumNameUTF8Bytes: limits.maximumNameUTF8Bytes,
                    maximumPathUTF8Bytes: limits.maximumPathUTF8Bytes,
                    maximumTextUTF8Bytes: limits.maximumTextUTF8Bytes,
                    maximumUnknownArrayItems:
                        limits.maximumUnknownArrayItems,
                    maximumUnknownObjectMembers:
                        limits.maximumUnknownObjectMembers,
                    maximumKeyUTF8Bytes: limits.maximumKeyUTF8Bytes,
                    maximumUnknownStringUTF8Bytes:
                        limits.maximumUnknownStringUTF8Bytes,
                    maximumUnknownNumberBytes:
                        limits.maximumUnknownNumberBytes,
                    maximumNestingDepth: limits.maximumNestingDepth,
                    maximumTokenCount: limits.maximumTokenCount
                )
            )
            value = try parser.parse()
        } catch let issue as SettingsStrictJSONParser.Issue {
            return invalid(codecIssue(issue), data)
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

    private func codecIssue(
        _ issue: SettingsStrictJSONParser.Issue
    ) -> SettingsDocumentCodecIssue {
        switch issue {
        case .malformedJSON:
            return .malformedJSON
        case .excessiveNesting(let maximum):
            return .excessiveNesting(maximum: maximum)
        case .tooManyTokens(let maximum):
            return .tooManyTokens(maximum: maximum)
        case .duplicateKey(let path, let key):
            return .duplicateKey(path: path, key: key)
        case .numericTokenTooLong(let path, let maximum):
            return .numericTokenTooLong(path: path, maximum: maximum)
        case .stringTooLong(let path, let maximum):
            return .stringTooLong(path: path, maximum: maximum)
        case .tooManyItems(let path, let maximum):
            return .tooManyItems(path: path, maximum: maximum)
        }
    }

    private func currentDocument(
        _ object: SettingsStrictJSONObject,
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

    private static let appearances: Set<String> = [
        "system", "light", "dark",
    ]
    static let colors: Set<String> = [
        "blue", "purple", "orange", "pink", "teal", "green",
        "indigo", "cyan", "brown", "gray",
    ]
    static let symbols: Set<String> = [
        "briefcase.fill", "person.crop.circle.fill", "flask.fill",
        "terminal.fill", "book.closed.fill", "paintpalette.fill",
        "globe", "lightbulb.fill", "hammer.fill", "camera.fill",
        "music.note", "leaf.fill", "app.dashed",
    ]
}
