import Foundation

/// Reads untyped JSON fields without coercion and appends schema issues in the
/// exact order requested by the raw schema phase.
struct LibraryImportRawFieldReader {
    func requiredString(
        _ value: Any?,
        path: String,
        maximumUTF8Bytes: Int,
        allowEmpty: Bool,
        issues: inout [LibraryImportIssue]
    ) -> String? {
        guard let value else {
            issues.append(
                LibraryImportIssueFactory.make(
                    .missingRequiredField,
                    path: path,
                    detail: "This field is required."
                )
            )
            return nil
        }
        guard let string = value as? String else {
            issues.append(
                LibraryImportIssueFactory.make(
                    .invalidFieldType,
                    path: path,
                    detail: "This field must be text."
                )
            )
            return nil
        }
        if !allowEmpty,
           string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            issues.append(
                LibraryImportIssueFactory.make(
                    .emptyRequiredString,
                    path: path,
                    detail: "This field cannot be blank."
                )
            )
        }
        appendStringLimitIssue(
            string,
            path: path,
            maximumUTF8Bytes: maximumUTF8Bytes,
            issues: &issues
        )
        return string
    }

    func optionalString(
        _ value: Any?,
        path: String,
        maximumUTF8Bytes: Int,
        issues: inout [LibraryImportIssue]
    ) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else {
            issues.append(
                LibraryImportIssueFactory.make(
                    .invalidFieldType,
                    path: path,
                    detail: "This optional field must be text or null."
                )
            )
            return nil
        }
        appendStringLimitIssue(
            string,
            path: path,
            maximumUTF8Bytes: maximumUTF8Bytes,
            issues: &issues
        )
        return string
    }

    func appendStringLimitIssue(
        _ string: String,
        path: String,
        maximumUTF8Bytes: Int,
        issues: inout [LibraryImportIssue]
    ) {
        if string.utf8.count > maximumUTF8Bytes {
            issues.append(
                LibraryImportIssueFactory.make(
                    .stringTooLong,
                    path: path,
                    detail: "This text exceeds the import field-size limit."
                )
            )
        }
    }

    func array(
        _ value: Any?,
        path: String,
        required: Bool,
        issues: inout [LibraryImportIssue]
    ) -> [Any]? {
        guard let value else {
            if required {
                issues.append(
                    LibraryImportIssueFactory.make(
                        .missingRequiredField,
                        path: path,
                        detail: "This collection is required."
                    )
                )
            }
            return nil
        }
        guard let array = value as? [Any] else {
            issues.append(
                LibraryImportIssueFactory.make(
                    .invalidFieldType,
                    path: path,
                    detail: "This field must be an array."
                )
            )
            return nil
        }
        return array
    }
}
