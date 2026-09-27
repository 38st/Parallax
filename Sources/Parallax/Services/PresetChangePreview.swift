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

    let sourceBaseStoragePath: String?
    let sourceProfiles: [LaunchProfile]
    fileprivate let refreshedProfiles: [LaunchProfile]
    let sourceSignature: String
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

    struct FieldPlan {
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
}
