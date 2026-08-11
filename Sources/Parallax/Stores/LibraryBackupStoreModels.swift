import Foundation

enum LibraryRecoveryArtifactKind: String, Codable, Sendable {
    case backup
    case quarantine
}

enum LibraryRecoveryArtifactContent: String, Codable, Sendable {
    case currentLibrary
    case legacyMigrationSource
    case unvalidatedQuarantine
}

enum LibraryBackupReason: String, Codable, Sendable {
    case migration
    case importReplacement
    case destructiveRewrite
    case corruptPrimary
    case manual
}

enum LibraryRecoveryArtifactProblem: String, Sendable, Equatable {
    case invalidMetadata
    case missingPayload
    case hashMismatch
    case invalidLibrary
}

struct LibraryRecoveryArtifact: Sendable, Equatable {
    let id: UUID
    let kind: LibraryRecoveryArtifactKind
    let reason: LibraryBackupReason
    let content: LibraryRecoveryArtifactContent
    let createdAt: Date
    let libraryURL: URL
    let byteCount: Int
    let sha256: String
}

struct LibraryRecoveryInspection: Sendable, Equatable {
    let artifact: LibraryRecoveryArtifact
    let problem: LibraryRecoveryArtifactProblem?

    var isVerified: Bool {
        problem == nil
    }

    var isRestorable: Bool {
        isVerified
            && artifact.kind == .backup
            && artifact.content == .currentLibrary
    }
}

struct LibraryRestorePreparation: Sendable, Equatable {
    let artifact: LibraryRecoveryArtifact
    let bytes: Data
}

struct LibraryPrimaryRestorePreparation: Sendable, Equatable {
    let restore: LibraryRestorePreparation
    let preservedPrimary: LibraryRecoveryArtifact?
}

struct LibraryStartOverPreparation: Sendable, Equatable {
    let quarantine: LibraryRecoveryArtifact
    let originalSHA256: String
    let emptyLibraryBytes: Data
}

enum LibraryBackupStoreError: LocalizedError, Equatable {
    case invalidRecoveryRoot
    case invalidArtifact
    case invalidMetadata
    case missingPayload
    case hashMismatch
    case invalidLibrary
    case notRestorable
    case noVerifiedBackup
    case destinationExists

    var errorDescription: String? {
        switch self {
        case .invalidRecoveryRoot:
            String(localized: "The library recovery folder is not a safe directory.")
        case .invalidArtifact:
            String(localized: "The selected recovery artifact does not belong to this library.")
        case .invalidMetadata:
            String(localized: "The recovery artifact metadata is invalid.")
        case .missingPayload:
            String(localized: "The recovery artifact no longer contains a library file.")
        case .hashMismatch:
            String(localized: "The recovery artifact failed integrity verification.")
        case .invalidLibrary:
            String(localized: "Only a structurally valid, supported library can be stored as a last-known-good backup.")
        case .notRestorable:
            String(localized: "The selected artifact is preserved for migration or inspection and cannot replace the current library.")
        case .noVerifiedBackup:
            String(localized: "No verified library backup is available.")
        case .destinationExists:
            String(localized: "The recovery export destination already exists.")
        }
    }
}

struct LibraryRecoveryArtifactMetadata: Codable, Sendable {
    static let currentVersion = 2

    let version: Int
    let id: UUID
    let kind: LibraryRecoveryArtifactKind
    let reason: LibraryBackupReason
    let content: LibraryRecoveryArtifactContent
    let createdAt: Date
    let byteCount: Int
    let sha256: String
}

struct VerifiedLibraryRecoveryArtifact {
    let artifact: LibraryRecoveryArtifact
    let bytes: Data
}
