import Foundation

extension PresetChangePreviewService {
    func retainedPlan(
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

    func change(
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

    func indexedPaths(
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

    func requiredPath(
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
        case .firefoxProfile:
            paths.firefoxProfile
        case .extensions:
            paths.extensions
        }
        guard isSafeAbsolutePath(value) else {
            throw PresetChangePreviewError.invalidGeneratedPath(
                profileID: profile.id,
                kind: kind
            )
        }
        return value
    }
    func presetFolderPlan(
        _ folder: PresetIsolationFolder, profile: LaunchProfile, targetPreset: AppPreset,
        pathsByProfile: [UUID: PresetGeneratedPaths]
    ) throws -> FieldPlan {
        let kind: PresetGeneratedValueKind = folder == .firefoxProfile ? .firefoxProfile : .extensions
        let option = folder.resolve(in: LaunchArgumentParser.parse(profile.argumentsText).words)
        let ownership = folder.ownership(in: profile.isolationOwnership)
        if (ownership != .generated && option.isPresent)
            || (folder == .firefoxProfile && PresetIsolationFolder.hasFirefoxSelection(
                argumentsText: profile.argumentsText, environmentText: profile.environmentText)) {
            return retainedPlan(profile: profile, kind: kind, previousValue: option.value, ownership: ownership)
        }
        guard folder.applies(to: targetPreset) else {
            guard ownership == .generated else {
                return FieldPlan(change: nil, refreshedText: nil, resultingOwnership: ownership)
            }
            return FieldPlan(change: change(profile: profile, kind: kind, disposition: .removed,
                previousValue: option.value, resultingValue: nil, priorOwnership: ownership, resultingOwnership: .explicit),
                refreshedText: try folder.setting(nil, in: profile.argumentsText), resultingOwnership: .explicit)
        }
        let path = try requiredPath(for: profile, kind: kind, pathsByProfile: pathsByProfile)
        let text = try folder.setting(path, in: profile.argumentsText)
        return FieldPlan(change: change(profile: profile, kind: kind,
            disposition: text == profile.argumentsText ? .retained : option.isPresent ? .changed : .added,
            previousValue: option.value, resultingValue: path, priorOwnership: ownership, resultingOwnership: .generated),
            refreshedText: text, resultingOwnership: .generated)
    }

}
