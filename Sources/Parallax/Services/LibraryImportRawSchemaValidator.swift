import Foundation

struct LibraryImportRawSchemaValidator: Sendable {
    private let limits: LibraryImportLimits

    private var fields: LibraryImportRawFieldReader {
        LibraryImportRawFieldReader()
    }

    private var launchSecurity: LibraryImportLaunchSecurityValidator {
        LibraryImportLaunchSecurityValidator(limits: limits)
    }

    init(limits: LibraryImportLimits = LibraryImportLimits()) {
        self.limits = limits
    }

    func validate(_ dictionary: [String: Any]) -> [LibraryImportIssue] {
        var issues: [LibraryImportIssue] = []
        let rootSchema = LibraryImportRootSchemaValidator()
        rootSchema.validateVersion(in: dictionary, issues: &issues)
        rootSchema.validateRevision(in: dictionary, issues: &issues)

        var identities = LibraryImportValidationIdentityIndex()
        if let applications = fields.array(
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
        identities.appendCrossRoleIssues(to: &issues)

        return issues
    }

    private func validateApplications(
        _ rawApplications: [Any],
        identities: inout LibraryImportValidationIdentityIndex,
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

            identities.validate(
                application["id"],
                path: "\(path).id",
                role: .applicationID,
                duplicateCode: .duplicateApplicationID,
                requireCanonicalStorageForm: false,
                seen: &applicationIDs,
                issues: &issues
            )
            identities.validate(
                application["storageID"],
                path: "\(path).storageID",
                role: .applicationStorageID,
                duplicateCode: .duplicateApplicationStorageID,
                requireCanonicalStorageForm: true,
                seen: &applicationStorageIDs,
                issues: &issues
            )

            if let displayName = fields.requiredString(
                application["displayName"],
                path: "\(path).displayName",
                // The document's total byte limit already bounds raw input.
                // Display-name limits apply after canonical NFC below.
                maximumUTF8Bytes: limits.maximumBytes,
                allowEmpty: false,
                issues: &issues
            ) {
                if appendDisplayNameIssues(
                    displayName,
                    subject: .application,
                    path: "\(path).displayName",
                    issues: &issues
                ) {
                    appendNameCollision(
                        displayName,
                        path: "\(path).displayName",
                        priorNames: &normalizedNames,
                        issues: &issues
                    )
                }
            }

            if let bundleIdentifier = fields.optionalString(
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

            if let appPath = fields.requiredString(
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

            if let basePath = fields.optionalString(
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

            guard let profiles = fields.array(
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
        identities: inout LibraryImportValidationIdentityIndex,
        issues: inout [LibraryImportIssue]
    ) {
        var profileIDs = identities.identities(for: .profileID)
        var profileStorageIDs = identities.identities(for: .profileStorageID)
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

            identities.validate(
                profile["id"],
                path: "\(path).id",
                role: .profileID,
                duplicateCode: .duplicateProfileID,
                requireCanonicalStorageForm: false,
                seen: &profileIDs,
                issues: &issues
            )
            identities.validate(
                profile["storageID"],
                path: "\(path).storageID",
                role: .profileStorageID,
                duplicateCode: .duplicateProfileStorageID,
                requireCanonicalStorageForm: true,
                seen: &profileStorageIDs,
                issues: &issues
            )

            if let name = fields.requiredString(
                profile["name"],
                path: "\(path).name",
                // Decomposed Unicode may be larger before canonical NFC.
                maximumUTF8Bytes: limits.maximumBytes,
                allowEmpty: false,
                issues: &issues
            ) {
                if appendDisplayNameIssues(
                    name,
                    subject: .space,
                    path: "\(path).name",
                    issues: &issues
                ) {
                    appendNameCollision(
                        name,
                        path: "\(path).name",
                        priorNames: &normalizedNames,
                        issues: &issues
                    )
                }
            }

            let argumentsText = fields.requiredString(
                profile["argumentsText"],
                path: "\(path).argumentsText",
                maximumUTF8Bytes: limits.maximumTextUTF8Bytes,
                allowEmpty: true,
                issues: &issues
            )
            let environmentText = fields.requiredString(
                profile["environmentText"],
                path: "\(path).environmentText",
                maximumUTF8Bytes: limits.maximumTextUTF8Bytes,
                allowEmpty: true,
                issues: &issues
            )
            _ = fields.requiredString(
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
                launchSecurity.validateArguments(
                    argumentsText,
                    path: "\(path).argumentsText",
                    issues: &issues
                )
            }
            if let environmentText {
                launchSecurity.validateEnvironment(
                    environmentText,
                    path: "\(path).environmentText",
                    issues: &issues
                )
            }

            launchSecurity.validateOptionalProfileEnums(
                profile,
                path: path,
                issues: &issues
            )
            launchSecurity.validateIsolationOwnership(
                profile["isolationOwnership"],
                path: "\(path).isolationOwnership",
                issues: &issues
            )
            launchSecurity.validateSensitiveEnvironmentKeys(
                profile["sensitiveEnvironmentKeys"],
                path: "\(path).sensitiveEnvironmentKeys",
                issues: &issues
            )
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

    private func appendNameCollision(
        _ name: String,
        path: String,
        priorNames: inout [String: String],
        issues: inout [LibraryImportIssue]
    ) {
        let normalized = DisplayNameValidator.collisionKey(name)
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

    @discardableResult
    private func appendDisplayNameIssues(
        _ name: String,
        subject: DisplayNameSubject,
        path: String,
        issues: inout [LibraryImportIssue]
    ) -> Bool {
        let validation = DisplayNameValidator.validate(
            name,
            maximumUTF8Bytes: limits.maximumNameUTF8Bytes
        )
        guard let normalized = validation.normalized else {
            issues.append(
                LibraryImportIssue(
                    code: .invalidDisplayName,
                    severity: .error,
                    path: path,
                    message: validation.issue?.message(for: subject)
                        ?? String(
                            localized: "Choose a valid display name."
                        )
                )
            )
            return false
        }
        if normalized != name {
            issues.append(
                issue(
                    .normalizedDisplayName,
                    severity: .warning,
                    path: path,
                    detail:
                        "This name will be saved with canonical Unicode and edge whitespace normalization."
                )
            )
        }
        return true
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
