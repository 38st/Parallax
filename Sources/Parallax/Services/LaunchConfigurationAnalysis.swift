import Foundation

struct LaunchConfigurationAnalysisContext: Sendable {
    let analysis: LaunchAnalysis
    let managedPaths: ResolvedProfilePaths?
    let assignments: [StoredEnvironmentAssignment]
    let unsetKeys: Set<String>
}
struct LaunchConfigurationAnalyzer {
    let pathResolver: ManagedPathResolver
    let healthService: LaunchHealthService
    let identity: ChildEnvironmentIdentity
    let processEnvironment: [String: String]

    func analyze(
        for source: LaunchConfigurationSource
    ) -> LaunchConfigurationAnalysisContext {
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
        let fingerprint =
            LaunchConfigurationFingerprintFactory.fingerprint(source)
        var diagnostics = (
            argumentResult.diagnostics + userDataResolution.diagnostics
                + environmentResult.diagnostics
        ).map(LaunchConfigurationProjection.compilerDiagnostic)
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

        let assignmentsAndUnsets =
            LaunchConfigurationProjection.effectiveEnvironment(
            environmentResult.entries
        )
        let isolationResult = LaunchIsolationAnalyzer(
            pathResolver: pathResolver,
            healthService: healthService,
            identity: identity
        ).analyze(
            source: source,
            userDataResolution: userDataResolution,
            effectiveAssignments: assignmentsAndUnsets.assignments,
            managedPaths: managedPaths,
            diagnostics: &diagnostics
        )
        let isolation = isolationResult.isolation
        let profileHealth = isolationResult.profileHealth
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

        let effectiveAssignments =
            LaunchConfigurationProjection.preparedEnvironmentAssignments(
            assignmentsAndUnsets.assignments,
            isolation: isolation
        )
        let effectiveUnsetKeys =
            isolation.codexHome?.isManaged == true
            ? assignmentsAndUnsets.unsetKeys.subtracting(["CODEX_HOME"])
            : assignmentsAndUnsets.unsetKeys
        let preview = RedactedLaunchPreview(
            arguments: LaunchConfigurationProjection.preparedArguments(
                SensitiveLaunchArgumentPolicy().redactedWords(
                    in: argumentResult.tokens
                ),
                resolution: userDataResolution,
                isolation: isolation
            ),
            environment: EnvironmentDisclosurePolicy(
                explicitSensitiveKeys: Set(source.sensitiveEnvironmentKeys)
            ).preview(
                LaunchConfigurationProjection.previewEnvironmentAssignments(
                    effectiveAssignments,
                    unsetKeys: effectiveUnsetKeys,
                    policy: source.childEnvironmentPolicy,
                    processEnvironment: processEnvironment,
                    identity: identity
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
        return LaunchConfigurationAnalysisContext(
            analysis: analysis,
            managedPaths: managedPaths,
            assignments: effectiveAssignments,
            unsetKeys: effectiveUnsetKeys
        )
    }
}
