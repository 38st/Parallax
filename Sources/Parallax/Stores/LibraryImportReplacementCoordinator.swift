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
    private let planBuilder: LibraryImportReplacementPlanBuilder
    private let executor: LibraryImportReplacementExecutor
    private let undoExecutor: LibraryImportReplacementUndoExecutor

    init(
        repository: any LibraryRepositoryPersisting,
        backupStore: LibraryBackupStore,
        validator: LibraryImportValidator = LibraryImportValidator(),
        makePreviewID: @escaping () -> UUID = UUID.init
    ) {
        planBuilder = LibraryImportReplacementPlanBuilder(
            repository: repository,
            validator: validator,
            makePreviewID: makePreviewID
        )
        executor = LibraryImportReplacementExecutor(
            repository: repository,
            backupStore: backupStore,
            recovery: LibraryImportReplacementRecovery(
                repository: repository
            )
        )
        undoExecutor = LibraryImportReplacementUndoExecutor(
            repository: repository,
            backupStore: backupStore
        )
    }

    func preview(
        importData: Data,
        expectedVersion: LibraryVersionToken? = nil
    ) throws -> LibraryImportReplacementPreview {
        let evidence = try planBuilder.makeEvidence(
            importData: importData,
            expectedVersion: expectedVersion
        )
        return LibraryImportReplacementPreview(
            id: evidence.id,
            applicationCount: evidence.applicationCount,
            profileCount: evidence.profileCount,
            validationWarnings: evidence.validationWarnings,
            expectedVersion: evidence.expectedVersion,
            priorApplications: evidence.priorApplications,
            priorLibraryBytes: evidence.priorLibraryBytes,
            preparedCommit: evidence.preparedCommit,
            integritySHA256: evidence.integritySHA256
        )
    }

    func replace(
        using preview: LibraryImportReplacementPreview
    ) throws -> LibraryImportReplacementResult {
        let evidence = evidence(from: preview)
        try LibraryImportReplacementIntegrity.validate(evidence)
        let outcome = try executor.replace(using: evidence)
        return LibraryImportReplacementResult(
            previewID: preview.id,
            snapshot: outcome.snapshot,
            backup: outcome.backup
        )
    }

    /// Verifies the undo artifact and preserves the current primary before a
    /// caller performs a separately coordinated restore commit.
    func prepareUndo(
        for replacement: LibraryImportReplacementResult,
        replacing primaryURL: URL
    ) throws -> LibraryPrimaryRestorePreparation {
        try undoExecutor.prepareUndo(
            for: replacement,
            replacing: primaryURL
        )
    }

    /// Reverts this exact replacement through a new compare-and-swap commit.
    /// The replacement itself is backed up first, so undo never regresses the
    /// document revision and never overwrites a later writer.
    func undo(
        replacement: LibraryImportReplacementResult
    ) throws -> LibraryImportReplacementUndoResult {
        try undoExecutor.undo(replacement: replacement)
    }

    private func evidence(
        from preview: LibraryImportReplacementPreview
    ) -> LibraryImportReplacementEvidence {
        LibraryImportReplacementEvidence(
            id: preview.id,
            applicationCount: preview.applicationCount,
            profileCount: preview.profileCount,
            validationWarnings: preview.validationWarnings,
            expectedVersion: preview.expectedVersion,
            priorApplications: preview.priorApplications,
            priorLibraryBytes: preview.priorLibraryBytes,
            preparedCommit: preview.preparedCommit,
            integritySHA256: preview.integritySHA256
        )
    }
}
