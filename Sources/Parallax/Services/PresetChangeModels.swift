import Foundation

enum PresetGeneratedValueKind: String, Equatable, Sendable {
    case userDataDirectory
    case codexHome
}

enum PresetGeneratedValueDisposition: String, Equatable, Sendable {
    case added
    case changed
    case retained
    case removed
}

struct PresetGeneratedPaths: Equatable, Sendable {
    let profileID: UUID
    let profileStorageID: UUID
    let userDataDirectory: String
    let codexHome: String
}

struct PresetGeneratedValueChange: Equatable, Sendable {
    let profileID: UUID
    let profileStorageID: UUID
    let profileName: String
    let kind: PresetGeneratedValueKind
    let disposition: PresetGeneratedValueDisposition
    let previousValue: String?
    let resultingValue: String?
    let priorOwnership: IsolationPathOwnership
    let resultingOwnership: IsolationPathOwnership

    var changesStoredConfiguration: Bool {
        switch disposition {
        case .added, .changed, .removed:
            true
        case .retained:
            false
        }
    }
}

enum PresetGeneratedRefreshAcknowledgement: Equatable, Sendable {
    /// The caller displayed the preview and the user intentionally chose to
    /// apply exactly its listed generated-value changes.
    case applyListedGeneratedValueChanges
}

enum PresetChangePreviewError: LocalizedError, Equatable, Sendable {
    case duplicateGeneratedPaths(profileID: UUID)
    case missingGeneratedPaths(profileID: UUID)
    case generatedPathIdentityMismatch(profileID: UUID)
    case invalidGeneratedPath(profileID: UUID, kind: PresetGeneratedValueKind)
    case invalidGeneratedArguments(profileID: UUID)
    case invalidRefreshAuthorization
    case stalePreview

    var errorDescription: String? {
        switch self {
        case .duplicateGeneratedPaths:
            String(
                localized:
                    "Recommended profile paths were supplied more than once."
            )
        case .missingGeneratedPaths:
            String(
                localized:
                    "Recommended profile paths are unavailable. Preview the preset change again."
            )
        case .generatedPathIdentityMismatch:
            String(
                localized:
                    "Recommended profile paths no longer match the profile storage identity."
            )
        case .invalidGeneratedPath:
            String(
                localized:
                    "A recommended profile path is not an absolute, traversal-free path."
            )
        case .invalidGeneratedArguments:
            String(
                localized:
                    "Generated launch arguments contain syntax errors and cannot be refreshed without losing information."
            )
        case .invalidRefreshAuthorization:
            String(
                localized:
                    "The recommended-settings authorization does not match this preview."
            )
        case .stalePreview:
            String(
                localized:
                    "The preset or profile configuration changed after the preview. Preview it again before applying."
            )
        }
    }
}
