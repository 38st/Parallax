import Foundation

enum LibraryImportEnvelopeParseResult {
    case accepted([String: Any])
    case rejected(LibraryImportValidationReport)
}

/// Enforces the byte bound before allocating a JSON object, then requires the
/// versioned document envelope used by all later phases.
struct LibraryImportEnvelopeParser {
    let limits: LibraryImportLimits

    func parse(_ data: Data) -> LibraryImportEnvelopeParseResult {
        guard data.count <= limits.maximumBytes else {
            return .rejected(
                LibraryImportValidationReport(
                    document: nil,
                    issues: [
                        LibraryImportIssueFactory.make(
                            .inputTooLarge,
                            path: "$",
                            detail: "The selected file exceeds the import byte limit."
                        )
                    ]
                )
            )
        }

        let object: Any
        do {
            try LibraryImportJSONPreflight.validate(data, maximumBytes: limits.maximumBytes)
            object = try JSONSerialization.jsonObject(with: data)
        } catch StrictJSONPreflightIssue.duplicateKey {
            return .rejected(
                LibraryImportValidationReport(
                    document: nil,
                    issues: [
                        LibraryImportIssueFactory.make(
                            .duplicateJSONKey,
                            path: "$",
                            detail: "The selected file contains duplicate JSON keys. Remove the duplicate entries and try again."
                        )
                    ]
                )
            )
        } catch {
            return .rejected(
                LibraryImportValidationReport(
                    document: nil,
                    issues: [
                        LibraryImportIssueFactory.make(
                            .malformedJSON,
                            path: "$",
                            detail: "The selected file is not valid JSON."
                        )
                    ]
                )
            )
        }

        guard let dictionary = object as? [String: Any] else {
            return .rejected(
                LibraryImportValidationReport(
                    document: nil,
                    issues: [
                        LibraryImportIssueFactory.make(
                            .invalidTopLevel,
                            path: "$",
                            detail: "Import requires a versioned library document."
                        )
                    ]
                )
            )
        }
        return .accepted(dictionary)
    }
}

enum LibraryImportTypedDocumentDecoder {
    static func decode(
        _ data: Data,
        issues: inout [LibraryImportIssue]
    ) -> LibraryDocument? {
        do {
            return try JSONDecoder().decode(LibraryDocument.self, from: data)
        } catch {
            issues.append(
                LibraryImportIssueFactory.make(
                    .decodingFailed,
                    path: "$",
                    detail: "One or more fields cannot be decoded as a current Parallax library."
                )
            )
            return nil
        }
    }
}

struct LibraryImportDocumentNormalizer {
    let limits: LibraryImportLimits

    func normalize(_ document: LibraryDocument) -> LibraryDocument {
        var document = document
        for applicationIndex in document.applications.indices {
            let applicationName = document
                .applications[applicationIndex].displayName
            document.applications[applicationIndex].displayName =
                DisplayNameValidator.normalized(
                    applicationName,
                    maximumUTF8Bytes: limits.maximumNameUTF8Bytes
                ) ?? applicationName
            for profileIndex in document
                .applications[applicationIndex].profiles.indices
            {
                let profileName = document
                    .applications[applicationIndex]
                    .profiles[profileIndex].name
                document.applications[applicationIndex]
                    .profiles[profileIndex].name =
                    DisplayNameValidator.normalized(
                        profileName,
                        maximumUTF8Bytes: limits.maximumNameUTF8Bytes
                    ) ?? profileName
                let text = document.applications[applicationIndex]
                    .profiles[profileIndex].environmentText
                let normalized = NSMutableString(string: text)
                for entry in LaunchEnvironmentParser.parse(text).entries.reversed() {
                    guard entry.name == "CLAUDE_CONFIG_DIR",
                          case .set(let value) = entry.operation,
                          let range = entry.valueRange,
                          let path = LibraryImportLaunchSecurityValidator
                            .normalizedClaudeConfigurationPath(value)
                    else { continue }
                    normalized.replaceCharacters(
                        in: NSRange(
                            location: range.start.utf16Offset,
                            length: range.end.utf16Offset - range.start.utf16Offset
                        ),
                        with: path
                    )
                }
                document.applications[applicationIndex]
                    .profiles[profileIndex].environmentText = normalized as String
            }
        }
        return document
    }
}

enum LibraryImportIssueFactory {
    static func make(
        _ code: LibraryImportIssueCode,
        severity: LibraryImportIssueSeverity = .error,
        path: String,
        detail: String.LocalizationValue
    ) -> LibraryImportIssue {
        LibraryImportIssue(
            code: code,
            severity: severity,
            path: path,
            message: String(localized: detail)
        )
    }
}
