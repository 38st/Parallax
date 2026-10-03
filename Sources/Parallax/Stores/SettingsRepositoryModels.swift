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
    case committedWithCleanupFailure(SettingsRepositorySnapshot, SettingsRepositoryMutationEvidence)
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
    case mutationLock(SettingsRepositoryMutationLockFailure)
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

extension SettingsRepositoryMutationLockFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .acquisition(error):
            error.localizedDescription
        case let .cleanup(error):
            error.localizedSummary
        case let .acquisitionAndCleanup(primary, cleanup):
            primary.localizedDescription + " " + cleanup.localizedSummary
        case let .unknownPrimaryAndCleanup(primaryDescription, cleanup):
            primaryDescription + " " + cleanup.localizedSummary
        case let .unexpected(description):
            Self.unexpectedFailureDescription(description)
        }
    }

    /// The unexpected-failure message, whose detail is an explicitly typed
    /// constant so the localization census can infer its placeholder.
    private static func unexpectedFailureDescription(
        _ detail: String
    ) -> String {
        String(
            localized:
                "Parallax could not lock settings: \(detail)"
        )
    }
}
