import Foundation

/// Validates launch-capable imported fields before typed decoding can create a
/// trusted domain object.
struct LibraryImportLaunchSecurityValidator {
    let limits: LibraryImportLimits

    func validateArguments(
        _ text: String,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        let parsed = LaunchArgumentParser.parse(text)
        for _ in parsed.diagnostics where parsed.hasErrors {
            append(
                .invalidArguments,
                path: path,
                detail: "The launch arguments contain invalid syntax.",
                to: &issues
            )
        }
        let userData = UserDataDirectoryOptionResolver.resolve(in: parsed.tokens)
        for _ in userData.diagnostics {
            append(
                .invalidArguments,
                path: path,
                detail: "The user data directory option is ambiguous or incomplete.",
                to: &issues
            )
        }
        if let value = userData.resolvedValue,
           !isCanonicalIsolationPath(value)
        {
            append(
                .invalidIsolationPath,
                path: path,
                detail: "The user data directory must be absolute and traversal-free.",
                to: &issues
            )
        }
    }

    func validateEnvironment(
        _ text: String,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        let parsed = LaunchEnvironmentParser.parse(text)
        for diagnostic in parsed.diagnostics where diagnostic.severity == .error {
            append(
                .invalidEnvironment,
                path: path,
                detail: "The environment contains an invalid line or variable name.",
                to: &issues
            )
        }
        for entry in parsed.entries {
            guard entry.name == "CODEX_HOME",
                  case let .set(value) = entry.operation,
                  !isCanonicalIsolationPath(value)
            else { continue }
            append(
                .invalidIsolationPath,
                path: path,
                detail: "CODEX_HOME must be absolute and traversal-free.",
                to: &issues
            )
        }
    }

    func validateOptionalProfileEnums(
        _ profile: [String: Any],
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        if let policy = profile["childEnvironmentPolicy"],
           !(policy is NSNull)
        {
            guard let value = policy as? String else {
                append(
                    .invalidFieldType,
                    path: "\(path).childEnvironmentPolicy",
                    detail: "The child environment policy must be text.",
                    to: &issues
                )
                return
            }
            let allowed = Set(ChildEnvironmentPolicy.allCases.map(\.rawValue))
            if !allowed.contains(value) {
                append(
                    .invalidFieldValue,
                    path: "\(path).childEnvironmentPolicy",
                    detail: "The child environment policy is not supported.",
                    to: &issues
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

    func validateIsolationOwnership(
        _ value: Any?,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        guard let value, !(value is NSNull) else { return }
        guard let ownership = value as? [String: Any] else {
            append(
                .invalidFieldType,
                path: path,
                detail: "Isolation ownership must be an object.",
                to: &issues
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
                append(
                    .missingRequiredField,
                    path: "\(path).\(key)",
                    detail: "Isolation ownership requires both path authorities.",
                    to: &issues
                )
                continue
            }
            guard let string = rawValue as? String else {
                append(
                    .invalidFieldType,
                    path: "\(path).\(key)",
                    detail: "Isolation ownership authority must be text.",
                    to: &issues
                )
                continue
            }
            if !allowed.contains(string) {
                append(
                    .invalidFieldValue,
                    path: "\(path).\(key)",
                    detail: "The isolation ownership authority is not supported.",
                    to: &issues
                )
            }
        }
    }

    func validateSensitiveEnvironmentKeys(
        _ value: Any?,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        guard let value, !(value is NSNull) else { return }
        guard let keys = value as? [Any] else {
            append(
                .invalidFieldType,
                path: path,
                detail: "Sensitive environment keys must be an array.",
                to: &issues
            )
            return
        }
        if keys.count > limits.maximumSensitiveEnvironmentKeys {
            append(
                .tooManySensitiveEnvironmentKeys,
                path: path,
                detail: "The profile contains too many sensitive environment keys.",
                to: &issues
            )
        }
        for (index, rawKey) in keys.enumerated() {
            let keyPath = "\(path)[\(index)]"
            guard let key = rawKey as? String else {
                append(
                    .invalidFieldType,
                    path: keyPath,
                    detail: "Each sensitive environment key must be text.",
                    to: &issues
                )
                continue
            }
            LibraryImportRawFieldReader().appendStringLimitIssue(
                key,
                path: keyPath,
                maximumUTF8Bytes: limits.maximumNameUTF8Bytes,
                issues: &issues
            )
            if !isValidEnvironmentKey(key) {
                append(
                    .invalidFieldValue,
                    path: keyPath,
                    detail: "A sensitive environment key is not a valid variable name.",
                    to: &issues
                )
            }
        }
    }

    private func validateLaunchConfigurationTrust(
        _ value: Any,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        if let legacyState = value as? String {
            guard legacyState == "local"
                || legacyState == "importedPendingReview"
            else {
                append(
                    .invalidFieldValue,
                    path: path,
                    detail: "The launch configuration trust state is not supported.",
                    to: &issues
                )
                return
            }
            return
        }
        guard let object = value as? [String: Any] else {
            append(
                .invalidFieldType,
                path: path,
                detail: "Launch configuration trust must be a legacy state or an approval object.",
                to: &issues
            )
            return
        }
        guard let state = object["state"] as? String else {
            append(
                .missingRequiredField,
                path: "\(path).state",
                detail: "The launch configuration trust object requires a state.",
                to: &issues
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
            append(
                .invalidFieldValue,
                path: "\(path).state",
                detail: "The launch configuration trust state is not supported.",
                to: &issues
            )
        }
    }

    private func validateImportedLaunchApproval(
        _ value: Any?,
        path: String,
        issues: inout [LibraryImportIssue]
    ) {
        guard let approval = value as? [String: Any] else {
            append(
                value == nil ? .missingRequiredField : .invalidFieldType,
                path: path,
                detail: "Imported approval details are required for approved launch configuration trust.",
                to: &issues
            )
            return
        }
        if let fingerprint = approval["configurationFingerprint"] as? [String: Any] {
            guard let sha256 = fingerprint["sha256"] as? String else {
                append(
                    .missingRequiredField,
                    path: "\(path).configurationFingerprint.sha256",
                    detail: "Imported approval requires a configuration fingerprint.",
                    to: &issues
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
                append(
                    .invalidFieldValue,
                    path: "\(path).configurationFingerprint.sha256",
                    detail: "The imported approval fingerprint must be a lowercase SHA-256 value.",
                    to: &issues
                )
            }
        } else {
            append(
                approval["configurationFingerprint"] == nil
                    ? .missingRequiredField
                    : .invalidFieldType,
                path: "\(path).configurationFingerprint",
                detail: "Imported approval requires a configuration fingerprint object.",
                to: &issues
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
            append(
                .missingRequiredField,
                path: path,
                detail: "Imported approval requires an approval date.",
                to: &issues
            )
            return
        }
        guard let number = value as? NSNumber,
              !isBoolean(number),
              number.doubleValue.isFinite
        else {
            append(
                .invalidFieldType,
                path: path,
                detail: "The imported approval date must use the encoded date representation.",
                to: &issues
            )
            return
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

    private func isCanonicalIsolationPath(_ path: String) -> Bool {
        if path == "~" { return true }
        if path.hasPrefix("~/") {
            let remainder = String(path.dropFirst(2))
            return !remainder.isEmpty
                && !hasUnsafeRawPathComponent("/\(remainder)")
        }
        return isCanonicalAbsolutePath(path)
    }

    private func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.contains("\0"),
              (path as NSString).isAbsolutePath,
              !hasUnsafeRawPathComponent(path)
        else { return false }
        return URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL.path == path
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

    private func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func append(
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
