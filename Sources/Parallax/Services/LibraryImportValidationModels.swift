import Foundation

struct LibraryImportLimits: Sendable, Equatable {
    var maximumBytes: Int
    var maximumApplications: Int
    var maximumProfilesPerApplication: Int
    var maximumProfilesTotal: Int
    var maximumNameUTF8Bytes: Int
    var maximumBundleIdentifierUTF8Bytes: Int
    var maximumPathUTF8Bytes: Int
    var maximumTextUTF8Bytes: Int
    var maximumSensitiveEnvironmentKeys: Int

    init(
        maximumBytes: Int = 4 * 1_024 * 1_024,
        maximumApplications: Int = 256,
        maximumProfilesPerApplication: Int = 512,
        maximumProfilesTotal: Int = 4_096,
        maximumNameUTF8Bytes: Int = 256,
        maximumBundleIdentifierUTF8Bytes: Int = 512,
        maximumPathUTF8Bytes: Int = 4_096,
        maximumTextUTF8Bytes: Int = 64 * 1_024,
        maximumSensitiveEnvironmentKeys: Int = 256
    ) {
        self.maximumBytes = maximumBytes
        self.maximumApplications = maximumApplications
        self.maximumProfilesPerApplication = maximumProfilesPerApplication
        self.maximumProfilesTotal = maximumProfilesTotal
        self.maximumNameUTF8Bytes = maximumNameUTF8Bytes
        self.maximumBundleIdentifierUTF8Bytes = maximumBundleIdentifierUTF8Bytes
        self.maximumPathUTF8Bytes = maximumPathUTF8Bytes
        self.maximumTextUTF8Bytes = maximumTextUTF8Bytes
        self.maximumSensitiveEnvironmentKeys = maximumSensitiveEnvironmentKeys
    }
}

enum LibraryImportIssueSeverity: String, Sendable, Equatable {
    case error
    case warning
}

enum LibraryImportIssueCode: String, Sendable, Equatable, Hashable {
    case inputTooLarge
    case malformedJSON
    case duplicateJSONKey
    case invalidTopLevel
    case missingRequiredField
    case invalidFieldType
    case invalidFieldValue
    case invalidVersion
    case unsupportedVersion
    case tooManyApplications
    case tooManyProfiles
    case stringTooLong
    case emptyRequiredString
    case invalidDisplayName
    case normalizedDisplayName
    case invalidLogicalIdentity
    case invalidStorageIdentity
    case duplicateApplicationID
    case duplicateApplicationStorageID
    case duplicateProfileID
    case duplicateProfileStorageID
    case crossTypeIdentityReuse
    case invalidApplicationPath
    case invalidBaseStoragePath
    case invalidIsolationPath
    case forbiddenLegacyStorageName
    case invalidPreset
    case normalizedNameCollision
    case invalidArguments
    case invalidEnvironment
    case tooManySensitiveEnvironmentKeys
    case decodingFailed
}

struct LibraryImportIssue: Sendable, Equatable {
    let code: LibraryImportIssueCode
    let severity: LibraryImportIssueSeverity
    let path: String
    let message: String
}

struct LibraryImportValidationReport: Sendable {
    let document: LibraryDocument?
    let issues: [LibraryImportIssue]

    var presentationMessages: [String] {
        // Bound both the number of diagnostics and untrusted field paths.
        let limit = 20
        let orderedIssues = issues.filter { $0.severity == .error }
            + issues.filter { $0.severity == .warning }
        var messages = orderedIssues.prefix(limit).map {
            "\(String($0.path.prefix(160))): \(String($0.message.prefix(200)))"
        }
        if issues.count > limit {
            messages.append(String(localized: "Additional validation issues were omitted from this summary."))
        }
        return messages
    }

    var isValid: Bool {
        !issues.contains { $0.severity == .error } && document != nil
    }
}
