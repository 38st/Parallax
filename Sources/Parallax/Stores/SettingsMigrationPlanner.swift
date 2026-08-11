import Foundation

/// Selects a settings authority and constructs a behavior-preserving target.
/// This type performs no capture, file access, publication, or preference
/// mutation. Its attached assessments remain the evidence authority for a
/// later locked recapture and commit.
struct SettingsMigrationPlanner: Sendable {
    let current: SettingsCurrentMigrationAssessment
    let legacy: SettingsLegacyMigrationAssessment

    func plan() -> SettingsMigrationPlan {
        let evidence = SettingsMigrationEvidence(
            current: current,
            legacy: legacy
        )
        switch current.source {
        case .current(let snapshot):
            do {
                return .useCurrent(
                    .init(
                        state: try SettingsState(document: snapshot.document),
                        evidence: evidence
                    )
                )
            } catch let error as SettingsState.MappingError {
                return recovery(
                    [.currentPrimaryInvalidState(error)],
                    evidence: evidence
                )
            } catch {
                return recovery(
                    [
                        .currentPrimaryUnexpectedMappingFailure(
                            String(describing: error)
                        ),
                    ],
                    evidence: evidence
                )
            }
        case .future(let schemaVersion, _):
            return recovery(
                [.currentPrimaryFutureSchema(schemaVersion)],
                evidence: evidence
            )
        case .recoveryRequired(let failure, _):
            return recovery(
                [.currentPrimaryCorrupt(failure)],
                evidence: evidence
            )
        case .unavailable(let failure):
            return recovery(
                [.currentPrimaryUnavailable(failure)],
                evidence: evidence
            )
        case .missing:
            return legacyPlan(evidence: evidence)
        }
    }

    private func legacyPlan(
        evidence: SettingsMigrationEvidence
    ) -> SettingsMigrationPlan {
        var reasons: [SettingsMigrationRecoveryReason] = []
        validateLegacyEnvelope(into: &reasons)
        validateTemplates(into: &reasons)
        validateVisuals(into: &reasons)
        guard reasons.isEmpty else {
            return recovery(reasons, evidence: evidence)
        }

        guard let state = materializedLegacyState() else {
            return recovery(
                [.legacyAssessmentInconsistent],
                evidence: evidence
            )
        }
        do {
            _ = try SettingsDocumentCodec().encode(
                state.document(revision: .zero)
            )
        } catch let issue as SettingsDocumentCodecIssue {
            return recovery(
                [.legacyTargetInvalid(issue)],
                evidence: evidence
            )
        } catch {
            return recovery(
                [.legacyAssessmentInconsistent],
                evidence: evidence
            )
        }
        let ready = SettingsMigrationReadyPlan(
            state: state,
            evidence: evidence
        )
        return hasRetainedLegacyValue ? .publishLegacy(ready)
            : .publishDefaults(ready)
    }

    private func validateLegacyEnvelope(
        into reasons: inout [SettingsMigrationRecoveryReason]
    ) {
        if current.presence != .absent {
            reasons.append(.legacyAssessmentInconsistent)
        }
        switch legacy.source.source.completion {
        case .complete:
            break
        case .partial(let issues):
            reasons.append(.legacySnapshotPartial(issues))
        }
        if legacy.structuredTemplatePairing == .inconsistent {
            reasons.append(
                .legacyPayloadPairingInconsistent(.profileTemplates)
            )
        }
        if legacy.visualPairing == .inconsistent {
            reasons.append(
                .legacyPayloadPairingInconsistent(
                    .profileVisualIdentities
                )
            )
        }

        appendFieldIssue(
            legacy.source.source.profileTemplates,
            key: .profileTemplates,
            to: &reasons
        )
        appendFieldIssue(
            legacy.source.source.legacyProfileTemplateNames,
            key: .legacyProfileTemplateNames,
            to: &reasons
        )
        appendFieldIssue(
            legacy.source.source.defaultBaseStoragePath,
            key: .defaultBaseStoragePath,
            to: &reasons
        )
        appendFieldIssue(
            legacy.source.source.confirmBeforeLaunch,
            key: .confirmBeforeLaunch,
            to: &reasons
        )
        appendFieldIssue(
            legacy.source.source.automaticallyRecoverCrashedApps,
            key: .automaticallyRecoverCrashedApps,
            to: &reasons
        )
        appendFieldIssue(
            legacy.source.source.appearance,
            key: .appearance,
            to: &reasons
        )
        appendFieldIssue(
            legacy.source.source.profileVisualIdentities,
            key: .profileVisualIdentities,
            to: &reasons
        )

        if case .invalid(let issue) = legacy.source.profileTemplates {
            reasons.append(
                .legacyPayloadInvalid(
                    payload: .profileTemplates,
                    issue: issue
                )
            )
        }
        if case .invalid(let issue) = legacy.source.profileVisualIdentities {
            reasons.append(
                .legacyPayloadInvalid(
                    payload: .profileVisualIdentities,
                    issue: issue
                )
            )
        }
        switch legacy.appearance {
        case .unsupportedEmpty, .unsupportedNonempty:
            guard case .retained(let value) =
                legacy.source.source.appearance
            else {
                reasons.append(.legacyAssessmentInconsistent)
                return
            }
            reasons.append(.unsupportedAppearance(value))
        case .unavailable, .absent, .wrongType, .oversized, .supported:
            break
        }
    }

    private func validateTemplates(
        into reasons: inout [SettingsMigrationRecoveryReason]
    ) {
        let records: [SettingsLegacyTemplateWireRecord]
        switch legacy.source.profileTemplates {
        case .decoded(let value):
            records = value
        case .absent, .unavailable, .wrongType, .oversized, .invalid:
            records = []
        }
        guard records.count == legacy.structuredTemplateFacts.count else {
            reasons.append(.legacyAssessmentInconsistent)
            return
        }

        for (record, facts) in zip(
            records,
            legacy.structuredTemplateFacts
        ) {
            guard facts.sourceIndex >= 0,
                  facts.sourceIndex < records.count,
                  facts.id == record.id
            else {
                reasons.append(.legacyAssessmentInconsistent)
                continue
            }
            if let first = facts.firstPriorEqualUUIDIndex {
                reasons.append(
                    .duplicateTemplateID(
                        sourceIndex: facts.sourceIndex,
                        firstIndex: first,
                        id: facts.id
                    )
                )
            }
            if facts.materializedIgnoredMemberCount > 0 {
                reasons.append(
                    .templateUnknownMembers(
                        sourceIndex: facts.sourceIndex,
                        count: facts.materializedIgnoredMemberCount
                    )
                )
            }
        }

        guard case .decoded = legacy.source.profileTemplates,
              case .retained(let names) =
                legacy.source.source.legacyProfileTemplateNames
        else {
            return
        }
        let structuredNames = records.map(\.name)
        if !scalarExactEqual(structuredNames, names) {
            reasons.append(.conflictingTemplateForms)
        }
    }

    private func validateVisuals(
        into reasons: inout [SettingsMigrationRecoveryReason]
    ) {
        let records: [SettingsLegacyVisualIdentityWireRecord]
        switch legacy.source.profileVisualIdentities {
        case .decoded(let value):
            records = value
        case .absent, .unavailable, .wrongType, .oversized, .invalid:
            records = []
        }
        guard records.count == legacy.visualFacts.count else {
            reasons.append(.legacyAssessmentInconsistent)
            return
        }

        for (record, facts) in zip(records, legacy.visualFacts) {
            guard facts.entryIndex >= 0,
                  facts.entryIndex < records.count
            else {
                reasons.append(.legacyAssessmentInconsistent)
                continue
            }
            if facts.materializedIgnoredMemberCount > 0 {
                reasons.append(
                    .visualUnknownMembers(
                        entryIndex: facts.entryIndex,
                        count: facts.materializedIgnoredMemberCount
                    )
                )
            }
            switch facts.rawKeyClass {
            case .canonicalLowercaseUUID(let id):
                if let first = facts.firstPriorEqualUUIDIndex {
                    reasons.append(
                        .duplicateVisualID(
                            entryIndex: facts.entryIndex,
                            firstIndex: first,
                            id: id
                        )
                    )
                }
            case .noncanonicalUUID(let id):
                reasons.append(
                    .noncanonicalVisualKey(
                        entryIndex: facts.entryIndex,
                        key: record.key,
                        id: id
                    )
                )
                if let first = facts.firstPriorEqualUUIDIndex {
                    reasons.append(
                        .duplicateVisualID(
                            entryIndex: facts.entryIndex,
                            firstIndex: first,
                            id: id
                        )
                    )
                }
            case .nonUUID:
                reasons.append(
                    .nonUUIDVisualKey(
                        entryIndex: facts.entryIndex,
                        key: record.key
                    )
                )
            }
            if ProfileInstanceVisualSymbol(
                rawValue: record.symbol.rawValue
            ) == nil || ProfileInstanceVisualColor(
                rawValue: record.color.rawValue
            ) == nil {
                reasons.append(
                    .unsupportedVisualValue(
                        entryIndex: facts.entryIndex,
                        symbol: record.symbol.rawValue,
                        color: record.color.rawValue
                    )
                )
            }
        }
    }

    private func recovery(
        _ reasons: [SettingsMigrationRecoveryReason],
        evidence: SettingsMigrationEvidence
    ) -> SettingsMigrationPlan {
        .recoveryRequired(
            .init(reasons: reasons, evidence: evidence)
        )
    }
}

private func appendFieldIssue<Value>(
    _ field: SettingsLegacyField<Value>,
    key: SettingsLegacyKey,
    to reasons: inout [SettingsMigrationRecoveryReason]
) where Value: Equatable & Sendable {
    switch field {
    case .unavailable(let failure):
        reasons.append(
            .legacyFieldUnavailable(key: key, failure: failure)
        )
    case .wrongType(let actual):
        reasons.append(.legacyFieldWrongType(key: key, actual: actual))
    case .oversized(let violations):
        reasons.append(
            .legacyFieldOversized(key: key, violations: violations)
        )
    case .absent, .retained:
        break
    }
}

private func scalarExactEqual(_ lhs: [String], _ rhs: [String]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { left, right in
        left.unicodeScalars.map(\.value) == right.unicodeScalars.map(\.value)
    }
}
