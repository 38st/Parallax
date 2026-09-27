import CryptoKit
import Foundation

protocol SettingsRepositoryInspecting: Sendable {
    func inspect() -> SettingsRepositoryInspection
}

struct SettingsRepository: SettingsRepositoryInspecting, Sendable {
    static let maximumPrimaryBytes = 4 * 1_024 * 1_024

    private let primaryFileAccess: any SettingsPrimaryFileAccessing
    private let codec: SettingsDocumentCodec

    init(
        primaryFileAccess: any SettingsPrimaryFileAccessing,
        codec: SettingsDocumentCodec = SettingsDocumentCodec()
    ) {
        self.primaryFileAccess = primaryFileAccess
        self.codec = codec
    }

    func inspect() -> SettingsRepositoryInspection {
        switch primaryFileAccess.read(
            maximumBytes: Self.maximumPrimaryBytes
        ) {
        case .failure(let error):
            return .unavailable(.primaryFile(error))
        case .success(.missing):
            return .missing
        case .success(.bytes(let bytes)):
            let sourceSHA256 = SettingsSourceSHA256(bytes)
            switch codec.decode(bytes) {
            case .current(let document):
                return .current(
                    SettingsRepositorySnapshot(
                        document: document,
                        versionToken: SettingsVersionToken(
                            revision: document.revision,
                            sourceSHA256: sourceSHA256
                        ),
                        originalBytes: bytes
                    )
                )
            case .future(let schemaVersion, let originalBytes):
                return .future(
                    schemaVersion: schemaVersion,
                    evidence: SettingsRepositoryEvidence(
                        originalBytes: originalBytes,
                        sourceSHA256: sourceSHA256
                    )
                )
            case .invalid(let failure):
                return .recoveryRequired(
                    failure: failure,
                    sourceSHA256: sourceSHA256
                )
            }
        }
    }
}
struct SettingsRepositoryWriter: Sendable {
    private let mutationLock: SettingsPrimaryMutationLock
    private let preparer: SettingsCommitPreparer
    private let inspector: SettingsLockedPrimaryInspector

    init(
        mutationLock: SettingsPrimaryMutationLock,
        codec: SettingsDocumentCodec = SettingsDocumentCodec()
    ) {
        self.mutationLock = mutationLock
        preparer = SettingsCommitPreparer(codec: codec)
        inspector = SettingsLockedPrimaryInspector(codec: codec)
    }

    func inspect() -> SettingsRepositoryInspection {
        do {
            return try mutationLock.withMutationLock { authority in
                inspector.inspect(authority.readPrimary())
            }
        } catch {
            return .unavailable(.mutationLock(settingsMutationLockFailure(error)))
        }
    }

    func commit(
        _ content: SettingsContent,
        expecting expectation: SettingsCommitExpectation
    ) -> SettingsRepositoryCommitResult {
        var lastEvidence: SettingsRepositoryMutationEvidence?
        var terminalEvidence: SettingsRepositoryMutationEvidence?
        var committedPublication:
            SettingsRepositoryCommittedPublicationEvidence?
        var initialForRecovery: SettingsPrimaryInitialObservation?
        var preparedForRecovery: SettingsPrimaryPreparedPublication?
        do {
            return try mutationLock.withMutationLock { authority in
                let rawInitial = authority.readPrimary()
                initialForRecovery = SettingsPrimaryObservationClassifier
                    .initialObservation(rawInitial)
                let initial = inspector.inspect(rawInitial)
                let prepared: SettingsPrimaryPreparedPublication
                switch preparer.prepare(
                    content,
                    expectation: expectation,
                    inspection: initial
                ) {
                case .terminal(let result):
                    terminalEvidence = result.mutationEvidence
                    return result
                case .prepared(let value):
                    prepared = value
                }
                preparedForRecovery = prepared

                let publication = authority.publishPrepared(prepared)
                switch publication {
                case .committed(let residual):
                    committedPublication =
                        SettingsRepositoryCommittedPublicationEvidence(
                            classification: .target,
                            targetProofEligible: true,
                            residual: residual,
                            priorToken: prepared.prior.token,
                            targetToken: prepared.targetToken
                        )
                    return .committed(
                        SettingsRepositorySnapshot(
                            document: prepared.targetDocument,
                            versionToken: prepared.targetToken,
                            originalBytes: prepared.targetBytes
                        ),
                        residual: residual
                    )
                case .failed(let evidence):
                    let mapped = SettingsRepositoryMutationEvidence(
                        classification: evidence.classification,
                        failure: .publication(evidence),
                        priorToken: prepared.prior.token,
                        targetToken: prepared.targetToken,
                        residual: evidence.residual
                    )
                    lastEvidence = mapped
                    return .recoveryRequired(mapped)
                }
            }
        } catch {
            let lockFailure = settingsMutationLockFailure(error)
            if let committedPublication {
                return .recoveryRequired(
                    SettingsRepositoryMutationEvidence(
                        classification: .target,
                        failure: .committedPublicationAndLock(
                            publication: committedPublication,
                            lock: lockFailure
                        ),
                        priorToken: committedPublication.priorToken,
                        targetToken: committedPublication.targetToken,
                        residual: committedPublication.residual
                    )
                )
            }
            let classification: SettingsPrimaryMutationClassification
            if let lastEvidence {
                classification = cleanupClassification(
                    lastEvidence,
                    prepared: preparedForRecovery
                )
            } else if let terminalEvidence {
                classification = cleanupClassification(
                    terminalEvidence,
                    initial: initialForRecovery
                )
            } else {
                classification = .indeterminate
            }
            if let lastEvidence {
                let failure: SettingsRepositoryMutationFailure
                if case .publication(let publication) =
                    lastEvidence.failure
                {
                    failure = .publicationAndLock(
                        publication: publication,
                        lock: lockFailure
                    )
                } else {
                    failure = lastEvidence.failure
                }
                return .recoveryRequired(
                    SettingsRepositoryMutationEvidence(
                        classification: classification,
                        failure: failure,
                        priorToken: lastEvidence.priorToken,
                        targetToken: lastEvidence.targetToken,
                        residual: lastEvidence.residual
                    )
                )
            }
            if let terminalEvidence {
                return .recoveryRequired(
                    SettingsRepositoryMutationEvidence(
                        classification: classification,
                        failure: .terminalAndLock(
                            terminal: terminalEvidence.failure,
                            lock: lockFailure
                        ),
                        priorToken: terminalEvidence.priorToken,
                        targetToken: terminalEvidence.targetToken,
                        residual: terminalEvidence.residual
                    )
                )
            }
            return .recoveryRequired(
                SettingsRepositoryMutationEvidence(
                    classification: classification,
                    failure: .lock(lockFailure),
                    priorToken: expectation.token,
                    targetToken: preparedForRecovery?.targetToken,
                    residual: nil
                )
            )
        }
    }

    private func cleanupClassification(
        _ evidence: SettingsRepositoryMutationEvidence,
        prepared: SettingsPrimaryPreparedPublication?
    ) -> SettingsPrimaryMutationClassification {
        guard let prepared else { return evidence.classification }
        let targetProofEligible: Bool? = if case .publication(
            let publication
        ) = evidence.failure {
            publication.targetProofEligible
        } else {
            nil
        }
        return SettingsPrimaryObservationClassifier.cleanupClassification(
            evidence.classification,
            targetProofEligible: targetProofEligible
        ) {
            SettingsPrimaryLockReclassifier(
                mutationLock: mutationLock
            ).classify(prepared)
        }
    }

    private func cleanupClassification(
        _ evidence: SettingsRepositoryMutationEvidence,
        initial: SettingsPrimaryInitialObservation?
    ) -> SettingsPrimaryMutationClassification {
        guard evidence.classification == .indeterminate,
              let initial
        else {
            return evidence.classification
        }
        return classifyInitialByReacquiringLock(initial)
    }

    private func classifyInitialByReacquiringLock(
        _ initial: SettingsPrimaryInitialObservation
    ) -> SettingsPrimaryMutationClassification {
        var observed: SettingsPrimaryMutationClassification?
        do {
            let classification = try mutationLock.withMutationLock {
                authority in
                let value = SettingsPrimaryObservationClassifier.classify(
                    authority.readPrimary(),
                    initial: initial
                )
                observed = value
                return value
            }
            return classification
        } catch {
            return observed ?? .indeterminate
        }
    }

}

func settingsMutationLockFailure(
    _ error: any Error
) -> SettingsRepositoryMutationLockFailure {
    if let acquisition = error as? SettingsPrimaryMutationLockError {
        return .acquisition(acquisition)
    }
    if let cleanup = error as? SettingsPrimaryMutationLockCleanupError {
        return .cleanup(cleanup)
    }
    if let combined =
        error as? SettingsPrimaryMutationLockPrimaryAndCleanupError
    {
        if let primary = combined.primary as? SettingsPrimaryMutationLockError {
            return .acquisitionAndCleanup(
                primary: primary,
                cleanup: combined.cleanup
            )
        }
        return .unknownPrimaryAndCleanup(
            primaryDescription: String(describing: combined.primary),
            cleanup: combined.cleanup
        )
    }
    return .unexpected(String(describing: error))
}

private extension SettingsCommitExpectation {
    var token: SettingsVersionToken? {
        guard case .version(let token) = self else {
            return nil
        }
        return token
    }
}

private extension SettingsRepositoryCommitResult {
    var mutationEvidence: SettingsRepositoryMutationEvidence? {
        switch self {
        case .committed:
            return nil
        case .rejected(let evidence),
             .recoveryRequired(let evidence):
            return evidence
        }
    }
}

private extension SettingsPrimaryPreparedPrior {
    var token: SettingsVersionToken? {
        guard case .current(_, let token) = self else {
            return nil
        }
        return token
    }
}
