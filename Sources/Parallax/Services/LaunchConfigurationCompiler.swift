import CryptoKit
import Foundation

/// A value snapshot of every launch-relevant field. Callers create this before
/// confirmation so later model edits cannot retarget an approved request.
struct LaunchConfigurationSource: Sendable, Equatable {
    let requestID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let profileID: UUID
    let profileStorageID: UUID
    let configurationRevision: UInt64
    let applicationURL: URL
    let expectedBundleIdentifier: String?
    let configuredBaseRoot: String
    let argumentsText: String
    let environmentText: String
    let isolationOwnership: ProfileIsolationOwnership
    let childEnvironmentPolicy: ChildEnvironmentPolicy
    let sensitiveEnvironmentKeys: [String]
    var peerProfiles: [LaunchPeerProfileSource] = []
}

struct LaunchPeerProfileSource: Sendable, Equatable {
    let profileID: UUID
    let profileStorageID: UUID
    let argumentsText: String
    let environmentText: String
    let isolationOwnership: ProfileIsolationOwnership
}

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
}

struct LaunchCompilerDiagnostic: Sendable, Equatable {
    let code: LaunchCompilerDiagnosticCode
    let severity: LaunchDiagnosticSeverity
    let isOverridable: Bool
    let sourceRange: LaunchSourceRange?
    let path: String?

    var message: String {
        switch code {
        case .parsing(let code):
            return parsingMessage(for: code)
        case .applicationHealth:
            return String(
                localized:
                    "The selected application is not healthy enough to launch."
            )
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
        case .sensitiveArgument:
            return String(
                localized:
                    "A launch argument appears to contain a secret. Process arguments are visible to other local tools; move the value to a Keychain-backed environment entry."
            )
        }
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
    case external(URL)

    var url: URL {
        switch self {
        case .managed(let url), .external(let url):
            return url
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

struct LaunchConfigurationCompiler: Sendable {
    private struct AnalysisContext: Sendable {
        let analysis: LaunchAnalysis
        let managedPaths: ResolvedProfilePaths?
        let assignments: [StoredEnvironmentAssignment]
        let unsetKeys: Set<String>
    }

    private let fileSystem: any FileSystem
    private let pathResolver: ManagedPathResolver
    private let healthService: LaunchHealthService
    private let identity: ChildEnvironmentIdentity
    private let processEnvironment: [String: String]
    private let secretResolver: any SecretResolving
    private let preparationHook: @Sendable () async throws -> Void

    init(
        fileSystem: any FileSystem = LocalFileSystem(),
        writeAccess: any PathWriteAccessChecking =
            POSIXPathWriteAccessChecker(),
        activityProvider: any ProfileHealthActivityProviding =
            NoProfileHealthActivityProvider(),
        identity: ChildEnvironmentIdentity = .current,
        processEnvironment: [String: String] =
            ProcessInfo.processInfo.environment,
        secretResolver: any SecretResolving = KeychainSecretStore(),
        preparationHook:
            @escaping @Sendable () async throws -> Void = {}
    ) {
        self.fileSystem = fileSystem
        pathResolver = ManagedPathResolver(fileSystem: fileSystem)
        healthService = LaunchHealthService(
            fileSystem: fileSystem,
            writeAccess: writeAccess,
            activityProvider: activityProvider
        )
        self.identity = identity
        self.processEnvironment = processEnvironment
        self.secretResolver = secretResolver
        self.preparationHook = preparationHook
    }

    func analyze(_ source: LaunchConfigurationSource) async -> LaunchAnalysis {
        await Task.detached {
            analysisContext(for: source).analysis
        }.value
    }

    nonisolated static func configurationFingerprint(
        for source: LaunchConfigurationSource
    ) -> LaunchConfigurationFingerprint {
        fingerprint(source)
    }

    func prepare(
        _ source: LaunchConfigurationSource,
        override: LaunchDiagnosticOverride? = nil
    ) async throws -> PreparedLaunch {
        let task = Task.detached {
            try Task.checkCancellation()
            let context = analysisContext(for: source)
            try validate(context.analysis, override: override)

            try await preparationHook()
            try Task.checkCancellation()

            let environment = try await LaunchEnvironmentPreparer(
                policy: source.childEnvironmentPolicy,
                identity: identity,
                processEnvironment: processEnvironment,
                secretResolver: secretResolver
            ).prepare(
                context.assignments,
                unsetKeys: context.unsetKeys
            )
            try Task.checkCancellation()

            if let managedPaths = context.managedPaths {
                try prepareManagedDirectories(
                    for: context.analysis.isolation,
                    managedPaths: managedPaths
                )
            }
            try Task.checkCancellation()

            let arguments = preparedArguments(
                context.analysis.argumentResult.words,
                resolution: context.analysis.userDataResolution,
                isolation: context.analysis.isolation
            )
            guard
                let canonicalApplicationURL =
                    context.analysis.applicationHealth
                        .canonicalApplicationURL,
                let bundleIdentifier =
                    context.analysis.applicationHealth.bundleIdentifier,
                !bundleIdentifier.isEmpty
            else {
                throw LaunchPreparationError.blocked(
                    context.analysis.diagnostics
                )
            }
            return PreparedLaunch(
                requestID: source.requestID,
                applicationID: source.applicationID,
                applicationStorageID: source.applicationStorageID,
                profileID: source.profileID,
                profileStorageID: source.profileStorageID,
                applicationIdentity: WorkspaceApplicationBundleIdentity(
                    bundleURL: canonicalApplicationURL,
                    bundleIdentifier: bundleIdentifier
                ),
                arguments: arguments,
                environment: environment,
                isolation: PreparedLaunchIsolation(
                    userDataURL: context.analysis.isolation.userDataURL,
                    codexHomeURL: context.analysis.isolation.codexHomeURL,
                    managesUserData:
                        context.analysis.isolation.userData?.isManaged ?? false,
                    managesCodexHome:
                        context.analysis.isolation.codexHome?.isManaged ?? false
                ),
                configurationFingerprint:
                    context.analysis.configurationFingerprint
            )
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func analysisContext(
        for source: LaunchConfigurationSource
    ) -> AnalysisContext {
        let argumentResult = LaunchArgumentParser.parse(source.argumentsText)
        let sensitiveArgumentIndexes =
            SensitiveLaunchArgumentPolicy().sensitiveTokenIndexes(
                in: argumentResult.tokens
            )
        let userDataResolution = UserDataDirectoryOptionResolver.resolve(
            in: argumentResult.tokens
        )
        let environmentResult = LaunchEnvironmentParser.parse(
            source.environmentText
        )
        let fingerprint = Self.fingerprint(source)
        var diagnostics = (
            argumentResult.diagnostics + userDataResolution.diagnostics
                + environmentResult.diagnostics
        ).map(Self.compilerDiagnostic)
        diagnostics.append(
            contentsOf: sensitiveArgumentIndexes.sorted().map { index in
                LaunchCompilerDiagnostic(
                    code: .sensitiveArgument,
                    severity: .error,
                    isOverridable: false,
                    sourceRange: argumentResult.tokens[index].range,
                    path: nil
                )
            }
        )

        let applicationHealth = healthService.inspectApplication(
            ApplicationHealthInput(
                applicationID: source.applicationID,
                applicationURL: source.applicationURL,
                expectedBundleIdentifier: source.expectedBundleIdentifier
            )
        )
        diagnostics.append(
            contentsOf: applicationHealth.issues.map {
                LaunchCompilerDiagnostic(
                    code: .applicationHealth($0.code),
                    severity: .error,
                    isOverridable: false,
                    sourceRange: nil,
                    path: $0.path
                )
            }
        )
        if source.expectedBundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty != false
        {
            diagnostics.append(
                LaunchCompilerDiagnostic(
                    code: .applicationHealth(.missingBundleIdentifier),
                    severity: .error,
                    isOverridable: false,
                    sourceRange: nil,
                    path: applicationHealth.canonicalApplicationURL?.path
                        ?? source.applicationURL.path
                )
            )
        }

        let managedPaths: ResolvedProfilePaths?
        do {
            managedPaths = try pathResolver.resolve(
                configuredBaseRoot: source.configuredBaseRoot,
                applicationStorageID: source.applicationStorageID,
                profileStorageID: source.profileStorageID
            )
        } catch {
            managedPaths = nil
            diagnostics.append(
                LaunchCompilerDiagnostic(
                    code: .invalidManagedPath,
                    severity: .error,
                    isOverridable: false,
                    sourceRange: nil,
                    path: source.configuredBaseRoot
                )
            )
        }

        let assignmentsAndUnsets = effectiveEnvironment(
            environmentResult.entries
        )
        let isolation = isolationAnalysis(
            source: source,
            userDataResolution: userDataResolution,
            effectiveAssignments: assignmentsAndUnsets.assignments,
            managedPaths: managedPaths,
            diagnostics: &diagnostics
        )
        let profileHealth = profileHealth(
            source: source,
            isolation: isolation
        )
        if let profileHealth {
            diagnostics.append(
                contentsOf: profileHealth.issues.map {
                    LaunchCompilerDiagnostic(
                        code: .profileHealth($0.code),
                        severity: .error,
                        isOverridable: false,
                        sourceRange: nil,
                        path: $0.path
                    )
                }
            )
        }

        let effectiveAssignments = preparedEnvironmentAssignments(
            assignmentsAndUnsets.assignments,
            isolation: isolation
        )
        let effectiveUnsetKeys =
            isolation.codexHome?.isManaged == true
            ? assignmentsAndUnsets.unsetKeys.subtracting(["CODEX_HOME"])
            : assignmentsAndUnsets.unsetKeys
        let preview = RedactedLaunchPreview(
            arguments: preparedArguments(
                SensitiveLaunchArgumentPolicy().redactedWords(
                    in: argumentResult.tokens
                ),
                resolution: userDataResolution,
                isolation: isolation
            ),
            environment: EnvironmentDisclosurePolicy(
                explicitSensitiveKeys: Set(source.sensitiveEnvironmentKeys)
            ).preview(
                previewEnvironmentAssignments(
                    effectiveAssignments,
                    unsetKeys: effectiveUnsetKeys,
                    policy: source.childEnvironmentPolicy
                )
            ),
            userDataURL: isolation.userDataURL,
            codexHomeURL: isolation.codexHomeURL
        )
        let analysis = LaunchAnalysis(
            requestID: source.requestID,
            configurationFingerprint: fingerprint,
            argumentResult: argumentResult,
            userDataResolution: userDataResolution,
            environmentResult: environmentResult,
            applicationHealth: applicationHealth,
            profileHealth: profileHealth,
            isolation: isolation,
            diagnostics: diagnostics,
            preview: preview
        )
        return AnalysisContext(
            analysis: analysis,
            managedPaths: managedPaths,
            assignments: effectiveAssignments,
            unsetKeys: effectiveUnsetKeys
        )
    }

    private func validate(
        _ analysis: LaunchAnalysis,
        override: LaunchDiagnosticOverride?
    ) throws {
        let blocking = analysis.diagnostics.filter {
            $0.severity == .error
        }
        guard !blocking.isEmpty else {
            if let override,
               override.requestID != analysis.requestID
                    || override.configurationFingerprint
                        != analysis.configurationFingerprint
            {
                throw LaunchPreparationError.overrideDoesNotMatchRequest
            }
            return
        }
        guard
            let override,
            override.requestID == analysis.requestID,
            override.configurationFingerprint
                == analysis.configurationFingerprint,
            blocking.allSatisfy({
                $0.isOverridable
                    || (
                        override.allowsActiveProfileRisk
                            && $0.code
                                == .profileHealth(.profileActive)
                    )
            })
        else {
            throw LaunchPreparationError.blocked(blocking)
        }
    }

    private func isolationAnalysis(
        source: LaunchConfigurationSource,
        userDataResolution: UserDataDirectoryResolution,
        effectiveAssignments: [StoredEnvironmentAssignment],
        managedPaths: ResolvedProfilePaths?,
        diagnostics: inout [LaunchCompilerDiagnostic]
    ) -> LaunchIsolationAnalysis {
        let expander = PathSpecificTildeExpander(
            homeDirectory: identity.homeDirectory
        )
        let configuredUserData = userDataResolution.resolvedValue.map {
            expander.argumentValue($0, forOption: "--user-data-dir")
        }
        let configuredCodexHome = effectiveAssignments.first {
            $0.key == "CODEX_HOME"
        }.flatMap { assignment -> String? in
            switch assignment.value {
            case .literal(let value):
                return expander.environmentValue(
                    value,
                    forKey: "CODEX_HOME"
                )
            case .secretReference:
                diagnostics.append(
                    LaunchCompilerDiagnostic(
                        code: .unresolvedIsolationPath,
                        severity: .error,
                        isOverridable: false,
                        sourceRange: nil,
                        path: nil
                    )
                )
                return nil
            }
        }

        let userData = classifyIsolation(
            ownership: source.isolationOwnership.userData,
            configuredPath: configuredUserData,
            managedURL: managedPaths?.userData.url,
            diagnostics: &diagnostics
        )
        let codexHome = classifyIsolation(
            ownership: source.isolationOwnership.codexHome,
            configuredPath: configuredCodexHome,
            managedURL: managedPaths?.codexHome.url,
            diagnostics: &diagnostics
        )
        return LaunchIsolationAnalysis(
            userData: userData,
            codexHome: codexHome
        )
    }

    private func classifyIsolation(
        ownership: IsolationPathOwnership,
        configuredPath: String?,
        managedURL: URL?,
        diagnostics: inout [LaunchCompilerDiagnostic]
    ) -> LaunchIsolationPath? {
        switch ownership {
        case .generated:
            return managedURL.map { .managed($0) }
        case .explicit:
            guard let configuredPath else { return nil }
            return validatedExternalIsolation(
                configuredPath,
                diagnostics: &diagnostics
            )
        case .legacyUnknown:
            guard let configuredPath else { return nil }
            let configuredURL: URL
            do {
                configuredURL = try pathResolver
                    .resolveExternalPath(configuredPath).url
            } catch {
                diagnostics.append(
                    LaunchCompilerDiagnostic(
                        code: .profileHealth(.externalPathInvalid),
                        severity: .error,
                        isOverridable: false,
                        sourceRange: nil,
                        path: configuredPath
                    )
                )
                return nil
            }
            if let managedURL,
               configuredURL.path == managedURL.standardizedFileURL.path
            {
                return .managed(managedURL)
            }
            return .external(configuredURL)
        }
    }

    private func validatedExternalIsolation(
        _ configuredPath: String,
        diagnostics: inout [LaunchCompilerDiagnostic]
    ) -> LaunchIsolationPath? {
        do {
            return .external(
                try pathResolver.resolveExternalPath(configuredPath).url
            )
        } catch {
            diagnostics.append(
                LaunchCompilerDiagnostic(
                    code: .profileHealth(.externalPathInvalid),
                    severity: .error,
                    isOverridable: false,
                    sourceRange: nil,
                    path: configuredPath
                )
            )
            return nil
        }
    }

    private func profileHealth(
        source: LaunchConfigurationSource,
        isolation: LaunchIsolationAnalysis
    ) -> ProfileHealthReport? {
        var inputs: [ProfileIsolationHealthInput] = []
        if let userData = isolation.userData {
            inputs.append(
                ProfileIsolationHealthInput(
                    role: userData.isManaged
                        ? .managedUserData : .externalUserData,
                    source: userData.isManaged
                        ? .managedUserData
                        : .external(userData.url.path)
                )
            )
        }
        if let codexHome = isolation.codexHome {
            inputs.append(
                ProfileIsolationHealthInput(
                    role: codexHome.isManaged
                        ? .managedCodexHome : .externalCodexHome,
                    source: codexHome.isManaged
                        ? .managedCodexHome
                        : .external(codexHome.url.path)
                )
            )
        }
        let current = ProfileHealthInput(
            applicationID: source.applicationID,
            profileID: source.profileID,
            applicationStorageID: source.applicationStorageID,
            profileStorageID: source.profileStorageID,
            configuredBaseRoot: source.configuredBaseRoot,
            isolationPaths: inputs
        )
        let allInputs = [current] + source.peerProfiles.map {
            peerHealthInput(source: source, peer: $0)
        }
        return healthService.inspectProfiles(allInputs).first {
            $0.profileID == source.profileID
        }
    }

    private func peerHealthInput(
        source: LaunchConfigurationSource,
        peer: LaunchPeerProfileSource
    ) -> ProfileHealthInput {
        let expander = PathSpecificTildeExpander(
            homeDirectory: identity.homeDirectory
        )
        var paths: [ProfileIsolationHealthInput] = []
        switch peer.isolationOwnership.userData {
        case .generated:
            paths.append(
                ProfileIsolationHealthInput(
                    role: .managedUserData,
                    source: .managedUserData
                )
            )
        case .explicit, .legacyUnknown:
            let parsed = LaunchArgumentParser.parse(peer.argumentsText)
            if
                let configured =
                    UserDataDirectoryOptionResolver.resolve(
                        in: parsed.tokens
                    ).resolvedValue
            {
                paths.append(
                    ProfileIsolationHealthInput(
                        role: .externalUserData,
                        source: .external(
                            expander.argumentValue(
                                configured,
                                forOption: "--user-data-dir"
                            )
                        )
                    )
                )
            }
        }
        switch peer.isolationOwnership.codexHome {
        case .generated:
            paths.append(
                ProfileIsolationHealthInput(
                    role: .managedCodexHome,
                    source: .managedCodexHome
                )
            )
        case .explicit, .legacyUnknown:
            if
                let configured = LaunchEnvironmentParser.parse(
                    peer.environmentText
                ).effectiveValues["CODEX_HOME"],
                case .literal(let value) =
                    StoredEnvironmentValue(storedText: configured)
            {
                paths.append(
                    ProfileIsolationHealthInput(
                        role: .externalCodexHome,
                        source: .external(
                            expander.environmentValue(
                                value,
                                forKey: "CODEX_HOME"
                            )
                        )
                    )
                )
            }
        }
        return ProfileHealthInput(
            applicationID: source.applicationID,
            profileID: peer.profileID,
            applicationStorageID: source.applicationStorageID,
            profileStorageID: peer.profileStorageID,
            configuredBaseRoot: source.configuredBaseRoot,
            isolationPaths: paths
        )
    }

    private func prepareManagedDirectories(
        for isolation: LaunchIsolationAnalysis,
        managedPaths: ResolvedProfilePaths
    ) throws {
        var managedTargets: [any ManagedMutationPath] = []
        if isolation.userData?.isManaged == true {
            managedTargets.append(managedPaths.userData)
        }
        if isolation.codexHome?.isManaged == true {
            managedTargets.append(managedPaths.codexHome)
        }
        guard !managedTargets.isEmpty else { return }

        let context = managedPaths.profileRoot.validationContext
        let canonicalRoot = context.canonicalBaseRootURL
        let anchorComponents =
            context.identityAnchorURL.standardizedFileURL.pathComponents
        let rootComponents =
            canonicalRoot.standardizedFileURL.pathComponents
        guard
            rootComponents.count >= anchorComponents.count,
            Array(rootComponents.prefix(anchorComponents.count))
                == anchorComponents
        else {
            throw ManagedPathError(
                .outsideManagedRoot,
                path: canonicalRoot.path
            )
        }
        let missingRootComponents = Array(
            rootComponents.dropFirst(anchorComponents.count)
        )
        let secureFileSystem: SecureManagedFileSystem
        if missingRootComponents.isEmpty {
            secureFileSystem = try SecureManagedFileSystem(
                rootURL: canonicalRoot
            )
        } else {
            secureFileSystem = try SecureManagedFileSystem(
                anchorURL: context.identityAnchorURL,
                rootComponents: missingRootComponents,
                createIfMissing: true
            )
        }
        for target in managedTargets {
            try Task.checkCancellation()
            _ = try pathResolver.revalidateForMutation(target)
            let relative = try securePath(
                target.url,
                relativeTo: canonicalRoot
            )
            switch try secureFileSystem.itemState(at: relative) {
            case .missing:
                try secureFileSystem.createDirectory(at: relative)
            case .present(let identity):
                guard identity.kind == .directory else {
                    throw SecureManagedFileSystemError.unsupportedItem
                }
            }
            _ = try pathResolver.revalidateForMutation(target)
        }
    }

    private func securePath(
        _ url: URL,
        relativeTo root: URL
    ) throws -> SecureManagedPath {
        let rootComponents = root.standardizedFileURL.pathComponents
        let targetComponents = url.standardizedFileURL.pathComponents
        guard
            targetComponents.count > rootComponents.count,
            Array(targetComponents.prefix(rootComponents.count))
                == rootComponents
        else {
            throw ManagedPathError(.outsideManagedRoot, path: url.path)
        }
        return try SecureManagedPath(
            Array(targetComponents.dropFirst(rootComponents.count))
        )
    }

    private func preparedArguments(
        _ words: [String],
        resolution: UserDataDirectoryResolution,
        isolation: LaunchIsolationAnalysis
    ) -> [String] {
        guard let path = isolation.userDataURL?.path else {
            return words
        }
        var result = words
        if resolution.occurrences.isEmpty {
            if isolation.userData?.isManaged == true {
                result.append("--user-data-dir=\(path)")
            }
            return result
        }
        guard resolution.occurrences.count == 1 else { return result }

        var index = 0
        while index < result.count {
            if result[index].hasPrefix("--user-data-dir=") {
                result[index] = "--user-data-dir=\(path)"
                return result
            }
            if result[index] == "--user-data-dir",
               result.indices.contains(index + 1)
            {
                result[index + 1] = path
                return result
            }
            index += 1
        }
        return result
    }

    private func preparedEnvironmentAssignments(
        _ assignments: [StoredEnvironmentAssignment],
        isolation: LaunchIsolationAnalysis
    ) -> [StoredEnvironmentAssignment] {
        guard
            let codexHome = isolation.codexHome
        else {
            return assignments
        }
        let replacement = StoredEnvironmentAssignment(
            key: "CODEX_HOME",
            value: .literal(codexHome.url.path)
        )
        var result = assignments.filter { $0.key != "CODEX_HOME" }
        result.append(replacement)
        return result
    }

    private func previewEnvironmentAssignments(
        _ assignments: [StoredEnvironmentAssignment],
        unsetKeys: Set<String>,
        policy: ChildEnvironmentPolicy
    ) -> [StoredEnvironmentAssignment] {
        var effective = policy.baseEnvironment(
            processEnvironment: processEnvironment,
            identity: identity
        ).mapValues { StoredEnvironmentValue.literal($0) }
        for key in unsetKeys {
            effective.removeValue(forKey: key)
        }
        for assignment in assignments {
            effective[assignment.key] = assignment.value
        }
        return effective.keys.sorted().compactMap { key in
            effective[key].map {
                StoredEnvironmentAssignment(key: key, value: $0)
            }
        }
    }

    private func effectiveEnvironment(
        _ entries: [LaunchEnvironmentEntry]
    ) -> (
        assignments: [StoredEnvironmentAssignment],
        unsetKeys: Set<String>
    ) {
        var lastEntries: [String: (Int, LaunchEnvironmentOperation)] = [:]
        for (index, entry) in entries.enumerated() {
            lastEntries[entry.name] = (index, entry.operation)
        }
        let ordered = lastEntries.sorted { $0.value.0 < $1.value.0 }
        var assignments: [StoredEnvironmentAssignment] = []
        var unsetKeys: Set<String> = []
        for (key, indexedOperation) in ordered {
            switch indexedOperation.1 {
            case .set(let value):
                assignments.append(
                    StoredEnvironmentAssignment(
                        key: key,
                        value: StoredEnvironmentValue(storedText: value)
                    )
                )
            case .unset:
                unsetKeys.insert(key)
            }
        }
        return (assignments, unsetKeys)
    }

    private static func compilerDiagnostic(
        _ diagnostic: LaunchParsingDiagnostic
    ) -> LaunchCompilerDiagnostic {
        let overridable: Bool
        switch diagnostic.code {
        case .unmatchedSingleQuote,
             .unmatchedDoubleQuote,
             .trailingEscape,
             .invalidEnvironmentName,
             .malformedEnvironmentLine:
            overridable = true
        case .unsupportedControlCharacter,
             .blankUserDataDirectory,
             .missingUserDataDirectory,
             .duplicateUserDataDirectory,
             .duplicateEnvironmentName:
            overridable = false
        }
        return LaunchCompilerDiagnostic(
            code: .parsing(diagnostic.code),
            severity: diagnostic.severity,
            isOverridable: overridable,
            sourceRange: diagnostic.range,
            path: nil
        )
    }

    private static func fingerprint(
        _ source: LaunchConfigurationSource
    ) -> LaunchConfigurationFingerprint {
        var rows = [
            source.requestID.uuidString.lowercased(),
            source.applicationID.uuidString.lowercased(),
            source.applicationStorageID.uuidString.lowercased(),
            source.profileID.uuidString.lowercased(),
            source.profileStorageID.uuidString.lowercased(),
            String(source.configurationRevision),
            source.applicationURL.absoluteString,
            source.expectedBundleIdentifier ?? "",
            source.configuredBaseRoot,
            source.argumentsText,
            source.environmentText,
            source.isolationOwnership.userData.rawValue,
            source.isolationOwnership.codexHome.rawValue,
            source.childEnvironmentPolicy.rawValue,
            source.sensitiveEnvironmentKeys.sorted().joined(separator: "\u{1e}"),
        ]
        for peer in source.peerProfiles.sorted(by: {
            $0.profileID.uuidString < $1.profileID.uuidString
        }) {
            rows.append(peer.profileID.uuidString.lowercased())
            rows.append(peer.profileStorageID.uuidString.lowercased())
            rows.append(peer.argumentsText)
            rows.append(peer.environmentText)
            rows.append(peer.isolationOwnership.userData.rawValue)
            rows.append(peer.isolationOwnership.codexHome.rawValue)
        }
        let bytes = Data(rows.joined(separator: "\u{1f}").utf8)
        let digest = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }
            .joined()
        return LaunchConfigurationFingerprint(digest: digest)
    }
}
