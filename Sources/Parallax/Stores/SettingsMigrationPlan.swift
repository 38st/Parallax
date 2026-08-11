import Foundation

enum SettingsMigrationLegacyPayload: Equatable, Sendable {
    case profileTemplates
    case profileVisualIdentities
}

enum SettingsMigrationRecoveryReason: Equatable, Sendable {
    case currentPrimaryUnavailable(SettingsRepositoryUnavailable)
    case currentPrimaryFutureSchema(UInt64)
    case currentPrimaryCorrupt(SettingsDocumentCodecFailure)
    case currentPrimaryInvalidState(SettingsState.MappingError)
    case currentPrimaryUnexpectedMappingFailure(String)
    case legacySnapshotPartial([SettingsLegacySnapshotIssue])
    case legacyAssessmentInconsistent
    case legacyPayloadPairingInconsistent(SettingsMigrationLegacyPayload)
    case legacyFieldUnavailable(
        key: SettingsLegacyKey,
        failure: SettingsLegacySourceFailure
    )
    case legacyFieldWrongType(
        key: SettingsLegacyKey,
        actual: SettingsLegacyRawType
    )
    case legacyFieldOversized(
        key: SettingsLegacyKey,
        violations: [SettingsLegacyLimitViolation]
    )
    case legacyPayloadInvalid(
        payload: SettingsMigrationLegacyPayload,
        issue: SettingsLegacySnapshotDecodeIssue
    )
    case legacyTargetInvalid(SettingsDocumentCodecIssue)
    case conflictingTemplateForms
    case duplicateTemplateID(
        sourceIndex: Int,
        firstIndex: Int,
        id: UUID
    )
    case templateUnknownMembers(sourceIndex: Int, count: Int)
    case visualUnknownMembers(entryIndex: Int, count: Int)
    case noncanonicalVisualKey(entryIndex: Int, key: String, id: UUID)
    case nonUUIDVisualKey(entryIndex: Int, key: String)
    case duplicateVisualID(
        entryIndex: Int,
        firstIndex: Int,
        id: UUID
    )
    case unsupportedAppearance(String)
    case unsupportedVisualValue(
        entryIndex: Int,
        symbol: String,
        color: String
    )
}

struct SettingsMigrationEvidence: Equatable, Sendable {
    let current: SettingsCurrentMigrationAssessment
    let legacy: SettingsLegacyMigrationAssessment
}

struct SettingsMigrationReadyPlan: Equatable, Sendable {
    let state: SettingsState
    let evidence: SettingsMigrationEvidence
}

struct SettingsMigrationRecoveryPlan: Equatable, Sendable {
    let reasons: [SettingsMigrationRecoveryReason]
    let evidence: SettingsMigrationEvidence
}

enum SettingsMigrationPlan: Equatable, Sendable {
    case useCurrent(SettingsMigrationReadyPlan)
    case publishLegacy(SettingsMigrationReadyPlan)
    case publishDefaults(SettingsMigrationReadyPlan)
    case recoveryRequired(SettingsMigrationRecoveryPlan)
}
