import Foundation

struct LibraryImportReplacementWarning: Sendable, Equatable, Hashable {
    enum Severity: String, Sendable, Equatable, Hashable {
        case information
        case warning
    }

    let code: String
    let severity: Severity
    let path: String
    let message: String
}

struct LibraryImportReplacementPreview: Sendable, Equatable {
    let id: UUID
    let applicationCount: Int
    let profileCount: Int
    let validationWarnings: [LibraryImportReplacementWarning]
    let expectedVersion: LibraryVersionToken

    fileprivate let priorApplications: [ManagedApplication]
    fileprivate let priorLibraryBytes: Data
    fileprivate let preparedCommit: PreparedLibraryCommit
    fileprivate let integritySHA256: String

    fileprivate init(
        id: UUID,
        applicationCount: Int,
        profileCount: Int,
        validationWarnings: [LibraryImportReplacementWarning],
        expectedVersion: LibraryVersionToken,
        priorApplications: [ManagedApplication],
        priorLibraryBytes: Data,
        preparedCommit: PreparedLibraryCommit,
        integritySHA256: String
    ) {
        self.id = id
        self.applicationCount = applicationCount
        self.profileCount = profileCount
        self.validationWarnings = validationWarnings
        self.expectedVersion = expectedVersion
        self.priorApplications = priorApplications
        self.priorLibraryBytes = priorLibraryBytes
        self.preparedCommit = preparedCommit
        self.integritySHA256 = integritySHA256
    }
}

struct LibraryImportReplacementResult: Sendable, Equatable {
    let previewID: UUID
    let snapshot: LibraryRepositorySnapshot
    let backup: LibraryRecoveryArtifact

    fileprivate init(
        previewID: UUID,
        snapshot: LibraryRepositorySnapshot,
        backup: LibraryRecoveryArtifact
    ) {
        self.previewID = previewID
        self.snapshot = snapshot
        self.backup = backup
    }
}

struct LibraryImportReplacementUndoResult: Sendable, Equatable {
    let snapshot: LibraryRepositorySnapshot
    let replacementBackup: LibraryRecoveryArtifact
}

struct LibraryImportReplacementError: LocalizedError {
    enum Code: String, Sendable, Equatable {
        case libraryUnavailable
        case validationFailed
        case invalidPreview
        case backupVerificationFailed
        case replacementFailedAndRolledBack
        case recoveryRequired
        case undoNoLongerValid
    }

    let code: Code
    let detail: String?

    init(_ code: Code, detail: String? = nil) {
        self.code = code
        self.detail = detail
    }

    var errorDescription: String? {
        switch code {
        case .libraryUnavailable:
            String(
                localized: "The active library is not available for replacement."
            )
        case .validationFailed:
            String(
                localized: "The imported library contains validation errors and cannot replace the active library."
            )
        case .invalidPreview:
            String(
                localized: "The import replacement preview is no longer valid. Preview the import again."
            )
        case .backupVerificationFailed:
            String(
                localized: "Parallax could not verify the undo backup, so the active library was not replaced."
            )
        case .replacementFailedAndRolledBack:
            String(
                localized: "The imported library could not be confirmed and the prior library was restored."
            )
        case .recoveryRequired:
            String(
                localized: "The import replacement could not be completed or rolled back safely. Use the verified recovery backup before editing the library."
            )
        case .undoNoLongerValid:
            String(
                localized:
                    "This import replacement can no longer be undone because the active library changed afterward."
            )
        }
    }
}

/// Coordinates a metadata-only replace import.
///
/// The imported document is prepared against an immutable repository version.
/// Execution first publishes and re-verifies an exact-byte backup, then uses
/// the repository's exclusive compare-and-swap commit. This coordinator never
/// reads, moves, creates, or removes profile-data roots.
struct LibraryImportReplacementCoordinator {
    private let repository: any LibraryRepositoryPersisting
    private let backupStore: LibraryBackupStore
    private let validator: LibraryImportValidator
    private let makePreviewID: () -> UUID

    init(
        repository: any LibraryRepositoryPersisting,
        backupStore: LibraryBackupStore,
        validator: LibraryImportValidator = LibraryImportValidator(),
        makePreviewID: @escaping () -> UUID = UUID.init
    ) {
        self.repository = repository
        self.backupStore = backupStore
        self.validator = validator
        self.makePreviewID = makePreviewID
    }

    func preview(
        importData: Data,
        expectedVersion: LibraryVersionToken? = nil
    ) throws -> LibraryImportReplacementPreview {
        let report = validator.validate(importData)
        guard
            report.isValid,
            let document = report.document
        else {
            throw LibraryImportReplacementError(.validationFailed)
        }
        let warnings = report.issues
            .filter { $0.severity == .warning }
            .map {
                LibraryImportReplacementWarning(
                    code: $0.code.rawValue,
                    severity: .warning,
                    path: $0.path,
                    message: $0.message
                )
            }
        return try makePreview(
            replacementApplications: document.applications,
            validationWarnings: warnings,
            expectedVersion: expectedVersion
        )
    }

    private func makePreview(
        replacementApplications: [ManagedApplication],
        validationWarnings: [LibraryImportReplacementWarning],
        expectedVersion: LibraryVersionToken?
    ) throws -> LibraryImportReplacementPreview {
        let prior: PriorLibrary
        switch repository.load() {
        case .missing:
            prior = PriorLibrary(
                applications: [],
                version: .missing,
                bytes: try encodedEmptyLibrary()
            )
        case let .loaded(snapshot):
            prior = PriorLibrary(
                applications: snapshot.applications,
                version: snapshot.versionToken,
                bytes: snapshot.originalBytes
            )
        case .migrationRequired, .recoveryRequired, .readOnly:
            throw LibraryImportReplacementError(.libraryUnavailable)
        }
        if let expectedVersion,
           prior.version != expectedVersion
        {
            throw LibraryImportReplacementError(.invalidPreview)
        }

        let prepared = try repository.prepare(
            replacementApplications,
            expectedVersion: prior.version
        )
        let id = makePreviewID()
        let applicationCount = replacementApplications.count
        let profileCount = replacementApplications.reduce(into: 0) {
            $0 += $1.profiles.count
        }
        let integrity = previewIntegrity(
            id: id,
            applicationCount: applicationCount,
            profileCount: profileCount,
            warnings: validationWarnings,
            expectedVersion: prior.version,
            priorBytes: prior.bytes,
            preparedCommit: prepared
        )
        return LibraryImportReplacementPreview(
            id: id,
            applicationCount: applicationCount,
            profileCount: profileCount,
            validationWarnings: validationWarnings,
            expectedVersion: prior.version,
            priorApplications: prior.applications,
            priorLibraryBytes: prior.bytes,
            preparedCommit: prepared,
            integritySHA256: integrity
        )
    }

    func replace(
        using preview: LibraryImportReplacementPreview
    ) throws -> LibraryImportReplacementResult {
        try validate(preview)

        let backup = try backupStore.createBackup(
            of: preview.priorLibraryBytes,
            reason: .importReplacement
        )
        let verified = try backupStore.prepareRestore(from: backup)
        guard verified.bytes == preview.priorLibraryBytes else {
            throw LibraryImportReplacementError(
                .backupVerificationFailed
            )
        }

        do {
            let snapshot = try repository.withExclusiveMutation(
                expectedVersion: preview.expectedVersion
            ) { capability in
                guard
                    capability.applications == preview.priorApplications,
                    capability.versionToken == preview.expectedVersion
                else {
                    throw LibraryImportReplacementError(.invalidPreview)
                }
                return try capability.commit(
                    preview.preparedCommit
                ).snapshot
            }
            guard
                snapshot.versionToken == preview.preparedCommit.targetVersion,
                snapshot.applications
                    == preview.preparedCommit.applications
            else {
                throw LibraryImportReplacementError(.recoveryRequired)
            }
            return LibraryImportReplacementResult(
                previewID: preview.id,
                snapshot: snapshot,
                backup: backup
            )
        } catch {
            try recoverFailedReplacementIfNeeded(
                preview: preview,
                originalError: error
            )
            throw error
        }
    }

    /// Verifies the undo artifact and preserves the current primary before a
    /// caller performs a separately coordinated restore commit.
    func prepareUndo(
        for replacement: LibraryImportReplacementResult,
        replacing primaryURL: URL
    ) throws -> LibraryPrimaryRestorePreparation {
        try backupStore.preparePrimaryRestore(
            from: replacement.backup,
            replacing: primaryURL
        )
    }

    /// Reverts this exact replacement through a new compare-and-swap commit.
    /// The replacement itself is backed up first, so undo never regresses the
    /// document revision and never overwrites a later writer.
    func undo(
        replacement: LibraryImportReplacementResult
    ) throws -> LibraryImportReplacementUndoResult {
        let restore = try backupStore.prepareRestore(
            from: replacement.backup
        )
        let priorApplications = try LibraryPersistence
            .decodeApplications(from: restore.bytes)
        let current: LibraryRepositorySnapshot
        guard
            case let .loaded(loaded) = repository.load(),
            loaded.versionToken == replacement.snapshot.versionToken,
            loaded.applications == replacement.snapshot.applications
        else {
            throw LibraryImportReplacementError(.undoNoLongerValid)
        }
        current = loaded

        let replacementBackup = try backupStore.createBackup(
            of: current.originalBytes,
            reason: .destructiveRewrite
        )
        let verifiedReplacement = try backupStore.prepareRestore(
            from: replacementBackup
        )
        guard verifiedReplacement.bytes == current.originalBytes else {
            throw LibraryImportReplacementError(
                .backupVerificationFailed
            )
        }

        let prepared = try repository.prepare(
            priorApplications,
            expectedVersion: current.versionToken
        )
        let snapshot = try repository.withExclusiveMutation(
            expectedVersion: current.versionToken
        ) { capability in
            guard
                capability.applications == current.applications,
                capability.versionToken == current.versionToken
            else {
                throw LibraryImportReplacementError(
                    .undoNoLongerValid
                )
            }
            return try capability.commit(prepared).snapshot
        }
        return LibraryImportReplacementUndoResult(
            snapshot: snapshot,
            replacementBackup: replacementBackup
        )
    }

    private func validate(
        _ preview: LibraryImportReplacementPreview
    ) throws {
        guard
            preview.applicationCount
                == preview.preparedCommit.applications.count,
            preview.profileCount
                == preview.preparedCommit.applications.reduce(into: 0, {
                    $0 += $1.profiles.count
                }),
            preview.expectedVersion == preview.preparedCommit.priorVersion,
            preview.preparedCommit.targetVersion.primarySHA256
                == LibraryPersistence.sha256(
                    preview.preparedCommit.targetBytes
                ),
            preview.integritySHA256 == previewIntegrity(
                id: preview.id,
                applicationCount: preview.applicationCount,
                profileCount: preview.profileCount,
                warnings: preview.validationWarnings,
                expectedVersion: preview.expectedVersion,
                priorBytes: preview.priorLibraryBytes,
                preparedCommit: preview.preparedCommit
            )
        else {
            throw LibraryImportReplacementError(.invalidPreview)
        }
    }

    private func recoverFailedReplacementIfNeeded(
        preview: LibraryImportReplacementPreview,
        originalError: Error
    ) throws {
        let current: LibraryRepositorySnapshot
        switch repository.load() {
        case let .loaded(snapshot):
            current = snapshot
        case .missing:
            if preview.expectedVersion == .missing {
                return
            }
            throw LibraryImportReplacementError(
                .recoveryRequired,
                detail: String(reflecting: type(of: originalError))
            )
        case .migrationRequired, .recoveryRequired, .readOnly:
            throw LibraryImportReplacementError(
                .recoveryRequired,
                detail: String(reflecting: type(of: originalError))
            )
        }

        if current.versionToken == preview.expectedVersion {
            return
        }
        guard
            current.versionToken == preview.preparedCommit.targetVersion,
            current.applications == preview.preparedCommit.applications
        else {
            // A stale competing writer is not rollback authority.
            if case LibraryRepositoryError.staleWriter = originalError {
                return
            }
            throw LibraryImportReplacementError(
                .recoveryRequired,
                detail: String(reflecting: type(of: originalError))
            )
        }

        do {
            let rollback = try repository.prepare(
                preview.priorApplications,
                expectedVersion: current.versionToken
            )
            _ = try repository.withExclusiveMutation(
                expectedVersion: current.versionToken
            ) { capability in
                try capability.commit(rollback)
            }
        } catch {
            if case let .loaded(snapshot) = repository.load(),
               snapshot.applications == preview.priorApplications {
                throw LibraryImportReplacementError(
                    .replacementFailedAndRolledBack,
                    detail: String(reflecting: type(of: originalError))
                )
            }
            throw LibraryImportReplacementError(
                .recoveryRequired,
                detail: String(reflecting: type(of: error))
            )
        }
        throw LibraryImportReplacementError(
            .replacementFailedAndRolledBack,
            detail: String(reflecting: type(of: originalError))
        )
    }

    private func previewIntegrity(
        id: UUID,
        applicationCount: Int,
        profileCount: Int,
        warnings: [LibraryImportReplacementWarning],
        expectedVersion: LibraryVersionToken,
        priorBytes: Data,
        preparedCommit: PreparedLibraryCommit
    ) -> String {
        var fields = [
            id.uuidString.lowercased(),
            String(applicationCount),
            String(profileCount),
            String(expectedVersion.revision.rawValue),
            expectedVersion.primarySHA256 ?? "",
            LibraryPersistence.sha256(priorBytes),
            String(preparedCommit.targetVersion.revision.rawValue),
            preparedCommit.targetVersion.primarySHA256 ?? "",
            LibraryPersistence.sha256(preparedCommit.targetBytes),
        ]
        fields.append(
            contentsOf: warnings.map {
                [$0.code, $0.severity.rawValue, $0.path, $0.message]
                    .joined(separator: "\u{1f}")
            }
        )
        return LibraryPersistence.sha256(
            Data(fields.joined(separator: "\n").utf8)
        )
    }

    private func encodedEmptyLibrary() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(
            LibraryDocument(
                revision: .initial,
                applications: []
            )
        )
    }

    private struct PriorLibrary {
        let applications: [ManagedApplication]
        let version: LibraryVersionToken
        let bytes: Data
    }
}
