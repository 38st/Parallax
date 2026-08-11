import Foundation

enum SettingsMutation: Equatable, Sendable {
    case replaceProfileTemplates([ProfileTemplate])
    case setDefaultBaseStoragePath(String)
    case setConfirmBeforeLaunch(Bool)
    case setAutomaticallyRecoverCrashedApps(Bool)
    case setAppearance(AppAppearance)
    case setProfileVisualIdentity(
        profileID: UUID,
        identity: ProfileInstanceVisualIdentity?
    )
    case resetAllProfileVisualIdentities

    func applying(to state: SettingsState) throws -> SettingsState {
        var templates = state.profileTemplates
        var basePath = state.defaultBaseStoragePath
        var confirm = state.confirmBeforeLaunch
        var automaticRecovery = state.automaticallyRecoverCrashedApps
        var appearance = state.appearance
        var visuals = state.profileVisualIdentities

        switch self {
        case .replaceProfileTemplates(let replacement):
            var identifiers = Set<UUID>()
            for template in replacement {
                guard identifiers.insert(template.id).inserted else {
                    throw SettingsMutationValidationError
                        .duplicateTemplateID(template.id)
                }
            }
            templates = replacement
        case .setDefaultBaseStoragePath(let value):
            basePath = value
        case .setConfirmBeforeLaunch(let value):
            confirm = value
        case .setAutomaticallyRecoverCrashedApps(let value):
            automaticRecovery = value
        case .setAppearance(let value):
            appearance = value
        case .setProfileVisualIdentity(let profileID, let identity):
            visuals[profileID] = identity
        case .resetAllProfileVisualIdentities:
            visuals = [:]
        }

        return SettingsState(
            profileTemplates: templates,
            defaultBaseStoragePath: basePath,
            confirmBeforeLaunch: confirm,
            automaticallyRecoverCrashedApps: automaticRecovery,
            appearance: appearance,
            profileVisualIdentities: visuals
        )
    }
}

enum SettingsMutationValidationError: Error, Equatable, Sendable {
    case duplicateTemplateID(UUID)
}

enum SettingsRuntimeMutationFailure: Error, Equatable, Sendable {
    case invalidMutation(SettingsMutationValidationError)
    case invalidRefreshedState(SettingsState.MappingError)
    case primaryChanged(SettingsRepositoryInspection)
    case commit(SettingsRepositoryMutationEvidence)
    case retryLimitExceeded(
        attempts: Int,
        lastConflict: SettingsRepositoryMutationEvidence
    )
    case unexpected(String)
}

enum SettingsMutationCoordinatorResult: Equatable, Sendable {
    case committed(SettingsState, SettingsRepositorySnapshot)
    case unchanged(SettingsState, SettingsRepositorySnapshot)
    case recoveryRequired(
        SettingsRuntimeMutationFailure,
        lastKnownState: SettingsState
    )
}

enum SettingsRuntimeContainerFailure: Error, Equatable, Sendable {
    case invalidURL(String)
    case systemCall(operation: String, code: Int32)
    case unsafeExistingItem(path: String)
    case mutationLock(SettingsRepositoryMutationLockFailure)
    case trustedContainer(TrustedParallaxContainerError)
}

enum SettingsRuntimeBootstrapRecovery: Equatable, Sendable {
    case container(SettingsRuntimeContainerFailure)
    case migration(SettingsMigrationCommitEvidence)

    var preservedPrimaryBytes: Data? {
        switch self {
        case .container:
            return nil
        case .migration(let evidence):
            if case .committedPublicationAndLock(let receipt, _) =
                evidence.failure
            {
                return receipt.snapshot.originalBytes
            }
            if let locked = evidence.lockedPrimary?.preservedPrimaryBytes {
                return locked
            }
            return evidence.planned.current.source.preservedPrimaryBytes
        }
    }
}

extension SettingsRepositoryInspection {
    var preservedPrimaryBytes: Data? {
        switch self {
        case .missing, .unavailable:
            return nil
        case .current(let snapshot):
            return snapshot.originalBytes
        case .future(_, let evidence):
            return evidence.originalBytes
        case .recoveryRequired(let failure, _):
            return failure.originalBytes
        }
    }
}

struct SettingsRuntime: Sendable {
    let initialState: SettingsState
    let initialSnapshot: SettingsRepositorySnapshot
    let migrationEvidence: SettingsMigrationEvidence
    let coordinator: SettingsMutationCoordinator
}

enum SettingsRuntimeBootstrapResult: Sendable {
    case ready(SettingsRuntime)
    case recoveryRequired(SettingsRuntimeBootstrapRecovery)
}

struct SettingsRuntimeBootstrapOutcome: Sendable {
    let result: SettingsRuntimeBootstrapResult
    let trustedContainer: TrustedParallaxContainer?
}
