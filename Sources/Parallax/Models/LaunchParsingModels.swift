import Foundation

struct LaunchSourceLocation: Sendable, Equatable, Hashable {
    let utf16Offset: Int
    let line: Int
    let column: Int
}

struct LaunchSourceRange: Sendable, Equatable, Hashable {
    let start: LaunchSourceLocation
    let end: LaunchSourceLocation
}

enum LaunchDiagnosticSeverity: String, Sendable, Equatable {
    case error
    case warning
}

enum LaunchDiagnosticSource: String, Sendable, Equatable {
    case arguments
    case environment
}

enum LaunchParsingDiagnosticCode: String, Sendable, Equatable {
    case unmatchedSingleQuote
    case unmatchedDoubleQuote
    case trailingEscape
    case unsupportedControlCharacter
    case blankUserDataDirectory
    case missingUserDataDirectory
    case duplicateUserDataDirectory
    case invalidEnvironmentName
    case malformedEnvironmentLine
    case duplicateEnvironmentName
}

struct LaunchParsingDiagnostic: Sendable, Equatable {
    let code: LaunchParsingDiagnosticCode
    let severity: LaunchDiagnosticSeverity
    let source: LaunchDiagnosticSource
    let range: LaunchSourceRange
    let relatedRange: LaunchSourceRange?

    init(
        code: LaunchParsingDiagnosticCode,
        severity: LaunchDiagnosticSeverity = .error,
        source: LaunchDiagnosticSource,
        range: LaunchSourceRange,
        relatedRange: LaunchSourceRange? = nil
    ) {
        self.code = code
        self.severity = severity
        self.source = source
        self.range = range
        self.relatedRange = relatedRange
    }

    var message: String {
        switch code {
        case .unmatchedSingleQuote:
            String(localized: "The launch arguments contain an unmatched single quote.")
        case .unmatchedDoubleQuote:
            String(localized: "The launch arguments contain an unmatched double quote.")
        case .trailingEscape:
            String(localized: "The launch arguments end with an incomplete escape.")
        case .unsupportedControlCharacter:
            String(localized: "The launch configuration contains an unsupported control character.")
        case .blankUserDataDirectory:
            String(localized: "The user data directory option cannot be blank.")
        case .missingUserDataDirectory:
            String(localized: "The user data directory option requires a path.")
        case .duplicateUserDataDirectory:
            String(localized: "Specify the user data directory option only once.")
        case .invalidEnvironmentName:
            String(localized: "Environment variable names must use letters, numbers, and underscores, and cannot start with a number.")
        case .malformedEnvironmentLine:
            String(localized: "Use KEY=value or unset KEY for each environment line.")
        case .duplicateEnvironmentName:
            String(localized: "This environment variable is configured more than once; the last entry takes precedence.")
        }
    }
}
