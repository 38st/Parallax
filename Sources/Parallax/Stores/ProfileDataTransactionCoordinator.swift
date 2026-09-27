import Darwin
import Foundation

struct ProfileDataTransactionIdentity: Codable, Sendable, Equatable {
    let applicationID: UUID
    let applicationStorageID: UUID
    let sourceProfileID: UUID
    let sourceProfileStorageID: UUID
    let destinationProfileID: UUID?
    let destinationProfileStorageID: UUID?

    init(
        applicationID: UUID,
        applicationStorageID: UUID,
        sourceProfileID: UUID,
        sourceProfileStorageID: UUID,
        destinationProfileID: UUID? = nil,
        destinationProfileStorageID: UUID? = nil
    ) {
        self.applicationID = applicationID
        self.applicationStorageID = applicationStorageID
        self.sourceProfileID = sourceProfileID
        self.sourceProfileStorageID = sourceProfileStorageID
        self.destinationProfileID = destinationProfileID
        self.destinationProfileStorageID = destinationProfileStorageID
    }
}

enum ProfileDataTransactionOperation: String, Codable, Sendable, Equatable {
    case archive
    case clear
    case delete
    case duplicate
    case relocate

    var localizedName: String {
        switch self {
        case .archive: String(localized: "profile data operation name: archive")
        case .clear: String(localized: "profile data operation name: clear")
        case .delete: String(localized: "profile data operation name: delete")
        case .duplicate: String(localized: "profile data operation name: duplicate")
        case .relocate: String(localized: "profile data operation name: relocate")
        }
    }
}

enum ProfileExternalDataHandling: Codable, Sendable, Equatable {
    case notConfigured
    case configurationOnly(configuredPaths: [String])
}

enum ProfileDataMutation: String, Codable, Sendable, Equatable {
    case noManagedData
    case archivedManagedData
    case deletedManagedData
    case copiedManagedData
    case relocatedManagedData
    case rolledBack
}

struct ProfileDataTransactionRequest: Sendable {
    let transactionID: UUID
    let identity: ProfileDataTransactionIdentity
    let operation: ProfileDataTransactionOperation
    let source: ResolvedProfilePaths
    let destination: ResolvedProfilePaths?
    let externalDataHandling: ProfileExternalDataHandling
}

enum ProfileDataTransactionEffect: String, Codable, Sendable, Equatable {
    case createTransactionsDirectory
    case writeOwnerMarker
    case createStaging
    case moveToStaging
    case copyToStaging
    case writePayloadMarker
    case publishArchive
    case publishDestination
    case commitMetadata
    case removePayloadMarker
    case removeDeletedPayload
    case removeDuplicateDestination
    case removeRelocatedSource
    case removeStaging
    case removeOwnerMarker
    case writeReceipt
    case requireRecovery
}

enum ProfileDataTransactionBoundary: Sendable, Equatable {
    case beforeEffect(ProfileDataTransactionEffect)
    case afterEffectBeforeRecord(ProfileDataTransactionEffect)
    case afterRecord(ProfileDataTransactionEffect)
}

struct ProfileDataTransactionOutcome: Sendable, Equatable {
    let transactionID: UUID
    let operation: ProfileDataTransactionOperation?
    let dataMutation: ProfileDataMutation
    let externalDataHandling: ProfileExternalDataHandling
    let didArchiveData: Bool
    let archiveURL: URL?
    let receiptURL: URL?
    var operationFailure: String? = nil
}

struct PendingProfileDataTransaction: Sendable, Equatable {
    let transactionID: UUID
    let identity: ProfileDataTransactionIdentity?
    let operation: ProfileDataTransactionOperation?
    let state: String
    let createdAt: Date?
}

struct ProfileDataTransactionError: LocalizedError {
    enum Code: String, Sendable, Equatable {
        case unexpectedDestination
        case sameSourceAndDestination
        case sourceChanged
        case invalidJournal
        case invalidReceipt
        case transactionNotFound
        case rollbackRequired
        case unsupportedSymbolicLink
        case preparedCommitMismatch
        case ambiguousLibraryState
        case unownedData
    }

    let code: Code
    let operation: ProfileDataTransactionOperation?
    let path: String?
    let detail: String?

    init(
        _ code: Code,
        operation: ProfileDataTransactionOperation? = nil,
        path: String? = nil,
        detail: String? = nil
    ) {
        self.code = code
        self.operation = operation
        self.path = path
        self.detail = detail
    }

    var errorDescription: String? {
        let operationName = operation?.localizedName ?? String(localized: "profile data")
        switch code {
        case .unexpectedDestination:
            return String(
                localized: "The \(operationName) transaction stopped because an unexpected destination exists at \(path ?? String(localized: "an unknown path"))."
            )
        case .sameSourceAndDestination:
            return String(localized: "The profile data source and destination are the same.")
        case .sourceChanged:
            return String(localized: "Managed profile data changed during the transaction.")
        case .invalidJournal:
            if let path { return String(localized: "The profile transaction journal at \(path) failed integrity validation.") }
            return String(localized: "The profile transaction journal failed integrity validation.")
        case .invalidReceipt:
            if let path { return String(localized: "The profile transaction receipt at \(path) failed integrity validation.") }
            return String(localized: "The profile transaction receipt failed integrity validation.")
        case .transactionNotFound:
            return String(localized: "The profile transaction could not be found.")
        case .rollbackRequired:
            return String(localized: "The \(operationName) transaction requires recovery.")
        case .unsupportedSymbolicLink:
            return String(localized: "Managed profile data contains an unsupported symbolic link.")
        case .preparedCommitMismatch:
            return String(localized: "The prepared library commit does not match this profile transaction.")
        case .ambiguousLibraryState:
            return String(
                localized: "The library matches neither the prior nor prepared transaction version. No profile data was removed."
            )
        case .unownedData:
            return String(
                localized: "Parallax could not prove ownership of transaction data at \(path ?? String(localized: "an unknown path")), so it was preserved."
            )
        }
    }
}

/// Executes managed profile mutations through descriptor-relative filesystem
/// primitives and binds them to one prepared, compare-and-swap library commit.
///
/// The central ProfileTransactions index is independent of the mutable library
/// model and every record is write-once, canonical, and hash chained.
struct ProfileDataTransactionCoordinator: Sendable {
    // Legacy embedded manifests can exceed 4 MiB. Bound trusted control reads
    // to 64 MiB; new digest-only journals are substantially smaller.
    static let maximumJournalBytes = 64 * 1_024 * 1_024
    static let retainedCompletedTransactions = 8
    static let controlComponents = ["Parallax", "ProfileTransactions"]
    static let payloadOwnerPrefix = ".parallax-owner-"

    let applicationSupportURL: URL
    let controlRootURL: URL
    let controlRootIdentity: FileSystemObjectIdentity
    let control: SecureManagedFileSystem
    let fileSystem: any FileSystem
    let activityRegistry: ProfileActivityRegistry?
    let now: @Sendable () -> Date
    let transactionBoundary:
        (@Sendable (ProfileDataTransactionBoundary) throws -> Void)?
    let secureBoundary:
        (@Sendable (URL, SecureManagedFileSystemBoundary) throws -> Void)?
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    init(
        applicationSupportURL: URL,
        fileSystem: any FileSystem = LocalFileSystem(),
        activityRegistry: ProfileActivityRegistry? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        transactionBoundary:
            (@Sendable (ProfileDataTransactionBoundary) throws -> Void)? = nil,
        secureBoundary:
            (@Sendable (URL, SecureManagedFileSystemBoundary) throws -> Void)? = nil
    ) throws {
        self.applicationSupportURL = applicationSupportURL
        self.fileSystem = fileSystem
        self.activityRegistry = activityRegistry
        self.now = now
        self.transactionBoundary = transactionBoundary
        self.secureBoundary = secureBoundary
        control = try SecureManagedFileSystem(
            anchorURL: applicationSupportURL,
            rootComponents: Self.controlComponents,
            createIfMissing: true
        )
        controlRootURL = Self.controlComponents.reduce(applicationSupportURL) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        let attributes = try fileSystem.attributesOfItem(at: controlRootURL)
        guard
            attributes.kind == .directory,
            let identity = attributes.identity
        else {
            throw ProfileDataTransactionError(
                .invalidJournal,
                path: controlRootURL.path
            )
        }
        controlRootIdentity = identity

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

}

struct ProfileDataTransactionRecoveryFailure: LocalizedError {
    let operationError: any Error
    let recoveryError: any Error

    var errorDescription: String? {
        String(localized: "The profile data operation failed: \(operationError.localizedDescription) Recovery also failed: \(recoveryError.localizedDescription)")
    }
}
