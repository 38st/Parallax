import Foundation

/// Validates the versioned document root while preserving NSNumber/Bool
/// distinctions from JSONSerialization.
struct LibraryImportRootSchemaValidator {
    func validateVersion(
        in dictionary: [String: Any],
        issues: inout [LibraryImportIssue]
    ) {
        guard let rawVersion = dictionary["version"] else {
            issue(
                .missingRequiredField,
                path: "$.version",
                detail: "The library version is required.",
                to: &issues
            )
            return
        }
        guard let number = rawVersion as? NSNumber,
              !isBoolean(number),
              let version = rawVersion as? Int
        else {
            issue(
                .invalidFieldType,
                path: "$.version",
                detail: "The library version must be an integer.",
                to: &issues
            )
            return
        }
        guard version > 0 else {
            issue(
                .invalidVersion,
                path: "$.version",
                detail: "The library version must be positive.",
                to: &issues
            )
            return
        }
        guard version <= LibraryDocument.currentVersion else {
            issue(
                .unsupportedVersion,
                path: "$.version",
                detail: "This library was written by a newer Parallax version.",
                to: &issues
            )
            return
        }
        if version != LibraryDocument.currentVersion {
            issue(
                .invalidVersion,
                path: "$.version",
                detail: "Import accepts only the current library format.",
                to: &issues
            )
        }
    }

    func validateRevision(
        in dictionary: [String: Any],
        issues: inout [LibraryImportIssue]
    ) {
        guard let rawRevision = dictionary["revision"] else { return }
        guard let number = rawRevision as? NSNumber,
              !isBoolean(number),
              number.int64Value >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue
        else {
            issue(
                .invalidFieldValue,
                path: "$.revision",
                detail: "The library revision must be a nonnegative integer.",
                to: &issues
            )
            return
        }
    }

    private func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func issue(
        _ code: LibraryImportIssueCode,
        path: String,
        detail: String.LocalizationValue,
        to issues: inout [LibraryImportIssue]
    ) {
        issues.append(
            LibraryImportIssueFactory.make(
                code,
                path: path,
                detail: detail
            )
        )
    }
}
