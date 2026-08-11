import Foundation

enum SensitiveConfigurationTextSanitizationPolicy: Equatable, Sendable {
    case omit
    case redact
    case includeAfterExplicitConfirmation
}

enum SensitiveConfigurationTextSanitizationError: Error, Equatable, Sendable {
    case invalidArguments
    case invalidEnvironment
}

struct SensitiveConfigurationTextSanitizationResult: Equatable, Sendable {
    let text: String
    let containsSensitiveContent: Bool
    let wasModified: Bool

    init(
        originalText: String,
        text: String,
        containsSensitiveContent: Bool
    ) {
        self.text = text
        self.containsSensitiveContent = containsSensitiveContent
        wasModified = text != originalText
    }
}

/// Pure, fail-closed sanitization for launch configuration text.
///
/// Parsing always succeeds before any policy is applied. Environment edits use
/// parser-provided UTF-16 ranges and are applied from the end of the string so
/// earlier ranges remain stable. Keychain references are intentionally retained
/// because they contain no secret value.
struct SensitiveConfigurationTextSanitizer: Sendable {
    func sanitizeEnvironment(
        _ text: String,
        explicitSensitiveKeys: Set<String>,
        policy: SensitiveConfigurationTextSanitizationPolicy
    ) throws -> SensitiveConfigurationTextSanitizationResult {
        let parsed = LaunchEnvironmentParser.parse(text)
        guard !parsed.hasErrors else {
            throw SensitiveConfigurationTextSanitizationError
                .invalidEnvironment
        }

        let classifier = SensitiveEnvironmentKeyClassifier(
            explicitSensitiveKeys: explicitSensitiveKeys
        )
        var replacements: [(range: NSRange, text: String)] = []
        var containsSensitiveLiterals = false

        for entry in parsed.entries {
            guard
                case .set(let storedText) = entry.operation,
                classifier.isSensitive(entry.name),
                case .literal = StoredEnvironmentValue(
                    storedText: storedText
                )
            else {
                continue
            }
            containsSensitiveLiterals = true

            switch policy {
            case .includeAfterExplicitConfirmation:
                continue
            case .redact:
                guard let valueRange = entry.valueRange else {
                    continue
                }
                replacements.append(
                    (
                        NSRange(
                            location: valueRange.start.utf16Offset,
                            length:
                                valueRange.end.utf16Offset
                                - valueRange.start.utf16Offset
                        ),
                        "<redacted>"
                    )
                )
            case .omit:
                replacements.append(
                    (
                        NSRange(
                            location: entry.range.start.utf16Offset,
                            length:
                                entry.range.end.utf16Offset
                                - entry.range.start.utf16Offset
                        ),
                        "# Omitted sensitive value: \(entry.name)"
                    )
                )
            }
        }

        let result = NSMutableString(string: text)
        for replacement in replacements.sorted(by: {
            $0.range.location > $1.range.location
        }) {
            result.replaceCharacters(
                in: replacement.range,
                with: replacement.text
            )
        }
        return SensitiveConfigurationTextSanitizationResult(
            originalText: text,
            text: result as String,
            containsSensitiveContent: containsSensitiveLiterals
        )
    }

    func sanitizeArguments(
        _ text: String,
        policy: SensitiveConfigurationTextSanitizationPolicy
    ) throws -> SensitiveConfigurationTextSanitizationResult {
        let parsed = LaunchArgumentParser.parse(text)
        guard !parsed.hasErrors else {
            throw SensitiveConfigurationTextSanitizationError
                .invalidArguments
        }
        let disclosure = SensitiveLaunchArgumentPolicy()
        let sensitiveIndexes = disclosure.sensitiveTokenIndexes(
            in: parsed.tokens
        )
        guard !sensitiveIndexes.isEmpty else {
            return SensitiveConfigurationTextSanitizationResult(
                originalText: text,
                text: text,
                containsSensitiveContent: false
            )
        }

        let sanitizedText: String
        switch policy {
        case .includeAfterExplicitConfirmation:
            sanitizedText = text
        case .redact:
            sanitizedText = LaunchArgumentParser.serialize(
                disclosure.redactedWords(in: parsed.tokens)
            )
        case .omit:
            sanitizedText = LaunchArgumentParser.serialize(
                disclosure.redactedWords(
                    in: parsed.tokens,
                    omission: true
                )
            )
        }
        return SensitiveConfigurationTextSanitizationResult(
            originalText: text,
            text: sanitizedText,
            containsSensitiveContent: true
        )
    }
}
