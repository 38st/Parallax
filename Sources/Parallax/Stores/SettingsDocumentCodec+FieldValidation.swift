import Foundation

extension SettingsDocumentCodec {
    func exactKeys(
        _ object: SettingsStrictJSONObject,
        allowed: Set<String>,
        path: String
    ) throws {
        let exactAllowed = Set(allowed.map(StrictJSONExactKey.init))
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

    func string(
        _ value: SettingsStrictJSONParser.Value?,
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

    func boolean(
        _ value: SettingsStrictJSONParser.Value?,
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

    func unsignedInteger(
        _ value: SettingsStrictJSONParser.Value?,
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
    func validateTemplateName(
        _ value: String,
        path: String
    ) throws {
        try validateString(
            value,
            path: path,
            maximum: limits.maximumNameUTF8Bytes
        )
    }

    func validateString(
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

    func validateAggregateStringBytes(
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

    func canonicalUUID(
        _ raw: String,
        path: String
    ) throws -> (uuid: UUID, string: String) {
        guard let uuid = UUID(uuidString: raw) else {
            throw SettingsDocumentCodecIssue.invalidValue(path: path)
        }
        return (uuid, uuid.uuidString.lowercased())
    }
}
