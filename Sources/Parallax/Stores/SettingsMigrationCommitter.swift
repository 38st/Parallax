import Foundation

indirect enum SettingsMigrationCommitFailure: Error, Equatable, Sendable {
    case planRecoveryRequired([SettingsMigrationRecoveryReason])
    case inconsistentPlan
    case currentPrimaryChanged(SettingsRepositoryInspection)
    case residualInventoryUnavailable(SettingsPrimaryLockedInspectionError)
    case preexistingResiduals(SettingsPublicationResidualInventorySnapshot)
    case legacyRecaptureChanged(SettingsLegacyMigrationAssessment)
    case preparation(SettingsRepositoryMutationEvidence)
    case publication(SettingsPrimaryPublicationEvidence)
    case lock(SettingsRepositoryMutationLockFailure)
    case terminalAndLock(
        terminal: SettingsMigrationCommitFailure,
        lock: SettingsRepositoryMutationLockFailure
    )
    case publicationAndLock(
        publication: SettingsPrimaryPublicationEvidence,
        lock: SettingsRepositoryMutationLockFailure
    )
    case committedPublicationAndLock(
        receipt: SettingsMigrationPublicationReceipt,
        lock: SettingsRepositoryMutationLockFailure
    )
}

struct SettingsMigrationCommitEvidence: Equatable, Sendable {
    let classification: SettingsPrimaryMutationClassification
    let failure: SettingsMigrationCommitFailure
    let planned: SettingsMigrationEvidence
    let lockedPrimary: SettingsRepositoryInspection?
    let lockedReadFailure: SettingsPrimaryLockedInspectionError?
    let residualInventory: SettingsPublicationResidualInventorySnapshot?
    let recapturedLegacy: SettingsLegacyMigrationAssessment?
    let targetToken: SettingsVersionToken?
    let publicationResidual: SettingsPrimaryPublicationResidual?
}

enum SettingsMigrationCommitResult: Equatable, Sendable {
    case notRequired(SettingsMigrationReadyPlan)
    case committed(SettingsMigrationPublicationReceipt)
    case recoveryRequired(SettingsMigrationCommitEvidence)
}

struct SettingsMigrationPublicationReceipt: Equatable, Sendable {
    let snapshot: SettingsRepositorySnapshot
    let migrationEvidence: SettingsMigrationEvidence
    let lockedPrimary: SettingsRepositoryInspection
    let recapturedLegacy: SettingsLegacyMigrationAssessment
    let preflightInventory: SettingsPublicationResidualInventorySnapshot
    let publication: SettingsRepositoryCommittedPublicationEvidence
    let residual: SettingsPrimaryPublicationResidual?
}

/// Commits a precomputed migration only after all source evidence has been
/// recaptured under one settings mutation-lock lease. Legacy preferences are
/// read-only here and remain available for rollback after publication.
struct SettingsMigrationCommitter: @unchecked Sendable {
    typealias LegacyCapture = @Sendable () -> SettingsLegacySnapshot

    private let mutationLock: SettingsPrimaryMutationLock
    private let legacyCapture: LegacyCapture
    private let preparer: SettingsCommitPreparer
    private let inspector: SettingsLockedPrimaryInspector

    init(
        mutationLock: SettingsPrimaryMutationLock,
        legacyReader: SettingsLegacySnapshotReader,
        codec: SettingsDocumentCodec = SettingsDocumentCodec()
    ) {
        self.init(
            mutationLock: mutationLock,
            legacyCapture: { legacyReader.capture() },
            codec: codec
        )
    }

    init(
        mutationLock: SettingsPrimaryMutationLock,
        legacyCapture: @escaping LegacyCapture,
        codec: SettingsDocumentCodec = SettingsDocumentCodec()
    ) {
        self.mutationLock = mutationLock
        self.legacyCapture = legacyCapture
        preparer = SettingsCommitPreparer(codec: codec)
        inspector = SettingsLockedPrimaryInspector(codec: codec)
    }

    func commit(_ plan: SettingsMigrationPlan)
        -> SettingsMigrationCommitResult
    {
        switch plan {
        case .recoveryRequired(let recovery):
            return .recoveryRequired(
                .init(
                    classification: .indeterminate,
                    failure: .planRecoveryRequired(recovery.reasons),
                    planned: recovery.evidence,
                    lockedPrimary: nil,
                    lockedReadFailure: nil,
                    residualInventory: nil,
                    recapturedLegacy: nil,
                    targetToken: nil,
                    publicationResidual: nil
                )
            )
        case .useCurrent(let ready):
            return .notRequired(ready)
        case .publishLegacy(let ready):
            return publish(ready, expectedPlan: plan)
        case .publishDefaults(let ready):
            return publish(ready, expectedPlan: plan)
        }
    }

    private func publish(
        _ ready: SettingsMigrationReadyPlan,
        expectedPlan: SettingsMigrationPlan
    ) -> SettingsMigrationCommitResult {
        guard ready.evidence.current.source == .missing,
              ready.evidence.current.presence == .absent
        else {
            return .recoveryRequired(
                failure(
                    .inconsistentPlan,
                    classification: .indeterminate,
                    ready: ready
                )
            )
        }

        var terminal: SettingsMigrationCommitEvidence?
        var preparedForRecovery: SettingsPrimaryPreparedPublication?
        var publicationForRecovery: SettingsPrimaryPublicationEvidence?
        var committedForRecovery: SettingsMigrationPublicationReceipt?
        do {
            return try mutationLock.withMutationLock { authority in
                let lockedRead = authority.readPrimary()
                let lockedReadFailure: SettingsPrimaryLockedInspectionError?
                switch lockedRead {
                case .success:
                    lockedReadFailure = nil
                case .failure(let error):
                    lockedReadFailure = error
                }
                let observed = inspector.inspect(lockedRead)
                guard observed == ready.evidence.current.source else {
                    let evidence = failure(
                        .currentPrimaryChanged(observed),
                        classification: classification(
                            expected: ready.evidence.current.source,
                            observed: observed
                        ),
                        ready: ready,
                        lockedPrimary: observed,
                        lockedReadFailure: lockedReadFailure
                    )
                    terminal = evidence
                    return .recoveryRequired(evidence)
                }

                let inventory: SettingsPublicationResidualInventorySnapshot
                switch authority.inspectPublicationResiduals() {
                case .failure(let error):
                    let evidence = failure(
                        .residualInventoryUnavailable(error),
                        classification: .prior,
                        ready: ready,
                        lockedPrimary: observed
                    )
                    terminal = evidence
                    return .recoveryRequired(evidence)
                case .success(let value):
                    inventory = value
                }
                guard inventoryIsClear(inventory) else {
                    let evidence = failure(
                        .preexistingResiduals(inventory),
                        classification: .prior,
                        ready: ready,
                        lockedPrimary: observed,
                        inventory: inventory
                    )
                    terminal = evidence
                    return .recoveryRequired(evidence)
                }

                let recaptured = SettingsLegacyMigrationAssessor(
                    source: SettingsLegacySnapshotDecoder(
                        source: legacyCapture()
                    ).decode()
                ).assess()
                guard recaptured == ready.evidence.legacy else {
                    let evidence = failure(
                        .legacyRecaptureChanged(recaptured),
                        classification: .prior,
                        ready: ready,
                        lockedPrimary: observed,
                        inventory: inventory,
                        recapturedLegacy: recaptured
                    )
                    terminal = evidence
                    return .recoveryRequired(evidence)
                }
                let replanned = SettingsMigrationPlanner(
                    current: SettingsCurrentMigrationAssessor(
                        source: observed
                    ).assess(),
                    legacy: recaptured
                ).plan()
                guard replanned == expectedPlan else {
                    let evidence = failure(
                        .inconsistentPlan,
                        classification: .prior,
                        ready: ready,
                        lockedPrimary: observed,
                        inventory: inventory,
                        recapturedLegacy: recaptured
                    )
                    terminal = evidence
                    return .recoveryRequired(evidence)
                }

                let content = SettingsContent(
                    document: ready.state.document(revision: .zero)
                )
                let prepared: SettingsPrimaryPreparedPublication
                switch preparer.prepare(
                    content,
                    expectation: .missing,
                    inspection: observed
                ) {
                case .terminal(let result):
                    let repositoryEvidence = result.migrationMutationEvidence
                    guard let repositoryEvidence else {
                        let evidence = failure(
                            .inconsistentPlan,
                            classification: .prior,
                            ready: ready,
                            lockedPrimary: observed,
                            inventory: inventory,
                            recapturedLegacy: recaptured
                        )
                        terminal = evidence
                        return .recoveryRequired(evidence)
                    }
                    let evidence = failure(
                        .preparation(repositoryEvidence),
                        classification: repositoryEvidence.classification,
                        ready: ready,
                        lockedPrimary: observed,
                        inventory: inventory,
                        recapturedLegacy: recaptured,
                        targetToken: repositoryEvidence.targetToken,
                        residual: repositoryEvidence.residual
                    )
                    terminal = evidence
                    return .recoveryRequired(evidence)
                case .prepared(let value):
                    prepared = value
                    preparedForRecovery = value
                }

                switch authority.publishPrepared(prepared) {
                case .committed(let residual):
                    let publication =
                        SettingsRepositoryCommittedPublicationEvidence(
                            classification: .target,
                            targetProofEligible: true,
                            residual: residual,
                            priorToken: prepared.prior.migrationToken,
                            targetToken: prepared.targetToken
                        )
                    let receipt = SettingsMigrationPublicationReceipt(
                        snapshot: SettingsRepositorySnapshot(
                            document: prepared.targetDocument,
                            versionToken: prepared.targetToken,
                            originalBytes: prepared.targetBytes
                        ),
                        migrationEvidence: ready.evidence,
                        lockedPrimary: observed,
                        recapturedLegacy: recaptured,
                        preflightInventory: inventory,
                        publication: publication,
                        residual: residual
                    )
                    committedForRecovery = receipt
                    return .committed(receipt)
                case .failed(let publication):
                    publicationForRecovery = publication
                    let evidence = failure(
                        .publication(publication),
                        classification: publication.classification,
                        ready: ready,
                        lockedPrimary: observed,
                        inventory: inventory,
                        recapturedLegacy: recaptured,
                        targetToken: prepared.targetToken,
                        residual: publication.residual
                    )
                    terminal = evidence
                    return .recoveryRequired(evidence)
                }
            }
        } catch {
            return lockRecovery(
                error,
                ready: ready,
                terminal: terminal,
                prepared: preparedForRecovery,
                publication: publicationForRecovery,
                committed: committedForRecovery
            )
        }
    }

    private func lockRecovery(
        _ error: any Error,
        ready: SettingsMigrationReadyPlan,
        terminal: SettingsMigrationCommitEvidence?,
        prepared: SettingsPrimaryPreparedPublication?,
        publication: SettingsPrimaryPublicationEvidence?,
        committed: SettingsMigrationPublicationReceipt?
    ) -> SettingsMigrationCommitResult {
        let lock = settingsMutationLockFailure(error)
        if let committed {
            return .recoveryRequired(
                failure(
                    .committedPublicationAndLock(
                        receipt: committed,
                        lock: lock
                    ),
                    classification: .target,
                    ready: ready,
                    lockedPrimary: committed.lockedPrimary,
                    inventory: committed.preflightInventory,
                    recapturedLegacy: committed.recapturedLegacy,
                    targetToken: committed.publication.targetToken,
                    residual: committed.residual
                )
            )
        }
        if let publication {
            let classification = cleanupClassification(
                publication.classification,
                publication: publication,
                prepared: prepared
            )
            return .recoveryRequired(
                failure(
                    .publicationAndLock(
                        publication: publication,
                        lock: lock
                    ),
                    classification: classification,
                    ready: ready,
                    lockedPrimary: terminal?.lockedPrimary,
                    inventory: terminal?.residualInventory,
                    recapturedLegacy: terminal?.recapturedLegacy,
                    targetToken: prepared?.targetToken,
                    residual: publication.residual
                )
            )
        }
        if let terminal {
            return .recoveryRequired(
                SettingsMigrationCommitEvidence(
                    classification: terminal.classification,
                    failure: .terminalAndLock(
                        terminal: terminal.failure,
                        lock: lock
                    ),
                    planned: terminal.planned,
                    lockedPrimary: terminal.lockedPrimary,
                    lockedReadFailure: terminal.lockedReadFailure,
                    residualInventory: terminal.residualInventory,
                    recapturedLegacy: terminal.recapturedLegacy,
                    targetToken: terminal.targetToken,
                    publicationResidual: terminal.publicationResidual
                )
            )
        }
        return .recoveryRequired(
            failure(
                .lock(lock),
                classification: .indeterminate,
                ready: ready
            )
        )
    }

    private func cleanupClassification(
        _ classification: SettingsPrimaryMutationClassification,
        publication: SettingsPrimaryPublicationEvidence,
        prepared: SettingsPrimaryPreparedPublication?
    ) -> SettingsPrimaryMutationClassification {
        guard let prepared else { return classification }
        return SettingsPrimaryObservationClassifier.cleanupClassification(
            classification,
            targetProofEligible: publication.targetProofEligible
        ) {
            SettingsPrimaryLockReclassifier(
                mutationLock: mutationLock
            ).classify(prepared)
        }
    }

    private func classification(
        expected: SettingsRepositoryInspection,
        observed: SettingsRepositoryInspection
    ) -> SettingsPrimaryMutationClassification {
        if expected == observed { return .prior }
        if case .unavailable = observed { return .indeterminate }
        return .neither
    }

    private func inventoryIsClear(
        _ inventory: SettingsPublicationResidualInventorySnapshot
    ) -> Bool {
        guard inventory.entries.isEmpty,
              inventory.closeFailures.isEmpty,
              case .complete = inventory.completion
        else { return false }
        return true
    }

    private func failure(
        _ failure: SettingsMigrationCommitFailure,
        classification: SettingsPrimaryMutationClassification,
        ready: SettingsMigrationReadyPlan,
        lockedPrimary: SettingsRepositoryInspection? = nil,
        lockedReadFailure: SettingsPrimaryLockedInspectionError? = nil,
        inventory: SettingsPublicationResidualInventorySnapshot? = nil,
        recapturedLegacy: SettingsLegacyMigrationAssessment? = nil,
        targetToken: SettingsVersionToken? = nil,
        residual: SettingsPrimaryPublicationResidual? = nil
    ) -> SettingsMigrationCommitEvidence {
        .init(
            classification: classification,
            failure: failure,
            planned: ready.evidence,
            lockedPrimary: lockedPrimary,
            lockedReadFailure: lockedReadFailure,
            residualInventory: inventory,
            recapturedLegacy: recapturedLegacy,
            targetToken: targetToken,
            publicationResidual: residual
        )
    }
}

private extension SettingsRepositoryCommitResult {
    var migrationMutationEvidence: SettingsRepositoryMutationEvidence? {
        switch self {
        case .committed:
            nil
        case .rejected(let evidence), .recoveryRequired(let evidence):
            evidence
        }
    }
}

private extension SettingsPrimaryPreparedPrior {
    var migrationToken: SettingsVersionToken? {
        guard case .current(_, let token) = self else { return nil }
        return token
    }
}
