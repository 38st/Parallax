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
    let operation: ProfileDataTransactionOperation
    let dataMutation: ProfileDataMutation
    let externalDataHandling: ProfileExternalDataHandling
    let didArchiveData: Bool
    let archiveURL: URL?
    let receiptURL: URL
}

struct PendingProfileDataTransaction: Sendable, Equatable {
    let transactionID: UUID
    let identity: ProfileDataTransactionIdentity
    let operation: ProfileDataTransactionOperation
    let state: String
    let createdAt: Date
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
        let operationName = operation?.rawValue ?? String(localized: "profile data")
        switch code {
        case .unexpectedDestination:
            return String(
                localized: "The \(operationName) transaction stopped because an unexpected destination exists at \(path ?? "an unknown path")."
            )
        case .sameSourceAndDestination:
            return String(localized: "The profile data source and destination are the same.")
        case .sourceChanged:
            return String(localized: "Managed profile data changed during the transaction.")
        case .invalidJournal:
            return String(localized: "The profile transaction journal failed integrity validation.")
        case .invalidReceipt:
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
                localized: "Parallax could not prove ownership of transaction data at \(path ?? "an unknown path"), so it was preserved."
            )
        }
    }
}

/// Executes managed profile mutations through descriptor-relative filesystem
/// primitives and binds them to one prepared, compare-and-swap library commit.
///
/// The central ProfileTransactions index is independent of the mutable library
/// model and every record is write-once, canonical, and hash chained.
struct ProfileDataTransactionCoordinator: @unchecked Sendable {
    static let controlComponents = ["Parallax", "ProfileTransactions"]
    static let payloadOwnerPrefix = ".parallax-owner-"

    let applicationSupportURL: URL
    let controlRootURL: URL
    let controlRootIdentity: FileSystemObjectIdentity
    let control: SecureManagedFileSystem
    let fileSystem: any FileSystem
    let now: () -> Date
    let transactionBoundary:
        (@Sendable (ProfileDataTransactionBoundary) throws -> Void)?
    let secureBoundary:
        (@Sendable (URL, SecureManagedFileSystemBoundary) throws -> Void)?
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    init(
        applicationSupportURL: URL,
        fileSystem: any FileSystem = LocalFileSystem(),
        now: @escaping () -> Date = Date.init,
        transactionBoundary:
            (@Sendable (ProfileDataTransactionBoundary) throws -> Void)? = nil,
        secureBoundary:
            (@Sendable (URL, SecureManagedFileSystemBoundary) throws -> Void)? = nil
    ) throws {
        self.applicationSupportURL = applicationSupportURL
        self.fileSystem = fileSystem
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
