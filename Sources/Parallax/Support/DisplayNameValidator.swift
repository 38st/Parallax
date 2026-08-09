import Foundation

enum DisplayNameSubject: Sendable {
    case application
    case space
    case template
}

enum DisplayNameValidationIssue: Equatable, Sendable {
    case empty
    case prohibitedFormatting
    case reserved
    case tooLong(maximumUTF8Bytes: Int)

    func message(for subject: DisplayNameSubject) -> String {
        switch self {
        case .empty:
            switch subject {
            case .application:
                String(localized: "Enter a name for this app.")
            case .space:
                String(localized: "Enter a name for this space.")
            case .template:
                String(localized: "Enter a name for this template.")
            }
        case .prohibitedFormatting:
            String(
                localized:
                    "Names cannot contain control, line-separator, or invisible formatting characters."
            )
        case .reserved:
            String(
                localized:
                    "Choose a descriptive name instead of “.” or “..”."
            )
        case .tooLong(let maximumUTF8Bytes):
            String(
                format: String(
                    localized:
                        "Names must be %lld UTF-8 bytes or fewer."
                ),
                Int64(maximumUTF8Bytes)
            )
        }
    }
}

struct DisplayNameValidation: Equatable, Sendable {
    let normalized: String?
    let issue: DisplayNameValidationIssue?

    var isValid: Bool {
        normalized != nil && issue == nil
    }
}

/// Canonical policy for user-facing application, Space, and template labels.
/// Names are labels, never filesystem identities, so ordinary slash characters
/// and internal Unicode whitespace remain valid. Mutation boundaries persist
/// NFC with Unicode edge whitespace removed. Compatibility folding is used only
/// for reserved-name and collision comparisons; it never rewrites user text.
enum DisplayNameValidator {
    static let maximumUTF8Bytes = 256

    static func validate(
        _ value: String,
        maximumUTF8Bytes: Int = DisplayNameValidator.maximumUTF8Bytes
    ) -> DisplayNameValidation {
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return DisplayNameValidation(
                normalized: nil,
                issue: .empty
            )
        }

        var hasVisibleBase = false
        let scalars = Array(normalized.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                return DisplayNameValidation(
                    normalized: nil,
                    issue: .prohibitedFormatting
                )
            case .format:
                // ZWNJ and ZWJ are meaningful within several writing systems
                // and emoji sequences. All other format controls are invisible
                // or directional and unsafe in a security-sensitive label.
                guard
                    scalar.value == 0x200C || scalar.value == 0x200D,
                    index > scalars.startIndex,
                    index < scalars.index(before: scalars.endIndex)
                else {
                    return DisplayNameValidation(
                        normalized: nil,
                        issue: .prohibitedFormatting
                    )
                }
            case .nonspacingMark, .spacingMark, .enclosingMark:
                break
            default:
                hasVisibleBase = true
            }
        }
        guard hasVisibleBase else {
            return DisplayNameValidation(
                normalized: nil,
                issue: .prohibitedFormatting
            )
        }

        guard normalized.utf8.count <= maximumUTF8Bytes else {
            return DisplayNameValidation(
                normalized: nil,
                issue: .tooLong(
                    maximumUTF8Bytes: maximumUTF8Bytes
                )
            )
        }

        let reservedKey = collisionKey(normalized)
        guard reservedKey != ".", reservedKey != ".." else {
            return DisplayNameValidation(
                normalized: nil,
                issue: .reserved
            )
        }
        return DisplayNameValidation(
            normalized: normalized,
            issue: nil
        )
    }

    static func normalized(
        _ value: String,
        maximumUTF8Bytes: Int = DisplayNameValidator.maximumUTF8Bytes
    ) -> String? {
        validate(
            value,
            maximumUTF8Bytes: maximumUTF8Bytes
        ).normalized
    }

    /// A comparison-only key for collision warnings. Cross-script homoglyphs
    /// remain valid because display names do not grant authority or select
    /// storage; callers must never use this key as a persisted display value.
    static func collisionKey(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(
                options: [
                    .caseInsensitive,
                    .diacriticInsensitive,
                    .widthInsensitive,
                ],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
