import Foundation
import Darwin

struct LibraryVersionToken: Hashable, Sendable {
    static let missing = LibraryVersionToken(
        revision: .initial,
        primarySHA256: nil
    )

    let revision: LibraryRevision
    let primarySHA256: String?
}

struct LibraryRepositorySnapshot: Hashable, Sendable {
    let applications: [ManagedApplication]
    let versionToken: LibraryVersionToken
    let originalBytes: Data

    var revision: LibraryRevision {
        versionToken.revision
    }

    var sourceSHA256: String {
        versionToken.primarySHA256 ?? ""
    }
}

struct PreparedLibraryCommit: Hashable, Sendable {
    let priorVersion: LibraryVersionToken
    let targetVersion: LibraryVersionToken
    let targetBytes: Data
    let applications: [ManagedApplication]
}

enum LibraryCommitPrimaryState: String, Sendable, Equatable {
    case prior
    case target
    case neither
}

struct LibraryPreparedCommitResult: Hashable, Sendable {
    let primaryState: LibraryCommitPrimaryState
    let snapshot: LibraryRepositorySnapshot
}

enum LibraryRepositoryLoadOutcome: Sendable {
    case missing
    case loaded(LibraryRepositorySnapshot)
    case migrationRequired(LegacyLibrarySnapshot)
    case recoveryRequired(LibraryPersistenceFailure)
    case readOnly(LibraryPersistenceFailure)
}

enum LibraryRepositoryError: LocalizedError {
    case staleWriter(expected: LibraryVersionToken, actual: LibraryVersionToken)
    case libraryUnavailable(LibraryPersistenceFailure)
    case migrationRequired(LegacyLibrary.Format)
    case revisionOverflow
    case mutationAlreadyPublished
    case mutationSessionExpired
    case preparedVersionMismatch
    case backupUnavailable
    case invalidExclusiveAccess
    case commitFailed(
        state: LibraryCommitPrimaryState,
        failure: LibraryPersistenceFailure
    )

    var errorDescription: String? {
        switch self {
        case let .staleWriter(expected, actual):
            String(
                localized: "The library changed in another Parallax process (expected revision \(expected.revision.rawValue, specifier: "%llu"), found \(actual.revision.rawValue, specifier: "%llu")). Reload before saving."
            )
        case let .libraryUnavailable(failure):
            String(
                localized: "The library is not writable until its load problem is resolved: \(failure.error.localizedDescription)"
            )
        case .migrationRequired:
            String(localized: "The legacy library must finish migration before it can be edited.")
        case .revisionOverflow:
            String(localized: "The library revision cannot be advanced. Preserve the library and contact support.")
        case .mutationAlreadyPublished:
            String(localized: "A library mutation session can publish metadata only once.")
        case .mutationSessionExpired:
            String(localized: "The library mutation session has ended. Start a new operation and revalidate the library before committing.")
        case .preparedVersionMismatch:
            String(localized: "The prepared library update does not belong to the currently locked library version.")
        case .invalidExclusiveAccess:
            String(localized: "The library lock capability has expired or belongs to another library. Start a new operation.")
        case .backupUnavailable:
            String(localized: "This library update requires a backup, but no backup service is configured.")
        case let .commitFailed(state, failure):
            switch state {
            case .prior:
                String(
                    localized: "The library update was not committed and the prior library remains active: \(failure.error.localizedDescription)"
                )
            case .target:
                String(
                    localized: "The target library is active, but commit verification reported an error: \(failure.error.localizedDescription)"
                )
            case .neither:
                String(
                    localized: "The library no longer matches either the prior or prepared version. Stop editing and recover the library: \(failure.error.localizedDescription)"
                )
            }
        }
    }
}

typealias LibraryBackupHook = @Sendable (
    _ priorBytes: Data,
    _ reason: LibraryBackupReason
) throws -> Void

