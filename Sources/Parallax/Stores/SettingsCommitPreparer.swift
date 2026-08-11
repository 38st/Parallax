import Foundation

enum SettingsCommitPreparation: Equatable, Sendable {
    case prepared(SettingsPrimaryPreparedPublication)
    case terminal(SettingsRepositoryCommitResult)
}

/// Purely derives the exact canonical publication request for an observed
/// primary. Locking, reads, publication, and cleanup remain caller-owned.
struct SettingsCommitPreparer: Sendable {
    private let codec: SettingsDocumentCodec

    init(codec: SettingsDocumentCodec = SettingsDocumentCodec()) {
        self.codec = codec
    }

    func prepare(
        _ content: SettingsContent,
        expectation: SettingsCommitExpectation,
        inspection: SettingsRepositoryInspection
    ) -> SettingsCommitPreparation {
        let prior: SettingsPrimaryPreparedPrior
        let nextRevision: SettingsRevision
        switch inspection {
        case .missing:
            guard expectation == .missing else {
                return .terminal(
                    rejected(.expectationMismatch, priorToken: nil)
                )
            }
            prior = .missing
            nextRevision = SettingsRevision(rawValue: 1)
        case .current(let snapshot):
            guard case .version(let expected) = expectation,
                  expected == snapshot.versionToken
            else {
                return .terminal(
                    rejected(
                        .expectationMismatch,
                        priorToken: snapshot.versionToken
                    )
                )
            }
            guard snapshot.document.revision.rawValue < UInt64.max else {
                return .terminal(
                    rejected(
                        .revisionOverflow,
                        priorToken: snapshot.versionToken
                    )
                )
            }
            prior = .current(
                bytes: snapshot.originalBytes,
                token: snapshot.versionToken
            )
            nextRevision = SettingsRevision(
                rawValue: snapshot.document.revision.rawValue + 1
            )
        case .future(let schemaVersion, _):
            return .terminal(
                .rejected(
                    SettingsRepositoryMutationEvidence(
                        classification: .prior,
                        failure: .futureSchema(schemaVersion),
                        priorToken: nil,
                        targetToken: nil,
                        residual: nil
                    )
                )
            )
        case .recoveryRequired(let failure, _):
            return .terminal(
                recovery(
                    .corrupt(failure),
                    classification: .prior
                )
            )
        case .unavailable(let unavailable):
            return .terminal(recovery(.unavailable(unavailable)))
        }

        let document = content.document(revision: nextRevision)
        let bytes: Data
        do {
            bytes = try codec.encode(document)
        } catch let issue as SettingsDocumentCodecIssue {
            return .terminal(
                rejected(
                    .invalidTarget(issue),
                    priorToken: token(for: prior)
                )
            )
        } catch {
            return .terminal(
                rejected(
                    .invalidTarget(.malformedJSON),
                    priorToken: token(for: prior)
                )
            )
        }
        let token = SettingsVersionToken(
            revision: nextRevision,
            sourceSHA256: SettingsSourceSHA256(bytes)
        )
        return .prepared(
            SettingsPrimaryPreparedPublication(
                prior: prior,
                targetDocument: document,
                targetBytes: bytes,
                targetToken: token
            )
        )
    }

    private func rejected(
        _ failure: SettingsRepositoryMutationFailure,
        priorToken: SettingsVersionToken?
    ) -> SettingsRepositoryCommitResult {
        .rejected(
            SettingsRepositoryMutationEvidence(
                classification: .prior,
                failure: failure,
                priorToken: priorToken,
                targetToken: nil,
                residual: nil
            )
        )
    }

    private func recovery(
        _ failure: SettingsRepositoryMutationFailure,
        classification: SettingsPrimaryMutationClassification =
            .indeterminate
    ) -> SettingsRepositoryCommitResult {
        .recoveryRequired(
            SettingsRepositoryMutationEvidence(
                classification: classification,
                failure: failure,
                priorToken: nil,
                targetToken: nil,
                residual: nil
            )
        )
    }

    private func token(
        for prior: SettingsPrimaryPreparedPrior
    ) -> SettingsVersionToken? {
        guard case .current(_, let token) = prior else { return nil }
        return token
    }
}

struct SettingsLockedPrimaryInspector: Sendable {
    private let codec: SettingsDocumentCodec

    init(codec: SettingsDocumentCodec = SettingsDocumentCodec()) {
        self.codec = codec
    }

    func inspect(
        _ result: Result<
            SettingsPrimaryFileReadResult,
            SettingsPrimaryLockedInspectionError
        >
    ) -> SettingsRepositoryInspection {
        switch result {
        case .failure(let error):
            return .unavailable(
                .primaryFile(
                    .systemCall(
                        operation: "locked primary inspection",
                        code: error.settingsPOSIXCode
                    )
                )
            )
        case .success(.missing):
            return .missing
        case .success(.bytes(let bytes)):
            let sha = SettingsSourceSHA256(bytes)
            switch codec.decode(bytes) {
            case .current(let document):
                return .current(
                    SettingsRepositorySnapshot(
                        document: document,
                        versionToken: SettingsVersionToken(
                            revision: document.revision,
                            sourceSHA256: sha
                        ),
                        originalBytes: bytes
                    )
                )
            case .future(let schemaVersion, let originalBytes):
                return .future(
                    schemaVersion: schemaVersion,
                    evidence: SettingsRepositoryEvidence(
                        originalBytes: originalBytes,
                        sourceSHA256: sha
                    )
                )
            case .invalid(let failure):
                return .recoveryRequired(
                    failure: failure,
                    sourceSHA256: sha
                )
            }
        }
    }
}

extension SettingsPrimaryLockedInspectionError {
    var settingsPOSIXCode: Int32 {
        switch self {
        case .expiredAuthority, .reentrantAuthorityOperation:
            EBADF
        case .lockValidation(.systemCall(let failure)):
            failure.code
        case .fileAccess(.systemCall(_, let code)):
            code
        case .authorityContainerClose(let failure):
            failure.code
        case .lockValidationAndAuthorityContainerClose(_, let close):
            close.code
        default:
            EIO
        }
    }
}
