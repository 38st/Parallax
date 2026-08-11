import Foundation

struct PresetChangePreview: Equatable, Sendable {
    let id: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let sourcePreset: AppPreset
    let sourceResolvedPreset: AppPreset
    let targetPreset: AppPreset
    let targetResolvedPreset: AppPreset
    let changes: [PresetGeneratedValueChange]

    fileprivate let sourceBaseStoragePath: String?
    fileprivate let sourceProfiles: [LaunchProfile]
    fileprivate let refreshedProfiles: [LaunchProfile]
    fileprivate let sourceSignature: String
}

struct PresetChangeRefreshAuthorization: Equatable, Sendable {
    fileprivate let previewID: UUID
    fileprivate let sourceSignature: String
    let acknowledgement: PresetGeneratedRefreshAcknowledgement
}

/// Pure preset-change planning. Previewing never edits metadata, creates
/// directories, or touches profile data. Explicit and legacy-ambiguous
/// isolation values are retained verbatim; only generated values are eligible
/// for automatic removal or replacement.
struct PresetChangePreviewService: Sendable {
    private let makePreviewID: @Sendable () -> UUID

    init(
        makePreviewID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.makePreviewID = makePreviewID
    }

    func preview(
        application: ManagedApplication,
        targetPreset: AppPreset,
        generatedPaths: [PresetGeneratedPaths]
    ) throws -> PresetChangePreview {
        let pathsByProfile = try indexedPaths(generatedPaths)
        let sourceResolvedPreset = resolvedPreset(
            application.preset,
            application: application
        )
        let targetResolvedPreset = resolvedPreset(
            targetPreset,
            application: application
        )
        var changes: [PresetGeneratedValueChange] = []
        var refreshedProfiles: [LaunchProfile] = []

        for profile in application.profiles {
            let userDataPlan = try userDataPlan(
                profile: profile,
                targetPreset: targetResolvedPreset,
                pathsByProfile: pathsByProfile
            )
            let codexHomePlan = try codexHomePlan(
                profile: profile,
                targetPreset: targetResolvedPreset,
                pathsByProfile: pathsByProfile
            )
            if let change = userDataPlan.change {
                changes.append(change)
            }
            if let change = codexHomePlan.change {
                changes.append(change)
            }

            var refreshed = profile
            if let argumentsText = userDataPlan.refreshedText {
                refreshed.argumentsText = argumentsText
                refreshed.isolationOwnership.userData =
                    userDataPlan.resultingOwnership
            }
            if let environmentText = codexHomePlan.refreshedText {
                refreshed.environmentText = environmentText
                refreshed.isolationOwnership.codexHome =
                    codexHomePlan.resultingOwnership
            }
            refreshedProfiles.append(refreshed)
        }

        let signature = try sourceSignature(
            applicationID: application.id,
            applicationStorageID: application.storageID,
            sourcePreset: application.preset,
            sourceBaseStoragePath: application.baseStoragePath,
            sourceProfiles: application.profiles
        )
        return PresetChangePreview(
            id: makePreviewID(),
            applicationID: application.id,
            applicationStorageID: application.storageID,
            sourcePreset: application.preset,
            sourceResolvedPreset: sourceResolvedPreset,
            targetPreset: targetPreset,
            targetResolvedPreset: targetResolvedPreset,
            changes: changes,
            sourceBaseStoragePath: application.baseStoragePath,
            sourceProfiles: application.profiles,
            refreshedProfiles: refreshedProfiles,
            sourceSignature: signature
        )
    }

    /// Applies only the preset field. All current metadata and every profile
    /// remain byte-for-byte/model-for-model unchanged.
    func applyingPresetMetadata(
        _ preview: PresetChangePreview,
        to currentApplication: ManagedApplication
    ) throws -> ManagedApplication {
        try validateCurrentSource(
            preview,
            currentApplication: currentApplication,
            requireSameResolvedTarget: false
        )
        var updated = currentApplication
        updated.preset = preview.targetPreset
        return updated
    }

    func authorizeRefresh(
        _ preview: PresetChangePreview,
        acknowledging acknowledgement:
            PresetGeneratedRefreshAcknowledgement
    ) -> PresetChangeRefreshAuthorization {
        PresetChangeRefreshAuthorization(
            previewID: preview.id,
            sourceSignature: preview.sourceSignature,
            acknowledgement: acknowledgement
        )
    }

    /// Dedicated intentional action. It applies only the previewed generated
    /// values and the target preset, while preserving current display/path
    /// metadata that does not affect managed profile path derivation.
    func applyingAuthorizedRefresh(
        _ preview: PresetChangePreview,
        authorization: PresetChangeRefreshAuthorization,
        to currentApplication: ManagedApplication
    ) throws -> ManagedApplication {
        guard
            authorization.previewID == preview.id,
            authorization.sourceSignature == preview.sourceSignature,
            authorization.acknowledgement
                == .applyListedGeneratedValueChanges
        else {
            throw PresetChangePreviewError.invalidRefreshAuthorization
        }
        try validateCurrentSource(
            preview,
            currentApplication: currentApplication,
            requireSameResolvedTarget: true
        )
        var updated = currentApplication
        updated.preset = preview.targetPreset
        updated.profiles = preview.refreshedProfiles
        return updated
    }

    private struct FieldPlan {
        let change: PresetGeneratedValueChange?
        let refreshedText: String?
        let resultingOwnership: IsolationPathOwnership
    }

    private func userDataPlan(
        profile: LaunchProfile,
        targetPreset: AppPreset,
        pathsByProfile: [UUID: PresetGeneratedPaths]
    ) throws -> FieldPlan {
        let parsed = LaunchArgumentParser.parse(profile.argumentsText)
        let resolution = UserDataDirectoryOptionResolver.resolve(
            in: parsed.tokens
        )
        let hasConfiguration = !resolution.occurrences.isEmpty
        let previousValue = resolution.resolvedValue
        let ownership = profile.isolationOwnership.userData

        if ownership != .generated, hasConfiguration {
            return retainedPlan(
                profile: profile,
                kind: .userDataDirectory,
                previousValue: previousValue,
                ownership: ownership
            )
        }
        guard targetPreset.supportsUserDataDir else {
            guard ownership == .generated else {
                return FieldPlan(
                    change: nil,
                    refreshedText: nil,
                    resultingOwnership: ownership
                )
            }
            guard !parsed.hasErrors else {
                throw PresetChangePreviewError
                    .invalidGeneratedArguments(profileID: profile.id)
            }
            return FieldPlan(
                change: change(
                    profile: profile,
                    kind: .userDataDirectory,
                    disposition: .removed,
                    previousValue: previousValue,
                    resultingValue: nil,
                    priorOwnership: ownership,
                    resultingOwnership: .explicit
                ),
                refreshedText: settingUserDataDirectory(
                    nil,
                    parsedWords: parsed.words
                ),
                resultingOwnership: .explicit
            )
        }

        let recommended = try requiredPath(
            for: profile,
            kind: .userDataDirectory,
            pathsByProfile: pathsByProfile
        )
        if ownership == .generated,
           resolution.occurrences.count == 1,
           previousValue == recommended
        {
            return retainedPlan(
                profile: profile,
                kind: .userDataDirectory,
                previousValue: previousValue,
                ownership: .generated
            )
        }
        guard !parsed.hasErrors else {
            throw PresetChangePreviewError
                .invalidGeneratedArguments(profileID: profile.id)
        }
        let disposition: PresetGeneratedValueDisposition =
            hasConfiguration ? .changed : .added
        return FieldPlan(
            change: change(
                profile: profile,
                kind: .userDataDirectory,
                disposition: disposition,
                previousValue: previousValue,
                resultingValue: recommended,
                priorOwnership: ownership,
                resultingOwnership: .generated
            ),
            refreshedText: settingUserDataDirectory(
                recommended,
                parsedWords: parsed.words
            ),
            resultingOwnership: .generated
        )
    }

    private func codexHomePlan(
        profile: LaunchProfile,
        targetPreset: AppPreset,
        pathsByProfile: [UUID: PresetGeneratedPaths]
    ) throws -> FieldPlan {
        let parsed = LaunchEnvironmentParser.parse(
            profile.environmentText
        )
        let entries = parsed.entries.filter { $0.name == "CODEX_HOME" }
        let operation = parsed.effectiveOperations["CODEX_HOME"]
        let hasConfiguration = operation != nil
        let previousValue: String? = if case let .set(value) = operation {
            value
        } else {
            nil
        }
        let ownership = profile.isolationOwnership.codexHome

        if ownership != .generated, hasConfiguration {
            return retainedPlan(
                profile: profile,
                kind: .codexHome,
                previousValue: previousValue,
                ownership: ownership
            )
        }
        guard targetPreset.needsCodexHome else {
            guard ownership == .generated else {
                return FieldPlan(
                    change: nil,
                    refreshedText: nil,
                    resultingOwnership: ownership
                )
            }
            return FieldPlan(
                change: change(
                    profile: profile,
                    kind: .codexHome,
                    disposition: .removed,
                    previousValue: previousValue,
                    resultingValue: nil,
                    priorOwnership: ownership,
                    resultingOwnership: .explicit
                ),
                refreshedText: settingCodexHome(
                    nil,
                    in: profile.environmentText,
                    entries: entries
                ),
                resultingOwnership: .explicit
            )
        }

        let recommended = try requiredPath(
            for: profile,
            kind: .codexHome,
            pathsByProfile: pathsByProfile
        )
        if ownership == .generated,
           entries.count == 1,
           previousValue == recommended
        {
            return retainedPlan(
                profile: profile,
                kind: .codexHome,
                previousValue: previousValue,
                ownership: .generated
            )
        }
        let disposition: PresetGeneratedValueDisposition =
            hasConfiguration ? .changed : .added
        return FieldPlan(
            change: change(
                profile: profile,
                kind: .codexHome,
                disposition: disposition,
                previousValue: previousValue,
                resultingValue: recommended,
                priorOwnership: ownership,
                resultingOwnership: .generated
            ),
            refreshedText: settingCodexHome(
                recommended,
                in: profile.environmentText,
                entries: entries
            ),
            resultingOwnership: .generated
        )
    }

    private func retainedPlan(
        profile: LaunchProfile,
        kind: PresetGeneratedValueKind,
        previousValue: String?,
        ownership: IsolationPathOwnership
    ) -> FieldPlan {
        FieldPlan(
            change: change(
                profile: profile,
                kind: kind,
                disposition: .retained,
                previousValue: previousValue,
                resultingValue: previousValue,
                priorOwnership: ownership,
                resultingOwnership: ownership
            ),
            refreshedText: nil,
            resultingOwnership: ownership
        )
    }

    private func change(
        profile: LaunchProfile,
        kind: PresetGeneratedValueKind,
        disposition: PresetGeneratedValueDisposition,
        previousValue: String?,
        resultingValue: String?,
        priorOwnership: IsolationPathOwnership,
        resultingOwnership: IsolationPathOwnership
    ) -> PresetGeneratedValueChange {
        PresetGeneratedValueChange(
            profileID: profile.id,
            profileStorageID: profile.storageID,
            profileName: profile.name,
            kind: kind,
            disposition: disposition,
            previousValue: previousValue,
            resultingValue: resultingValue,
            priorOwnership: priorOwnership,
            resultingOwnership: resultingOwnership
        )
    }

    private func indexedPaths(
        _ paths: [PresetGeneratedPaths]
    ) throws -> [UUID: PresetGeneratedPaths] {
        var result: [UUID: PresetGeneratedPaths] = [:]
        for path in paths {
            guard result[path.profileID] == nil else {
                throw PresetChangePreviewError
                    .duplicateGeneratedPaths(profileID: path.profileID)
            }
            result[path.profileID] = path
        }
        return result
    }

    private func requiredPath(
        for profile: LaunchProfile,
        kind: PresetGeneratedValueKind,
        pathsByProfile: [UUID: PresetGeneratedPaths]
    ) throws -> String {
        guard let paths = pathsByProfile[profile.id] else {
            throw PresetChangePreviewError
                .missingGeneratedPaths(profileID: profile.id)
        }
        guard paths.profileStorageID == profile.storageID else {
            throw PresetChangePreviewError
                .generatedPathIdentityMismatch(profileID: profile.id)
        }
        let value = switch kind {
        case .userDataDirectory:
            paths.userDataDirectory
        case .codexHome:
            paths.codexHome
        }
        guard isSafeAbsolutePath(value) else {
            throw PresetChangePreviewError.invalidGeneratedPath(
                profileID: profile.id,
                kind: kind
            )
        }
        return value
    }

    private func settingUserDataDirectory(
        _ value: String?,
        parsedWords: [String]
    ) -> String {
        var retained: [String] = []
        var index = 0
        while index < parsedWords.count {
            let word = parsedWords[index]
            if word.hasPrefix("--user-data-dir=") {
                index += 1
                continue
            }
            if word == "--user-data-dir" {
                if parsedWords.indices.contains(index + 1),
                   !parsedWords[index + 1].hasPrefix("--")
                {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            retained.append(word)
            index += 1
        }
        if let value {
            retained.append("--user-data-dir=\(value)")
        }
        return LaunchArgumentParser.serialize(retained)
    }

    private func settingCodexHome(
        _ value: String?,
        in text: String,
        entries: [LaunchEnvironmentEntry]
    ) -> String {
        let removedLines = Set(entries.map(\.range.start.line))
        var lines = text.components(separatedBy: "\n")
            .enumerated()
            .compactMap { index, line in
                removedLines.contains(index + 1) ? nil : line
            }
        while lines.last?.isEmpty == true {
            lines.removeLast()
        }
        if let value {
            lines.append("CODEX_HOME=\(value)")
        }
        return lines.joined(separator: "\n")
    }

    private func validateCurrentSource(
        _ preview: PresetChangePreview,
        currentApplication: ManagedApplication,
        requireSameResolvedTarget: Bool
    ) throws {
        guard
            currentApplication.id == preview.applicationID,
            currentApplication.storageID == preview.applicationStorageID,
            currentApplication.preset == preview.sourcePreset,
            currentApplication.baseStoragePath
                == preview.sourceBaseStoragePath,
            currentApplication.profiles == preview.sourceProfiles,
            try sourceSignature(
                applicationID: currentApplication.id,
                applicationStorageID: currentApplication.storageID,
                sourcePreset: currentApplication.preset,
                sourceBaseStoragePath: currentApplication.baseStoragePath,
                sourceProfiles: currentApplication.profiles
            ) == preview.sourceSignature
        else {
            throw PresetChangePreviewError.stalePreview
        }
        if requireSameResolvedTarget {
            guard resolvedPreset(
                preview.targetPreset,
                application: currentApplication
            ) == preview.targetResolvedPreset else {
                throw PresetChangePreviewError.stalePreview
            }
        }
    }

    private func resolvedPreset(
        _ preset: AppPreset,
        application: ManagedApplication
    ) -> AppPreset {
        preset == .automatic
            ? AppPreset.detected(
                displayName: application.displayName,
                bundleIdentifier: application.bundleIdentifier
            )
            : preset
    }

    private func isSafeAbsolutePath(_ path: String) -> Bool {
        guard
            !path.isEmpty,
            !path.contains("\0"),
            (path as NSString).isAbsolutePath
        else {
            return false
        }
        let components = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard components.first == "" else { return false }
        return !components.dropFirst().contains {
            $0.isEmpty || $0 == "." || $0 == ".."
        }
    }

    private struct SignatureSource: Encodable {
        let applicationID: UUID
        let applicationStorageID: UUID
        let sourcePreset: AppPreset
        let sourceBaseStoragePath: String?
        let sourceProfiles: [LaunchProfile]
    }

    private func sourceSignature(
        applicationID: UUID,
        applicationStorageID: UUID,
        sourcePreset: AppPreset,
        sourceBaseStoragePath: String?,
        sourceProfiles: [LaunchProfile]
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(
            SignatureSource(
                applicationID: applicationID,
                applicationStorageID: applicationStorageID,
                sourcePreset: sourcePreset,
                sourceBaseStoragePath: sourceBaseStoragePath,
                sourceProfiles: sourceProfiles
            )
        )
        return LibraryPersistence.sha256(bytes)
    }
}
