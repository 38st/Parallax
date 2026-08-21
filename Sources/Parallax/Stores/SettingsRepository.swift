import CryptoKit
import Foundation

struct SettingsSourceSHA256: Hashable, Sendable {
    let hex: String

    init(_ data: Data) {
        hex = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

struct SettingsContent: Equatable, Sendable {
    let profileTemplates: [SettingsDocument.Template]
    let defaultBaseStoragePath: String
    let confirmBeforeLaunch: Bool
    let automaticallyRecoverCrashedApps: Bool
    let appearance: String
    let profileVisualIdentities: [SettingsDocument.VisualIdentity]

    init(
        profileTemplates: [SettingsDocument.Template],
        defaultBaseStoragePath: String,
        confirmBeforeLaunch: Bool,
        automaticallyRecoverCrashedApps: Bool,
        appearance: String,
        profileVisualIdentities: [SettingsDocument.VisualIdentity]
    ) {
        self.profileTemplates = profileTemplates
        self.defaultBaseStoragePath = defaultBaseStoragePath
        self.confirmBeforeLaunch = confirmBeforeLaunch
        self.automaticallyRecoverCrashedApps =
            automaticallyRecoverCrashedApps
        self.appearance = appearance
        self.profileVisualIdentities = profileVisualIdentities
    }

    init(document: SettingsDocument) {
        self.init(
            profileTemplates: document.profileTemplates,
            defaultBaseStoragePath: document.defaultBaseStoragePath,
            confirmBeforeLaunch: document.confirmBeforeLaunch,
            automaticallyRecoverCrashedApps:
                document.automaticallyRecoverCrashedApps,
            appearance: document.appearance,
            profileVisualIdentities: document.profileVisualIdentities
        )
    }

    func document(revision: SettingsRevision) -> SettingsDocument {
        SettingsDocument(
            revision: revision,
            profileTemplates: profileTemplates,
            defaultBaseStoragePath: defaultBaseStoragePath,
            confirmBeforeLaunch: confirmBeforeLaunch,
            automaticallyRecoverCrashedApps:
                automaticallyRecoverCrashedApps,
            appearance: appearance,
            profileVisualIdentities: profileVisualIdentities
        )
    }
}

enum SettingsCommitExpectation: Equatable, Sendable {
    case missing
    case version(SettingsVersionToken)
}

enum SettingsPrimaryMutationClassification: Equatable, Sendable {
    case prior
    case target
    case neither
    case indeterminate
}

enum SettingsRepositoryMutationLockFailure: Equatable, Sendable {
    case acquisition(SettingsPrimaryMutationLockError)
    case cleanup(SettingsPrimaryMutationLockCleanupError)
    case acquisitionAndCleanup(
        primary: SettingsPrimaryMutationLockError,
        cleanup: SettingsPrimaryMutationLockCleanupError
    )
    case unknownPrimaryAndCleanup(
        primaryDescription: String,
        cleanup: SettingsPrimaryMutationLockCleanupError
    )
    case unexpected(String)
}

struct SettingsRepositoryCommittedPublicationEvidence:
    Equatable,
    Sendable
{
    let classification: SettingsPrimaryMutationClassification
    let targetProofEligible: Bool
    let residual: SettingsPrimaryPublicationResidual?
    let priorToken: SettingsVersionToken?
    let targetToken: SettingsVersionToken
}

indirect enum SettingsRepositoryMutationFailure:
    Error,
    Equatable,
    Sendable
{
    case revisionOverflow
    case expectationMismatch
    case futureSchema(UInt64)
    case corrupt(SettingsDocumentCodecFailure)
    case unavailable(SettingsRepositoryUnavailable)
    case invalidTarget(SettingsDocumentCodecIssue)
    case lock(SettingsRepositoryMutationLockFailure)
    case terminalAndLock(
        terminal: SettingsRepositoryMutationFailure,
        lock: SettingsRepositoryMutationLockFailure
    )
    case publication(SettingsPrimaryPublicationEvidence)
    case publicationAndLock(
        publication: SettingsPrimaryPublicationEvidence,
        lock: SettingsRepositoryMutationLockFailure
    )
    case committedPublicationAndLock(
        publication: SettingsRepositoryCommittedPublicationEvidence,
        lock: SettingsRepositoryMutationLockFailure
    )
}

struct SettingsRepositoryMutationEvidence: Equatable, Sendable {
    let classification: SettingsPrimaryMutationClassification
    let failure: SettingsRepositoryMutationFailure
    let priorToken: SettingsVersionToken?
    let targetToken: SettingsVersionToken?
    let residual: SettingsPrimaryPublicationResidual?
}

enum SettingsRepositoryCommitResult: Equatable, Sendable {
    case committed(
        SettingsRepositorySnapshot,
        residual: SettingsPrimaryPublicationResidual?
    )
    case rejected(SettingsRepositoryMutationEvidence)
    case recoveryRequired(SettingsRepositoryMutationEvidence)
}

struct SettingsVersionToken: Hashable, Sendable {
    let revision: SettingsRevision
    let sourceSHA256: SettingsSourceSHA256
}

struct SettingsRepositorySnapshot: Equatable, Sendable {
    let document: SettingsDocument
    let versionToken: SettingsVersionToken
    let originalBytes: Data
}

struct SettingsRepositoryEvidence: Equatable, Sendable {
    let originalBytes: Data
    let sourceSHA256: SettingsSourceSHA256
}

enum SettingsRepositoryUnavailable: Equatable, Sendable {
    case primaryFile(SettingsPrimaryFileAccessError)
}

enum SettingsRepositoryInspection: Equatable, Sendable {
    case missing
    case current(SettingsRepositorySnapshot)
    case future(schemaVersion: UInt64, evidence: SettingsRepositoryEvidence)
    case recoveryRequired(
        failure: SettingsDocumentCodecFailure,
        sourceSHA256: SettingsSourceSHA256
    )
    case unavailable(SettingsRepositoryUnavailable)
}

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
struct SettingsRepositoryWriter: @unchecked Sendable {
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
