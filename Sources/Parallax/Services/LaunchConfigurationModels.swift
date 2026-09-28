import Foundation

/// A value snapshot of every launch-relevant field. Callers create this before
/// confirmation so later model edits cannot retarget an approved request.
struct LaunchConfigurationSource: Sendable, Equatable {
    let requestID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileID: UUID
    let profileStorageID: UUID
    var configurationRevision: UInt64
    let applicationURL: URL
    let expectedBundleIdentifier: String?
    let configuredBaseRoot: String
    let argumentsText: String
    let environmentText: String
    let isolationOwnership: ProfileIsolationOwnership
    let childEnvironmentPolicy: ChildEnvironmentPolicy
    let sensitiveEnvironmentKeys: [String]
    var preset: AppPreset = .custom
    var requiresClaudeConfigIsolation = false
    var peerProfiles: [LaunchPeerProfileSource] = []
}

struct LaunchPeerProfileSource: Sendable, Equatable {
    let profileID: UUID
    let profileStorageID: UUID
    let argumentsText: String
    let environmentText: String
    let isolationOwnership: ProfileIsolationOwnership
    var profileName: String = ""
}

/// A request-scoped, in-memory confirmation fingerprint. This value is not
/// Codable and is never written to the library document.
struct LaunchConfigurationFingerprint: Sendable, Equatable, Hashable {
    fileprivate let digest: String

    init(digest: String) {
        self.digest = digest
    }
}

struct LaunchDiagnosticOverride: Sendable, Equatable {
    let requestID: UUID
    let configurationFingerprint: LaunchConfigurationFingerprint
    let allowsActiveProfileRisk: Bool

    init(
        requestID: UUID,
        configurationFingerprint: LaunchConfigurationFingerprint,
        allowsActiveProfileRisk: Bool = false
    ) {
        self.requestID = requestID
        self.configurationFingerprint = configurationFingerprint
        self.allowsActiveProfileRisk = allowsActiveProfileRisk
    }
}

enum LaunchCompilerDiagnosticCode: Sendable, Equatable {
    case parsing(LaunchParsingDiagnosticCode)
    case applicationHealth(LaunchHealthIssueCode)
    case profileHealth(LaunchHealthIssueCode)
    case invalidManagedPath
    case unresolvedIsolationPath
    case sensitiveArgument
    case invalidPresetOption(PresetIsolationFolder)
    case conflictingFirefoxProfileSelection
}

struct LaunchCompilerDiagnostic: Sendable, Equatable {
    let code: LaunchCompilerDiagnosticCode
    let severity: LaunchDiagnosticSeverity
    let isOverridable: Bool
    let sourceRange: LaunchSourceRange?
    let path: String?
    var claudeConfigCollisionProfileNames: [String] = []

    var message: String {
        if !claudeConfigCollisionProfileNames.isEmpty {
            return Self.claudeConfigCollisionMessage(profileNames: claudeConfigCollisionProfileNames)
        }
        switch code {
        case .parsing(let code):
            return parsingMessage(for: code)
        case .applicationHealth:
            return String(
                localized:
                    "The selected application is not healthy enough to launch."
            )
        case .profileHealth(.storageReservedForDataOperation):
            return ProfileActivityRegistryError.storageReservedForDataOperation.localizedDescription
        case .profileHealth:
            return String(
                localized:
                    "The selected profile storage is not healthy enough to launch."
            )
        case .invalidManagedPath:
            return String(
                localized:
                    "The managed profile storage path is invalid or unavailable."
            )
        case .unresolvedIsolationPath:
            return String(
                localized:
                    "The isolation path cannot be validated before launch."
            )
        case .invalidPresetOption(.firefoxProfile):
            return String(localized: "Specify -profile only once, followed by an absolute profile folder path.")
        case .invalidPresetOption(.extensions):
            return String(localized: "Specify --extensions-dir only once, followed by an absolute extensions folder path.")
        case .conflictingFirefoxProfileSelection:
            return String(localized: "Remove the generated -profile option or the other Firefox profile selection (-P, -ProfileManager, -CreateProfile, or XRE_PROFILE_PATH) before opening this space.")
        case .sensitiveArgument:
            return String(
                localized:
                    "A launch argument appears to contain a secret. Process arguments are visible to other local tools; move the value to a Keychain-backed environment entry."
            )
        }
    }

    static func claudeConfigCollisionMessage(
        profileNames: [String],
        bundle: Bundle = .main,
        locale: Locale = .current
    ) -> String {
        String(
            format: String(
                localized:
                    "The Claude configuration folder is also used by: %@. Remove the explicit CLAUDE_CONFIG_DIR entry from one of these spaces so it uses its own managed folder.",
                bundle: bundle,
                locale: locale
            ),
            locale: locale,
            arguments: [profileNames.joined(separator: ", ")]
        )
    }

    private func parsingMessage(
        for code: LaunchParsingDiagnosticCode
    ) -> String {
        let location = sourceRange ?? LaunchSourceRange(
            start: LaunchSourceLocation(utf16Offset: 0, line: 1, column: 1),
            end: LaunchSourceLocation(utf16Offset: 0, line: 1, column: 1)
        )
        return LaunchParsingDiagnostic(
            code: code,
            severity: severity,
            source: .arguments,
            range: location
        ).message
    }
}

struct RedactedLaunchPreview: Sendable, Equatable {
    let arguments: [String]
    let environment: [EnvironmentPreviewEntry]
    let userDataURL: URL?
    let codexHomeURL: URL?
}

enum LaunchIsolationPath: Sendable, Equatable {
    case managed(URL)
    case external(ExternalIsolationPath)

    var url: URL {
        switch self {
        case .managed(let url):
            return url
        case .external(let path):
            return path.requestedURL
        }
    }

    var canonicalURL: URL {
        switch self {
        case .managed(let url):
            return url
        case .external(let path):
            return path.canonicalURL
        }
    }

    var isManaged: Bool {
        if case .managed = self {
            return true
        }
        return false
    }
}

struct LaunchIsolationAnalysis: Sendable, Equatable {
    let userData: LaunchIsolationPath?
    let codexHome: LaunchIsolationPath?
    let claudeConfig: LaunchIsolationPath?
    var presetFolders: [PresetIsolationFolder: LaunchIsolationPath] = [:]

    init(
        userData: LaunchIsolationPath?,
        codexHome: LaunchIsolationPath?,
        claudeConfig: LaunchIsolationPath? = nil
    ) {
        self.userData = userData
        self.codexHome = codexHome
        self.claudeConfig = claudeConfig
    }

    var userDataURL: URL? { userData?.url }
    var codexHomeURL: URL? { codexHome?.url }
}

struct LaunchAnalysis: Sendable, Equatable {
    let requestID: UUID
    let configurationFingerprint: LaunchConfigurationFingerprint
    let argumentResult: LaunchArgumentParseResult
    let userDataResolution: UserDataDirectoryResolution
    let environmentResult: LaunchEnvironmentParseResult
    let applicationHealth: ApplicationHealthReport
    let profileHealth: ProfileHealthReport?
    let isolation: LaunchIsolationAnalysis
    let diagnostics: [LaunchCompilerDiagnostic]
    let preview: RedactedLaunchPreview

    var hasBlockingDiagnostics: Bool {
        diagnostics.contains { $0.severity == .error }
    }
}

struct PreparedLaunchIsolation: Sendable, Equatable {
    let userDataURL: URL?
    let codexHomeURL: URL?
    let managesUserData: Bool
    let managesCodexHome: Bool
    var managedFirefoxProfileURL: URL? = nil
    var verifiesUserData = true

    var managedVerificationPaths: [LaunchIsolationPath] {
        if let managedFirefoxProfileURL { return [.managed(managedFirefoxProfileURL)] }
        if verifiesUserData, managesUserData, let userDataURL { return [.managed(userDataURL)] }
        return []
    }
}

/// Deliberately not Codable, printable, or reflectively summarized. This value
/// may contain resolved secrets and should live only for the launch request.
struct PreparedLaunch:
    Sendable,
    CustomStringConvertible,
    CustomDebugStringConvertible,
    CustomReflectable
{
    let requestID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileID: UUID
    let profileStorageID: UUID
    let applicationIdentity: WorkspaceApplicationBundleIdentity
    let arguments: [String]
    let environment: [String: String]
    let isolation: PreparedLaunchIsolation
    let configurationFingerprint: LaunchConfigurationFingerprint

    var applicationURL: URL { applicationIdentity.bundleURL }

    var description: String { "<prepared launch: redacted>" }
    var debugDescription: String { "<prepared launch: redacted>" }
    var customMirror: Mirror {
        Mirror(
            self,
            children: ["summary": "<prepared launch: redacted>"]
        )
    }
}

enum LaunchPreparationError:
    Error,
    LocalizedError,
    Sendable,
    Equatable
{
    case blocked([LaunchCompilerDiagnostic])
    case overrideDoesNotMatchRequest

    var errorDescription: String? {
        switch self {
        case .blocked(let diagnostics):
            let messages = diagnostics.map(\.message)
            return messages.isEmpty
                ? String(localized: "The launch configuration is invalid.")
                : messages.joined(separator: "\n")
        case .overrideDoesNotMatchRequest:
            return String(
                localized:
                    "The launch approval no longer matches this configuration."
            )
        }
    }
}
