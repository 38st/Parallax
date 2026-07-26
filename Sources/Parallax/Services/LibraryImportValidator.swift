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

    var isValid: Bool {
        !issues.contains { $0.severity == .error } && document != nil
    }
}

struct LibraryImportValidator: Sendable {
    private enum IdentityRole: String, Hashable {
        case applicationID
        case applicationStorageID
        case profileID
        case profileStorageID
    }

    private struct IdentityOccurrence {
        let role: IdentityRole
        let path: String
    }

    private let limits: LibraryImportLimits

    init(limits: LibraryImportLimits = LibraryImportLimits()) {
        self.limits = limits
    }

    func validate(_ data: Data) -> LibraryImportValidationReport {
        guard data.count <= limits.maximumBytes else {
            return LibraryImportValidationReport(
                document: nil,
                issues: [
                    issue(
                        .inputTooLarge,
                        path: "$",
                        detail: "The selected file exceeds the import byte limit."
                    )
                ]
            )
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            return LibraryImportValidationReport(
                document: nil,
                issues: [
                    issue(
                        .malformedJSON,
                        path: "$",
                        detail: "The selected file is not valid JSON."
                    )
                ]
            )
        }

        guard let dictionary = object as? [String: Any] else {
            return LibraryImportValidationReport(
                document: nil,
                issues: [
                    issue(
                        .invalidTopLevel,
                        path: "$",
                        detail: "Import requires a versioned library document."
                    )
                ]
            )
        }

        var issues: [LibraryImportIssue] = []
        validateVersion(in: dictionary, issues: &issues)
        validateRevision(in: dictionary, issues: &issues)

        var identities: [UUID: [IdentityOccurrence]] = [:]
        if let applications = array(
            dictionary["applications"],
            path: "$.applications",
            required: true,
            issues: &issues
        ) {
            validateApplications(
                applications,
                identities: &identities,
                issues: &issues
            )
        }
        appendCrossRoleIdentityIssues(
            identities,
            issues: &issues
        )

        let decodedDocument: LibraryDocument?
        do {
            decodedDocument = try JSONDecoder().decode(
                LibraryDocument.self,
                from: data
            )
        } catch {
            decodedDocument = nil
            issues.append(
                issue(
                    .decodingFailed,
                    path: "$",
                    detail: "One or more fields cannot be decoded as a current Parallax library."
                )
            )
        }

        let hasErrors = issues.contains { $0.severity == .error }
        return LibraryImportValidationReport(
            document: hasErrors ? nil : decodedDocument,
            issues: issues
        )
    }

    private func validateVersion(
        in dictionary: [String: Any],
        issues: inout [LibraryImportIssue]
    ) {
        guard let rawVersion = dictionary["version"] else {
            issues.append(
                issue(
                    .missingRequiredField,
                    path: "$.version",
                    detail: "The library version is required."
                )
            )
            return
        }
        guard let version = rawVersion as? Int else {
            issues.append(
                issue(
                    .invalidFieldType,
                    path: "$.version",
                    detail: "The library version must be an integer."
                )
            )
            return
        }
        guard version > 0 else {
            issues.append(
                issue(
                    .invalidVersion,
                    path: "$.version",
                    detail: "The library version must be positive."
                )
            )
            return
        }
        guard version <= LibraryDocument.currentVersion else {
            issues.append(
                issue(
                    .unsupportedVersion,
                    path: "$.version",
                    detail: "This library was written by a newer Parallax version."
                )
            )
            return
        }
        if version != LibraryDocument.currentVersion {
            issues.append(
                issue(
                    .invalidVersion,
                    path: "$.version",
                    detail: "Import accepts only the current library format."
                )
            )
        }
    }

    private func validateRevision(
        in dictionary: [String: Any],
        issues: inout [LibraryImportIssue]
    ) {
        guard let rawRevision = dictionary["revision"] else { return }
        guard
            let number = rawRevision as? NSNumber,
            !isBoolean(number),
            number.int64Value >= 0,
            number.doubleValue.rounded(.towardZero) == number.doubleValue
        else {
            issues.append(
                issue(
                    .invalidFieldValue,
                    path: "$.revision",
                    detail: "The library revision must be a nonnegative integer."
                )
            )
            return
        }
    }

    private func validateApplications(
        _ rawApplications: [Any],
        identities: inout [UUID: [IdentityOccurrence]],
        issues: inout [LibraryImportIssue]
    ) {
        if rawApplications.count > limits.maximumApplications {
            issues.append(
                issue(
                    .tooManyApplications,
                    path: "$.applications",
                    detail: "The import contains too many applications."
                )
            )
        }

        var applicationIDs = Set<UUID>()
        var applicationStorageIDs = Set<UUID>()
        var normalizedNames: [String: String] = [:]
        var totalProfiles = 0

        for (applicationIndex, rawApplication) in rawApplications.enumerated() {
            let path = "$.applications[\(applicationIndex)]"
            guard let application = rawApplication as? [String: Any] else {
                issues.append(
                    issue(
                        .invalidFieldType,
                        path: path,
                        detail: "Each application must be an object."
                    )
                )
                continue
            }

            validateIdentity(
                application["id"],
                path: "\(path).id",
                role: .applicationID,
                duplicateCode: .duplicateApplicationID,
                requireCanonicalStorageForm: false,
                seen: &applicationIDs,
                identities: &identities,
                issues: &issues
            )
            validateIdentity(
                application["storageID"],
                path: "\(path).storageID",
                role: .applicationStorageID,
                duplicateCode: .duplicateApplicationStorageID,
                requireCanonicalStorageForm: true,
                seen: &applicationStorageIDs,
                identities: &identities,
                issues: &issues
            )

            if let displayName = requiredString(
                application["displayName"],
                path: "\(path).displayName",
                maximumUTF8Bytes: limits.maximumNameUTF8Bytes,
                allowEmpty: false,
                issues: &issues
            ) {
                appendNameCollision(
                    displayName,
                    path: "\(path).displayName",
                    priorNames: &normalizedNames,
                    issues: &issues
                )
            }

            if let bundleIdentifier = optionalString(
                application["bundleIdentifier"],
                path: "\(path).bundleIdentifier",
                maximumUTF8Bytes: limits.maximumBundleIdentifierUTF8Bytes,
                issues: &issues
            ), bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(
                    issue(
                        .emptyRequiredString,
                        path: "\(path).bundleIdentifier",
                        detail: "A present bundle identifier cannot be blank."
                    )
                )
            }

            if let appPath = requiredString(
                application["appPath"],
                path: "\(path).appPath",
                maximumUTF8Bytes: limits.maximumPathUTF8Bytes,
                allowEmpty: false,
                issues: &issues
            ), !isCanonicalAbsolutePath(appPath, requireAppExtension: true) {
                issues.append(
                    issue(
                        .invalidApplicationPath,
                        path: "\(path).appPath",
                        detail: "Application paths must be canonical absolute .app paths."
                    )
                )
            }

            if let basePath = optionalString(
                application["baseStoragePath"],
                path: "\(path).baseStoragePath",
                maximumUTF8Bytes: limits.maximumPathUTF8Bytes,
                issues: &issues
            ), !isCanonicalAbsolutePath(basePath, requireAppExtension: false) {
                issues.append(
                    issue(
                        .invalidBaseStoragePath,
                        path: "\(path).baseStoragePath",
                        detail: "Configured storage roots must be canonical absolute paths."
                    )
                )
            }

            validatePreset(
                application["preset"],
                path: "\(path).preset",
                issues: &issues
            )

            if application["storageName"] != nil {
                issues.append(
                    issue(
                        .forbiddenLegacyStorageName,
                        path: "\(path).storageName",
                        detail: "Visible or legacy storage names cannot define v2 storage identity."
                    )
                )
            }

            guard let profiles = array(
                application["profiles"],
                path: "\(path).profiles",
                required: true,
                issues: &issues
            ) else {
                continue
            }
            totalProfiles += profiles.count
            if profiles.count > limits.maximumProfilesPerApplication {
                issues.append(
                    issue(
                        .tooManyProfiles,
                        path: "\(path).profiles",
                        detail: "An application contains too many profiles."
                    )
                )
            }
            validateProfiles(
                profiles,
                applicationPath: path,
                identities: &identities,
                issues: &issues
            )
        }

        if totalProfiles > limits.maximumProfilesTotal {
            issues.append(
                issue(
                    .tooManyProfiles,
                    path: "$.applications",
                    detail: "The import contains too many profiles in total."
                )
            )
        }
    }

    private func validateProfiles(
        _ rawProfiles: [Any],
        applicationPath: String,
        identities: inout [UUID: [IdentityOccurrence]],
        issues: inout [LibraryImportIssue]
    ) {
        var profileIDs = identitiesForRole(.profileID, in: identities)
        var profileStorageIDs = identitiesForRole(
            .profileStorageID,
            in: identities
        )
        var normalizedNames: [String: String] = [:]

        for (profileIndex, rawProfile) in rawProfiles.enumerated() {
            let path = "\(applicationPath).profiles[\(profileIndex)]"
            guard let profile = rawProfile as? [String: Any] else {
                issues.append(
                    issue(
                        .invalidFieldType,
                        path: path,
                        detail: "Each profile must be an object."
                    )
                )
                continue
            }

            validateIdentity(
                profile["id"],
                path: "\(path).id",
                role: .profileID,
                duplicateCode: .duplicateProfileID,
                requireCanonicalStorageForm: false,
                seen: &profileIDs,
                identities: &identities,
                issues: &issues
            )
            validateIdentity(
                profile["storageID"],
                path: "\(path).storageID",
                role: .profileStorageID,
                duplicateCode: .duplicateProfileStorageID,
                requireCanonicalStorageForm: true,
                seen: &profileStorageIDs,
                identities: &identities,
                issues: &issues
            )

            if let name = requiredString(
                profile["name"],
                path: "\(path).name",
                maximumUTF8Bytes: limits.maximumNameUTF8Bytes,
                allowEmpty: false,
                issues: &issues
            ) {
                appendNameCollision(
                    name,
                    path: "\(path).name",
                    priorNames: &normalizedNames,
                    issues: &issues
                )
            }

            let argumentsText = requiredString(
                profile["argumentsText"],
                path: "\(path).argumentsText",
                maximumUTF8Bytes: limits.maximumTextUTF8Bytes,
                allowEmpty: true,
                issues: &issues
            )
            let environmentText = requiredString(
                profile["environmentText"],
                path: "\(path).environmentText",
                maximumUTF8Bytes: limits.maximumTextUTF8Bytes,
                allowEmpty: true,
                issues: &issues
            )
            _ = requiredString(
                profile["notes"],
                path: "\(path).notes",
                maximumUTF8Bytes: limits.maximumTextUTF8Bytes,
                allowEmpty: true,
                issues: &issues
            )

            if profile["storageName"] != nil {
                issues.append(
                    issue(
                        .forbiddenLegacyStorageName,
                        path: "\(path).storageName",
                        detail: "Legacy storageName cannot enter a v2 import."
                    )
                )
            }

            if let argumentsText {
                validateArguments(
                    argumentsText,
                    path: "\(path).argumentsText",
                    issues: &issues
                )
            }
            if let environmentText {
                validateEnvironment(
                    environmentText,
                    path: "\(path).environmentText",
                    issues: &issues
                )
            }

            validateOptionalProfileEnums(
                profile,
                path: path,
                issues: &issues
            )
            validateIsolationOwnership(
                profile["isolationOwnership"],
                path: "\(path).isolationOwnership",
                issues: &issues
            )
            validateSensitiveEnvironmentKeys(
                profile["sensitiveEnvironmentKeys"],
                path: "\(path).sensitiveEnvironmentKeys",
                issues: &issues
            )
        }
    }

    private func validateArguments(
        _ text: String,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        let parsed = LaunchArgumentParser.parse(text)
        for _ in parsed.diagnostics where parsed.hasErrors {
            issues.append(
                issue(
                    .invalidArguments,
                    path: path,
                    detail: "The launch arguments contain invalid syntax."
                )
            )
        }

        let userData = UserDataDirectoryOptionResolver.resolve(
            in: parsed.tokens
        )
        for _ in userData.diagnostics {
            issues.append(
                issue(
                    .invalidArguments,
                    path: path,
                    detail: "The user data directory option is ambiguous or incomplete."
                )
            )
        }
        if let value = userData.resolvedValue,
           !isCanonicalIsolationPath(value)
        {
            issues.append(
                issue(
                    .invalidIsolationPath,
                    path: path,
                    detail: "The user data directory must be absolute and traversal-free."
                )
            )
        }
    }

    private func validateEnvironment(
        _ text: String,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        let parsed = LaunchEnvironmentParser.parse(text)
        for diagnostic in parsed.diagnostics where diagnostic.severity == .error {
            issues.append(
                issue(
                    .invalidEnvironment,
                    path: path,
                    detail: "The environment contains an invalid line or variable name."
                )
            )
        }
        for entry in parsed.entries {
            guard
                entry.name == "CODEX_HOME",
                case let .set(value) = entry.operation,
                !isCanonicalIsolationPath(value)
            else {
                continue
            }
            issues.append(
                issue(
                    .invalidIsolationPath,
                    path: path,
                    detail: "CODEX_HOME must be absolute and traversal-free."
                )
            )
        }
    }

    private func validateOptionalProfileEnums(
        _ profile: [String: Any],
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        if let policy = profile["childEnvironmentPolicy"],
           !(policy is NSNull)
        {
            guard let value = policy as? String else {
                issues.append(
                    issue(
                        .invalidFieldType,
                        path: "\(path).childEnvironmentPolicy",
                        detail: "The child environment policy must be text."
                    )
                )
                return
            }
            let allowed = Set(ChildEnvironmentPolicy.allCases.map(\.rawValue))
            if !allowed.contains(value) {
                issues.append(
                    issue(
                        .invalidFieldValue,
                        path: "\(path).childEnvironmentPolicy",
                        detail: "The child environment policy is not supported."
                    )
                )
            }
        }
        if let trust = profile["launchConfigurationTrust"],
           !(trust is NSNull)
        {
            validateLaunchConfigurationTrust(
                trust,
                path: "\(path).launchConfigurationTrust",
                issues: &issues
            )
        }
    }

    private func validateIsolationOwnership(
        _ value: Any?,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        guard let value, !(value is NSNull) else { return }
        guard let ownership = value as? [String: Any] else {
            issues.append(
                issue(
                    .invalidFieldType,
                    path: path,
                    detail: "Isolation ownership must be an object."
                )
            )
            return
        }

        let allowed = Set([
            IsolationPathOwnership.generated.rawValue,
            IsolationPathOwnership.explicit.rawValue,
            IsolationPathOwnership.legacyUnknown.rawValue,
        ])
        for key in ["userData", "codexHome"] {
            guard let rawValue = ownership[key] else {
                issues.append(
                    issue(
                        .missingRequiredField,
                        path: "\(path).\(key)",
                        detail: "Isolation ownership requires both path authorities."
                    )
                )
                continue
            }
            guard let string = rawValue as? String else {
                issues.append(
                    issue(
                        .invalidFieldType,
                        path: "\(path).\(key)",
                        detail: "Isolation ownership authority must be text."
                    )
                )
                continue
            }
            if !allowed.contains(string) {
                issues.append(
                    issue(
                        .invalidFieldValue,
                        path: "\(path).\(key)",
                        detail: "The isolation ownership authority is not supported."
                    )
                )
            }
        }
    }

    private func validateSensitiveEnvironmentKeys(
        _ value: Any?,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        guard let value, !(value is NSNull) else { return }
        guard let keys = value as? [Any] else {
            issues.append(
                issue(
                    .invalidFieldType,
                    path: path,
                    detail: "Sensitive environment keys must be an array."
                )
            )
            return
        }
        if keys.count > limits.maximumSensitiveEnvironmentKeys {
            issues.append(
                issue(
                    .tooManySensitiveEnvironmentKeys,
                    path: path,
                    detail: "The profile contains too many sensitive environment keys."
                )
            )
        }
        for (index, rawKey) in keys.enumerated() {
            let keyPath = "\(path)[\(index)]"
            guard let key = rawKey as? String else {
                issues.append(
                    issue(
                        .invalidFieldType,
                        path: keyPath,
                        detail: "Each sensitive environment key must be text."
                    )
                )
                continue
            }
            appendStringLimitIssue(
                key,
                path: keyPath,
                maximumUTF8Bytes: limits.maximumNameUTF8Bytes,
                issues: &issues
            )
            if !isValidEnvironmentKey(key) {
                issues.append(
                    issue(
                        .invalidFieldValue,
                        path: keyPath,
                        detail: "A sensitive environment key is not a valid variable name."
                    )
                )
            }
        }
    }

    private func isValidEnvironmentKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first else { return false }
        let isLetter: (Unicode.Scalar) -> Bool = {
            (65...90).contains($0.value) || (97...122).contains($0.value)
        }
        guard isLetter(first) || first.value == 95 else { return false }
        return key.unicodeScalars.dropFirst().allSatisfy {
            isLetter($0) || (48...57).contains($0.value) || $0.value == 95
        }
    }

    private func validateLaunchConfigurationTrust(
        _ value: Any,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        if let legacyState = value as? String {
            guard
                legacyState == "local"
                    || legacyState == "importedPendingReview"
            else {
                issues.append(
                    issue(
                        .invalidFieldValue,
                        path: path,
                        detail: "The launch configuration trust state is not supported."
                    )
                )
                return
            }
            return
        }

        guard let object = value as? [String: Any] else {
            issues.append(
                issue(
                    .invalidFieldType,
                    path: path,
                    detail: "Launch configuration trust must be a legacy state or an approval object."
                )
            )
            return
        }
        guard let state = object["state"] as? String else {
            issues.append(
                issue(
                    .missingRequiredField,
                    path: "\(path).state",
                    detail: "The launch configuration trust object requires a state."
                )
            )
            return
        }

        switch state {
        case "local", "importedPendingReview":
            return
        case "importedApproved":
            validateImportedLaunchApproval(
                object["approval"],
                path: "\(path).approval",
                issues: &issues
            )
        default:
            issues.append(
                issue(
                    .invalidFieldValue,
                    path: "\(path).state",
                    detail: "The launch configuration trust state is not supported."
                )
            )
        }
    }

    private func validateImportedLaunchApproval(
        _ value: Any?,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        guard let approval = value as? [String: Any] else {
            issues.append(
                issue(
                    value == nil ? .missingRequiredField : .invalidFieldType,
                    path: path,
                    detail: "Imported approval details are required for approved launch configuration trust."
                )
            )
            return
        }

        if let fingerprint = approval["configurationFingerprint"]
            as? [String: Any]
        {
            guard let sha256 = fingerprint["sha256"] as? String else {
                issues.append(
                    issue(
                        .missingRequiredField,
                        path: "\(path).configurationFingerprint.sha256",
                        detail: "Imported approval requires a configuration fingerprint."
                    )
                )
                validateApprovalDate(
                    approval["approvedAt"],
                    path: "\(path).approvedAt",
                    issues: &issues
                )
                return
            }
            let isSHA256 = sha256.utf8.count == 64
                && sha256.unicodeScalars.allSatisfy {
                    ("0"..."9").contains(Character(String($0)))
                        || ("a"..."f").contains(Character(String($0)))
                }
            if !isSHA256 {
                issues.append(
                    issue(
                        .invalidFieldValue,
                        path: "\(path).configurationFingerprint.sha256",
                        detail: "The imported approval fingerprint must be a lowercase SHA-256 value."
                    )
                )
            }
        } else {
            issues.append(
                issue(
                    approval["configurationFingerprint"] == nil
                        ? .missingRequiredField
                        : .invalidFieldType,
                    path: "\(path).configurationFingerprint",
                    detail: "Imported approval requires a configuration fingerprint object."
                )
            )
        }

        validateApprovalDate(
            approval["approvedAt"],
            path: "\(path).approvedAt",
            issues: &issues
        )
    }

    private func validateApprovalDate(
        _ value: Any?,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        guard let value else {
            issues.append(
                issue(
                    .missingRequiredField,
                    path: path,
                    detail: "Imported approval requires an approval date."
                )
            )
            return
        }
        guard
            let number = value as? NSNumber,
            !isBoolean(number),
            number.doubleValue.isFinite
        else {
            issues.append(
                issue(
                    .invalidFieldType,
                    path: path,
                    detail: "The imported approval date must use the encoded date representation."
                )
            )
            return
        }
    }

    private func validatePreset(
        _ value: Any?,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        guard let value else {
            issues.append(
                issue(
                    .missingRequiredField,
                    path: path,
                    detail: "Every imported application requires a preset."
                )
            )
            return
        }
        guard
            let rawValue = value as? String,
            AppPreset(rawValue: rawValue) != nil
        else {
            issues.append(
                issue(
                    .invalidPreset,
                    path: path,
                    detail: "The application preset is not supported."
                )
            )
            return
        }
    }

    private func validateIdentity(
        _ value: Any?,
        path: String,
        role: IdentityRole,
        duplicateCode: LibraryImportIssueCode,
        requireCanonicalStorageForm: Bool,
        seen: inout Set<UUID>,
        identities: inout [UUID: [IdentityOccurrence]],
        issues: inout [LibraryImportIssue]
    ) {
        guard let value else {
            issues.append(
                issue(
                    .missingRequiredField,
                    path: path,
                    detail: "Every imported record requires an identity."
                )
            )
            return
        }
        guard let string = value as? String, let uuid = UUID(uuidString: string) else {
            issues.append(
                issue(
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
                issue(
                    .invalidStorageIdentity,
                    path: path,
                    detail: "Storage identity must use canonical lowercase UUID form."
                )
            )
        }
        if !seen.insert(uuid).inserted {
            issues.append(
                issue(
                    duplicateCode,
                    path: path,
                    detail: "This identity is reused by another imported record."
                )
            )
        }
        identities[uuid, default: []].append(
            IdentityOccurrence(role: role, path: path)
        )
    }

    private func appendCrossRoleIdentityIssues(
        _ identities: [UUID: [IdentityOccurrence]],
        issues: inout [LibraryImportIssue]
    ) {
        for occurrences in identities.values {
            let roles = Set(occurrences.map(\.role))
            guard roles.count > 1 else { continue }
            for occurrence in occurrences {
                issues.append(
                    issue(
                        .crossTypeIdentityReuse,
                        path: occurrence.path,
                        detail: "One UUID cannot be reused across logical or storage identity roles."
                    )
                )
            }
        }
    }

    private func appendNameCollision(
        _ name: String,
        path: String,
        priorNames: inout [String: String],
        issues: inout [LibraryImportIssue]
    ) {
        let normalized = name
            .precomposedStringWithCompatibilityMapping
            .lowercased()
        if priorNames[normalized] != nil {
            issues.append(
                issue(
                    .normalizedNameCollision,
                    severity: .warning,
                    path: path,
                    detail: "This name collides with another imported name after normalization."
                )
            )
        } else {
            priorNames[normalized] = path
        }
    }

    private func requiredString(
        _ value: Any?,
        path: String,
        maximumUTF8Bytes: Int,
        allowEmpty: Bool,
        issues: inout [LibraryImportIssue]
    ) -> String? {
        guard let value else {
            issues.append(
                issue(
                    .missingRequiredField,
                    path: path,
                    detail: "This field is required."
                )
            )
            return nil
        }
        guard let string = value as? String else {
            issues.append(
                issue(
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
                issue(
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

    private func optionalString(
        _ value: Any?,
        path: String,
        maximumUTF8Bytes: Int,
        issues: inout [LibraryImportIssue]
    ) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let string = value as? String else {
            issues.append(
                issue(
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

    private func appendStringLimitIssue(
        _ string: String,
        path: String,
        maximumUTF8Bytes: Int,
        issues: inout [LibraryImportIssue]
    ) {
        if string.utf8.count > maximumUTF8Bytes {
            issues.append(
                issue(
                    .stringTooLong,
                    path: path,
                    detail: "This text exceeds the import field-size limit."
                )
            )
        }
    }

    private func array(
        _ value: Any?,
        path: String,
        required: Bool,
        issues: inout [LibraryImportIssue]
    ) -> [Any]? {
        guard let value else {
            if required {
                issues.append(
                    issue(
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
                issue(
                    .invalidFieldType,
                    path: path,
                    detail: "This field must be an array."
                )
            )
            return nil
        }
        return array
    }

    private func isCanonicalAbsolutePath(
        _ path: String,
        requireAppExtension: Bool
    ) -> Bool {
        guard
            !path.isEmpty,
            !path.contains("\0"),
            (path as NSString).isAbsolutePath,
            !hasUnsafeRawPathComponent(path)
        else {
            return false
        }
        let standardized = URL(
            fileURLWithPath: path,
            isDirectory: !requireAppExtension
        ).standardizedFileURL.path
        guard standardized == path else { return false }
        return !requireAppExtension
            || URL(fileURLWithPath: path).pathExtension.lowercased() == "app"
    }

    private func isCanonicalIsolationPath(_ path: String) -> Bool {
        if path == "~" {
            return true
        }
        if path.hasPrefix("~/") {
            let remainder = String(path.dropFirst(2))
            return !remainder.isEmpty
                && !hasUnsafeRawPathComponent("/\(remainder)")
        }
        return isCanonicalAbsolutePath(path, requireAppExtension: false)
    }

    private func hasUnsafeRawPathComponent(_ path: String) -> Bool {
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.first == "" else { return true }
        return components.dropFirst().contains {
            $0.isEmpty || $0 == "." || $0 == ".."
        }
    }

    private func identitiesForRole(
        _ role: IdentityRole,
        in identities: [UUID: [IdentityOccurrence]]
    ) -> Set<UUID> {
        Set(
            identities.compactMap { id, occurrences in
                occurrences.contains { $0.role == role } ? id : nil
            }
        )
    }

    private func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func issue(
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
