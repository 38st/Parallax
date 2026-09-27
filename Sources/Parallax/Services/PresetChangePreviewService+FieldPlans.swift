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
        }
        guard isSafeAbsolutePath(value) else {
            throw PresetChangePreviewError.invalidGeneratedPath(
                profileID: profile.id,
                kind: kind
            )
        }
        return value
    }
}
