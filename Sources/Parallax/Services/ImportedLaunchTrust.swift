import CryptoKit
import Foundation

enum ImportedLaunchIsolationRole: String, Codable, Hashable, Sendable {
    case userData
    case codexHome
}

enum ImportedLaunchIsolationAuthority: String, Codable, Hashable, Sendable {
    case managed
    case external
}

struct ImportedLaunchIsolationPath: Equatable, Hashable, Sendable {
    let role: ImportedLaunchIsolationRole
    let authority: ImportedLaunchIsolationAuthority
    /// A canonical URL produced by launch health/path validation. This service
    /// deliberately does not resolve or create filesystem paths itself.
    let canonicalURL: URL
}

struct ImportedLaunchTrustSource:
    Equatable,
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    let applicationID: UUID
    let applicationStorageID: UUID
    let applicationDisplayName: String
    let canonicalApplicationURL: URL
    let expectedBundleIdentifier: String?
    let verifiedBundleIdentifier: String?
    let profileID: UUID
    let profileStorageID: UUID
    let profileName: String
    let configuredBaseRoot: String
    let argumentsText: String
    let environmentText: String
    let isolationOwnership: ProfileIsolationOwnership
    let childEnvironmentPolicy: ChildEnvironmentPolicy
    let sensitiveEnvironmentKeys: [String]
    let isolationPaths: [ImportedLaunchIsolationPath]

    var description: String {
        "<imported launch trust source: configuration redacted>"
    }

    var debugDescription: String { description }

    var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "applicationID": applicationID,
                "profileID": profileID,
                "configuration": "<redacted>",
            ]
        )
    }
}

struct ImportedLaunchApplicationReview: Equatable, Sendable {
    let id: UUID
    let storageID: UUID
    let displayName: String
    let canonicalPath: String
    let expectedBundleIdentifier: String?
    let verifiedBundleIdentifier: String?
}

enum ImportedLaunchEnvironmentOperationReview:
    String,
    Codable,
    Equatable,
    Sendable
{
    case set
    case unset
}

enum ImportedLaunchEnvironmentRisk:
    String,
    Codable,
    CaseIterable,
    Equatable,
    Hashable,
    Sendable
{
    case dynamicLoader
    case debugger
    case sensitive
}

struct ImportedLaunchEnvironmentReviewEntry: Equatable, Sendable {
    let key: String
    let operation: ImportedLaunchEnvironmentOperationReview
    let risks: [ImportedLaunchEnvironmentRisk]
}

struct ImportedLaunchIsolationPathReview: Equatable, Sendable {
    let role: ImportedLaunchIsolationRole
    let authority: ImportedLaunchIsolationAuthority
    let canonicalPath: String
}

struct ImportedLaunchReview: Equatable, Sendable {
    let application: ImportedLaunchApplicationReview
    let profileID: UUID
    let profileStorageID: UUID
    let profileName: String
    let configuredBaseRoot: String
    let arguments: [String]
    let argumentDiagnostics: [LaunchParsingDiagnostic]
    let environmentEntries: [ImportedLaunchEnvironmentReviewEntry]
    let environmentDiagnostics: [LaunchParsingDiagnostic]
    let isolationOwnership: ProfileIsolationOwnership
    let isolationPaths: [ImportedLaunchIsolationPathReview]
    let childEnvironmentPolicy: ChildEnvironmentPolicy
    let explicitlySensitiveEnvironmentKeys: [String]
    let fingerprint: ImportedLaunchConfigurationFingerprint

    var dangerousEnvironmentKeys: [String] {
        var seen: Set<String> = []
        return environmentEntries.compactMap { entry in
            guard !entry.risks.isEmpty, seen.insert(entry.key).inserted else {
                return nil
            }
            return entry.key
        }
    }

    var inheritsCompleteProcessEnvironment: Bool {
        childEnvironmentPolicy == .inheritProcessEnvironment
    }
}

enum ImportedLaunchTrustAssessment: Equatable, Sendable {
    case trustedLocal
    case reviewRequired(ImportedLaunchReview)
    case approved(ImportedLaunchApproval)
}

enum ImportedLaunchTrustError: Error, Equatable, LocalizedError {
    case configurationChangedAfterReview

    var errorDescription: String? {
        switch self {
        case .configurationChangedAfterReview:
            String(
                localized:
                    "The imported launch configuration changed after it was reviewed. Review it again before launching."
            )
        }
    }
}

/// Pure trust and disclosure logic for imported launch configurations.
///
/// The caller supplies canonical paths already established by the read-only
/// health pipeline. This type performs no filesystem mutation, secret
/// resolution, directory preparation, or application launch.
struct ImportedLaunchTrust: Sendable {
    func review(
        for source: ImportedLaunchTrustSource
    ) -> ImportedLaunchReview {
        let arguments = LaunchArgumentParser.parse(source.argumentsText)
        let environment = LaunchEnvironmentParser.parse(
            source.environmentText
        )
        let classifier = SensitiveEnvironmentKeyClassifier(
            explicitSensitiveKeys: Set(source.sensitiveEnvironmentKeys)
        )
        let environmentEntries = environment.entries.map { entry in
            let operation: ImportedLaunchEnvironmentOperationReview
            let risks: [ImportedLaunchEnvironmentRisk]
            switch entry.operation {
            case .unset:
                operation = .unset
                risks = []
            case .set:
                operation = .set
                risks = environmentRisks(
                    for: entry.name,
                    classifier: classifier
                )
            }
            return ImportedLaunchEnvironmentReviewEntry(
                key: entry.name,
                operation: operation,
                risks: risks
            )
        }

        return ImportedLaunchReview(
            application: ImportedLaunchApplicationReview(
                id: source.applicationID,
                storageID: source.applicationStorageID,
                displayName: source.applicationDisplayName,
                canonicalPath: canonicalPath(
                    source.canonicalApplicationURL
                ),
                expectedBundleIdentifier:
                    source.expectedBundleIdentifier,
                verifiedBundleIdentifier:
                    source.verifiedBundleIdentifier
            ),
            profileID: source.profileID,
            profileStorageID: source.profileStorageID,
            profileName: source.profileName,
            configuredBaseRoot: source.configuredBaseRoot,
            arguments:
                SensitiveLaunchArgumentPolicy().redactedWords(
                    in: arguments.tokens
                ),
            argumentDiagnostics: arguments.diagnostics,
            environmentEntries: environmentEntries,
            environmentDiagnostics: environment.diagnostics,
            isolationOwnership: source.isolationOwnership,
            isolationPaths: source.isolationPaths.map { path in
                ImportedLaunchIsolationPathReview(
                    role: path.role,
                    authority: path.authority,
                    canonicalPath: canonicalPath(path.canonicalURL)
                )
            },
            childEnvironmentPolicy: source.childEnvironmentPolicy,
            explicitlySensitiveEnvironmentKeys:
                normalizedSensitiveKeys(
                    source.sensitiveEnvironmentKeys
                ),
            fingerprint: fingerprint(for: source)
        )
    }

    func assessment(
        for profile: LaunchProfile,
        source: ImportedLaunchTrustSource
    ) -> ImportedLaunchTrustAssessment {
        switch profile.launchConfigurationTrust {
        case .local:
            return .trustedLocal
        case .importedPendingReview:
            return .reviewRequired(review(for: source))
        case .importedApproved(let approval):
            let currentFingerprint = fingerprint(for: source)
            guard
                profile.id == source.profileID,
                profile.storageID == source.profileStorageID,
                approval.matches(currentFingerprint)
            else {
                return .reviewRequired(review(for: source))
            }
            return .approved(approval)
        }
    }

    func approval(
        for reviewedConfiguration: ImportedLaunchReview,
        currentSource: ImportedLaunchTrustSource,
        approvedAt: Date = Date()
    ) throws -> ImportedLaunchApproval {
        let currentFingerprint = fingerprint(for: currentSource)
        guard reviewedConfiguration.fingerprint == currentFingerprint else {
            throw ImportedLaunchTrustError
                .configurationChangedAfterReview
        }
        return ImportedLaunchApproval(
            configurationFingerprint: currentFingerprint,
            approvedAt: approvedAt
        )
    }

    func fingerprint(
        for source: ImportedLaunchTrustSource
    ) -> ImportedLaunchConfigurationFingerprint {
        var fields: [String] = [
            "imported-launch-trust-v1",
            source.applicationID.uuidString.lowercased(),
            source.applicationStorageID.uuidString.lowercased(),
            canonicalPath(source.canonicalApplicationURL),
            source.expectedBundleIdentifier.map { "some:\($0)" } ?? "none",
            source.verifiedBundleIdentifier.map { "some:\($0)" } ?? "none",
            source.profileID.uuidString.lowercased(),
            source.profileStorageID.uuidString.lowercased(),
            source.configuredBaseRoot,
            source.argumentsText,
            source.environmentText,
            source.isolationOwnership.userData.rawValue,
            source.isolationOwnership.codexHome.rawValue,
            source.childEnvironmentPolicy.rawValue,
            normalizedSensitiveKeys(
                source.sensitiveEnvironmentKeys
            ).joined(separator: "\u{1e}"),
        ]
        for path in source.isolationPaths.sorted(by: isolationPathOrder) {
            fields.append(path.role.rawValue)
            fields.append(path.authority.rawValue)
            fields.append(canonicalPath(path.canonicalURL))
        }
        var canonical = Data()
        for field in fields {
            let bytes = Data(field.utf8)
            canonical.append(contentsOf: withUnsafeBytes(
                of: UInt64(bytes.count).bigEndian,
                Array.init
            ))
            canonical.append(bytes)
        }
        let digest = SHA256.hash(data: canonical)
            .map { String(format: "%02x", $0) }
            .joined()
        return ImportedLaunchConfigurationFingerprint(sha256: digest)
    }

    private func environmentRisks(
        for key: String,
        classifier: SensitiveEnvironmentKeyClassifier
    ) -> [ImportedLaunchEnvironmentRisk] {
        var risks: [ImportedLaunchEnvironmentRisk] = []
        if isDynamicLoaderKey(key) {
            risks.append(.dynamicLoader)
        }
        if isDebuggerKey(key) {
            risks.append(.debugger)
        }
        if classifier.isSensitive(key) {
            risks.append(.sensitive)
        }
        return risks
    }

    private func isDynamicLoaderKey(_ key: String) -> Bool {
        let normalized = key.uppercased()
        return normalized.hasPrefix("DYLD_")
            || normalized.hasPrefix("__XPC_DYLD_")
            || normalized == "LD_PRELOAD"
            || normalized == "LD_LIBRARY_PATH"
            || normalized == "LD_AUDIT"
            || normalized == "LD_DEBUG"
    }

    private func isDebuggerKey(_ key: String) -> Bool {
        let normalized = key.uppercased()
        let exact: Set<String> = [
            "CFNETWORK_DIAGNOSTICS",
            "NSAUTORELEASEFREEDOBJECTCHECKENABLED",
            "NSDEALLOCATEZOMBIES",
            "NSUNBUFFEREDIO",
            "NSZOMBIEENABLED",
        ]
        let prefixes = [
            "LLDB_",
            "MALLOC",
            "OBJC_DEBUG_",
            "OBJC_PRINT_",
            "SWIFT_DEBUG_",
            "XCTEST",
        ]
        return exact.contains(normalized)
            || prefixes.contains { normalized.hasPrefix($0) }
    }

    private func normalizedSensitiveKeys(
        _ keys: [String]
    ) -> [String] {
        Array(Set(keys.map { $0.uppercased() })).sorted()
    }

    private func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func isolationPathOrder(
        _ lhs: ImportedLaunchIsolationPath,
        _ rhs: ImportedLaunchIsolationPath
    ) -> Bool {
        let left = [
            lhs.role.rawValue,
            lhs.authority.rawValue,
            canonicalPath(lhs.canonicalURL),
        ]
        let right = [
            rhs.role.rawValue,
            rhs.authority.rawValue,
            canonicalPath(rhs.canonicalURL),
        ]
        return left.lexicographicallyPrecedes(right)
    }
}
