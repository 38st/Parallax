import Foundation

struct LibraryImportReplacementPriorLibrary {
    let applications: [ManagedApplication]
    let version: LibraryVersionToken
    let bytes: Data
}

struct LibraryImportReplacementEvidence {
    let id: UUID
    let applicationCount: Int
    let profileCount: Int
    let validationWarnings: [LibraryImportReplacementWarning]
    let expectedVersion: LibraryVersionToken
    let priorApplications: [ManagedApplication]
    let priorLibraryBytes: Data
    let preparedCommit: PreparedLibraryCommit
    let integritySHA256: String
}

struct LibraryImportReplacementExecutionOutcome {
    let snapshot: LibraryRepositorySnapshot
    let backup: LibraryRecoveryArtifact
}
