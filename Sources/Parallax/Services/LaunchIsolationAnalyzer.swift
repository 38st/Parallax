import Foundation

struct LaunchIsolationAnalyzer {
    let pathResolver: ManagedPathResolver
    let healthService: LaunchHealthService
    let identity: ChildEnvironmentIdentity

    func analyze(
        source: LaunchConfigurationSource,
        userDataResolution: UserDataDirectoryResolution,
        effectiveAssignments: [StoredEnvironmentAssignment],
        managedPaths: ResolvedProfilePaths?,
        diagnostics: inout [LaunchCompilerDiagnostic]
    ) -> (
        isolation: LaunchIsolationAnalysis,
        profileHealth: ProfileHealthReport?
    ) {
        let isolation = isolationAnalysis(
            source: source,
            userDataResolution: userDataResolution,
            effectiveAssignments: effectiveAssignments,
            managedPaths: managedPaths,
            diagnostics: &diagnostics
        )
        return (
            isolation: isolation,
            profileHealth: profileHealth(
                source: source,
                isolation: isolation
            )
        )
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
            let externalPath: ExternalIsolationPath
            do {
                externalPath = try pathResolver
                    .resolveExternalPath(configuredPath)
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
               externalPath.requestedURL.path
                    == managedURL.standardizedFileURL.path
            {
                return .managed(managedURL)
            }
            return .external(externalPath)
        }
    }

    private func validatedExternalIsolation(
        _ configuredPath: String,
        diagnostics: inout [LaunchCompilerDiagnostic]
    ) -> LaunchIsolationPath? {
        do {
            return .external(
                try pathResolver.resolveExternalPath(configuredPath)
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
}
