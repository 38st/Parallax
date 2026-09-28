import Foundation

struct LaunchIsolationAnalyzer {
    let pathResolver: ManagedPathResolver
    let healthService: LaunchHealthService
    let identity: ChildEnvironmentIdentity
    var inheritedFirefoxProfilePath: String? = nil

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

        var claudeConfig: LaunchIsolationPath?
        if let assignment = effectiveAssignments.first(where: {
            $0.key == "CLAUDE_CONFIG_DIR"
        }), case .literal(let value) = assignment.value {
            var claudeDiagnostics: [LaunchCompilerDiagnostic] = []
            claudeConfig = classifyIsolation(
                ownership: .legacyUnknown,
                configuredPath: expander.environmentValue(value, forKey: "CLAUDE_CONFIG_DIR"),
                managedURL: managedPaths?.claudeConfig.url,
                diagnostics: &claudeDiagnostics
            )
            // Custom presets may use arbitrary environment values. Track a
            // resolvable path, but require one only for the Claude preset.
            if source.requiresClaudeConfigIsolation {
                diagnostics.append(contentsOf: claudeDiagnostics)
            }
        } else if source.requiresClaudeConfigIsolation {
            diagnostics.append(
                LaunchCompilerDiagnostic(
                    code: .unresolvedIsolationPath,
                    severity: .error,
                    isOverridable: false,
                    sourceRange: nil,
                    path: nil
                )
            )
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
        var result = LaunchIsolationAnalysis(
            userData: userData,
            codexHome: codexHome,
            claudeConfig: claudeConfig
        )
        let parsed = LaunchArgumentParser.parse(source.argumentsText)
        for folder in PresetIsolationFolder.allCases where folder.applies(to: source.preset) {
            let option = folder.resolve(in: parsed.words)
            if let diagnostic = folder.diagnostic(in: parsed) {
                diagnostics.append(diagnostic)
                continue
            }
            guard option.isPresent else { continue }
            if folder == .firefoxProfile,
               (inheritedFirefoxProfilePath != nil || PresetIsolationFolder.hasFirefoxSelection(argumentsText: source.argumentsText, environmentText: source.environmentText)) {
                if folder.ownership(in: source.isolationOwnership) == .generated {
                    diagnostics.append(LaunchCompilerDiagnostic(
                        code: .conflictingFirefoxProfileSelection, severity: .error, isOverridable: false,
                        sourceRange: option.ranges.first.map { parsed.tokens[$0.lowerBound].range }, path: nil))
                }
                continue
            }
            let path = option.value.map { value in
                value == "~" ? identity.homeDirectory
                    : value.hasPrefix("~/") ? identity.homeDirectory + String(value.dropFirst()) : value
            }
            let managedURL = managedPaths.map { folder.managedPath(in: $0).url }
            // Exact managed-folder values are safe to manage even when entered by the user.
            let ownership = folder.ownership(in: source.isolationOwnership)
            if ownership != .generated, let path, let managedURL,
               let external = try? pathResolver.resolveExternalPath(path),
               let managed = try? pathResolver.resolveExternalPath(managedURL.path),
               external.canonicalURL.path == managed.canonicalURL.path {
                result.presetFolders[folder] = .managed(managedURL)
            } else {
                result.presetFolders[folder] = classifyIsolation(
                    ownership: ownership, configuredPath: path, managedURL: managedURL,
                    diagnostics: &diagnostics)
            }
        }
        return result
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
        if source.requiresClaudeConfigIsolation, let claudeConfig = isolation.claudeConfig {
            inputs.append(
                ProfileIsolationHealthInput(
                    role: claudeConfig.isManaged
                        ? .managedClaudeConfig : .externalClaudeConfig,
                    source: claudeConfig.isManaged
                        ? .managedClaudeConfig
                        : .external(claudeConfig.url.path)
                )
            )
        }
        for folder in PresetIsolationFolder.allCases {
            if let path = isolation.presetFolders[folder] {
                inputs.append(ProfileIsolationHealthInput(
                    role: path.isManaged ? folder.managedRole : folder.externalRole,
                    source: path.isManaged ? .managedPresetFolder(folder) : .external(path.url.path)
                ))
            }
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

    static func presetHealthPaths(
        preset: AppPreset, argumentsText: String, environmentText: String = "",
        ownership: ProfileIsolationOwnership = .explicit, homeDirectory: String
    ) -> [ProfileIsolationHealthInput] {
        let words = LaunchArgumentParser.parse(argumentsText).words
        return PresetIsolationFolder.allCases.filter { $0.applies(to: preset) }.compactMap { folder in
            let option = folder.resolve(in: words)
            guard option.isPresent else { return nil }
            if folder == .firefoxProfile,
               PresetIsolationFolder.hasFirefoxSelection(argumentsText: argumentsText, environmentText: environmentText) { return nil }
            if folder.ownership(in: ownership) == .generated {
                return ProfileIsolationHealthInput(role: folder.managedRole, source: .managedPresetFolder(folder))
            }
            let value = option.value ?? ""
            let expanded = value == "~" ? homeDirectory
                : value.hasPrefix("~/") ? homeDirectory + String(value.dropFirst()) : value
            return ProfileIsolationHealthInput(role: folder.externalRole, source: .external(expanded))
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
        if source.requiresClaudeConfigIsolation,
           let configured = LaunchEnvironmentParser.parse(
               peer.environmentText
           ).effectiveValues["CLAUDE_CONFIG_DIR"],
           case .literal(let value) = StoredEnvironmentValue(storedText: configured)
        {
            paths.append(
                ProfileIsolationHealthInput(
                    role: .externalClaudeConfig,
                    source: .external(
                        expander.environmentValue(value, forKey: "CLAUDE_CONFIG_DIR")
                    )
                )
            )
        }
        paths.append(contentsOf: Self.presetHealthPaths(
            preset: source.preset, argumentsText: peer.argumentsText, environmentText: peer.environmentText,
            ownership: peer.isolationOwnership, homeDirectory: identity.homeDirectory
        ))
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
