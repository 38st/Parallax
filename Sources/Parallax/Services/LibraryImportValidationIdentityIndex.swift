import Foundation

enum LibraryImportValidationIdentityRole: String, Hashable {
    case applicationID
    case applicationStorageID
    case profileID
    case profileStorageID
}

struct LibraryImportValidationIdentityIndex {
    private struct Occurrence {
        let role: LibraryImportValidationIdentityRole
        let path: String
    }

    private var occurrencesByIdentity: [UUID: [Occurrence]] = [:]

    mutating func validate(
        _ value: Any?,
        path: String,
        role: LibraryImportValidationIdentityRole,
        duplicateCode: LibraryImportIssueCode,
        requireCanonicalStorageForm: Bool,
        seen: inout Set<UUID>,
        issues: inout [LibraryImportIssue]
    ) {
        guard let value else {
            issues.append(
                LibraryImportIssueFactory.make(
                    .missingRequiredField,
                    path: path,
                    detail: "Every imported record requires an identity."
                )
            )
            return
        }
        guard let string = value as? String,
              let uuid = UUID(uuidString: string)
        else {
            issues.append(
                LibraryImportIssueFactory.make(
                    requireCanonicalStorageForm
                        ? .invalidStorageIdentity
                        : .invalidLogicalIdentity,
                    path: path,
                    detail: "The identity must be a UUID."
                )
            )
            return
        }
        if requireCanonicalStorageForm,
           string != uuid.uuidString.lowercased()
        {
            issues.append(
                LibraryImportIssueFactory.make(
                    .invalidStorageIdentity,
                    path: path,
                    detail: "Storage identity must use canonical lowercase UUID form."
                )
            )
        }
        if !seen.insert(uuid).inserted {
            issues.append(
                LibraryImportIssueFactory.make(
                    duplicateCode,
                    path: path,
                    detail: "This identity is reused by another imported record."
                )
            )
        }
        occurrencesByIdentity[uuid, default: []].append(
            Occurrence(role: role, path: path)
        )
    }

    func identities(for role: LibraryImportValidationIdentityRole) -> Set<UUID> {
        Set(
            occurrencesByIdentity.compactMap { id, occurrences in
                occurrences.contains { $0.role == role } ? id : nil
            }
        )
    }

    func appendCrossRoleIssues(to issues: inout [LibraryImportIssue]) {
        for occurrences in occurrencesByIdentity.values {
            let roles = Set(occurrences.map(\.role))
            guard roles.count > 1 else { continue }
            for occurrence in occurrences {
                issues.append(
                    LibraryImportIssueFactory.make(
                        .crossTypeIdentityReuse,
                        path: occurrence.path,
                        detail: "One UUID cannot be reused across logical or storage identity roles."
                    )
                )
            }
        }
    }
}
