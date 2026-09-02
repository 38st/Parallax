import Foundation

enum StorageRelocationIsolationField: String, Codable, Hashable, Sendable {
    case userData
    case codexHome
}

struct StorageRelocationGeneratedRewrite: Equatable, Sendable {
    let profileID: UUID
    let field: StorageRelocationIsolationField
    let oldURL: URL
    let newURL: URL
}

struct StorageRelocationExternalPath: Equatable, Sendable {
    let profileID: UUID
    let field: StorageRelocationIsolationField
    let value: String
}

struct StorageTreeEstimate: Equatable, Sendable {
    var allocatedBytes: UInt64
    var itemCount: UInt64

    static let zero = StorageTreeEstimate(allocatedBytes: 0, itemCount: 0)

    static func + (
        lhs: StorageTreeEstimate,
        rhs: StorageTreeEstimate
    ) -> StorageTreeEstimate {
        StorageTreeEstimate(
            allocatedBytes: lhs.allocatedBytes + rhs.allocatedBytes,
            itemCount: lhs.itemCount + rhs.itemCount
        )
    }
}

enum StorageRelocationStrategy: String, Codable, Equatable, Sendable {
    case sameVolume
    case crossVolume
}

enum StorageRelocationBlocker: Equatable, Sendable {
    case sameStorageLocation
    case overlappingStorageLocations
    case unexpectedDestination
    case insufficientSpace(required: UInt64, available: UInt64)
    case capacityUnavailable
    case activeProfiles([UUID])
}

enum StorageRelocationProgress: Equatable, Sendable {
    case preparing
    case stagingApplication
    case stagingArchives
    case publishingApplication
    case publishingArchives
    case committingMetadata
    case cleaningSource
    case rollingBack
    case completed
}

enum StorageRelocationBoundary: Equatable, Sendable {
    case afterPlanDurable(UUID)
    case afterStaging(UUID)
    case beforeSourceCleanup(URL)
    case beforeCompletionReceipt(UUID)
}

struct StorageRelocationItemIdentity: Codable, Equatable, Sendable {
    let volumeID: UInt64
    let fileID: UInt64
    let kind: String
}

struct StorageRelocationManifestEntry: Codable, Equatable, Sendable {
    let relativeComponents: [String]
    let kind: String
    let byteCount: UInt64
    let permissions: UInt16
    let sha256: String?
}

struct StorageRelocationOwnedTreeSnapshot: Codable, Equatable, Sendable {
    let identity: StorageRelocationItemIdentity
    let manifest: [StorageRelocationManifestEntry]
}

struct StorageRelocationPreview: Equatable, Sendable {
    let requestID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let expectedVersion: LibraryVersionToken
    let originalApplication: ManagedApplication
    let relocatedApplication: ManagedApplication
    let source: ResolvedApplicationStoragePaths
    let destination: ResolvedApplicationStoragePaths
    let sourceEstimate: StorageTreeEstimate
    let sourceApplicationFingerprint: String?
    let sourceArchiveFingerprint: String?
    let sourceApplicationSnapshot: StorageRelocationOwnedTreeSnapshot?
    let sourceArchiveSnapshot: StorageRelocationOwnedTreeSnapshot?
    let destinationAvailableBytes: UInt64?
    let strategy: StorageRelocationStrategy
    let generatedRewrites: [StorageRelocationGeneratedRewrite]
    let preservedExternalPaths: [StorageRelocationExternalPath]
    let blockers: [StorageRelocationBlocker]
}

struct PendingStorageRelocation: Equatable, Sendable {
    let transactionID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let sourceBasePath: String
    let destinationBasePath: String
    let createdAt: Date
}

struct StorageRelocationOutcome: Equatable, Sendable {
    let transactionID: UUID
    let application: ManagedApplication
    let versionToken: LibraryVersionToken
    let receiptURL: URL?
}

enum StorageRelocationRecoveryOutcome: Equatable, Sendable {
    case committed(StorageRelocationOutcome)
    case rolledBack
}

protocol StorageRelocationActivityProviding: Sendable {
    func activeProfileStorageIDs(
        applicationStorageID: UUID,
        profileStorageIDs: Set<UUID>
    ) -> Set<UUID>
}

typealias StorageRelocationCancellation = CancellationFlag

struct StorageRelocationError: LocalizedError {
    enum Code: String, Equatable, Sendable {
        case blocked
        case activeProfile
        case stalePreview
        case cancelled
        case sourceChanged
        case unexpectedDestination
        case metadataCommitFailed
        case rollbackRequired
        case ambiguousLibraryState
        case invalidJournal
        case transactionNotFound
        case invalidReceipt
    }

    let code: Code
    let path: String?
    let detail: String?

    init(
        _ code: Code,
        path: String? = nil,
        detail: String? = nil
    ) {
        self.code = code
        self.path = path
        self.detail = detail
    }

    var errorDescription: String? {
        switch code {
        case .blocked:
            String(localized: "Storage relocation cannot start until every blocking issue is resolved.")
        case .activeProfile:
            String(localized: "Storage relocation cannot run while one of this application’s profiles is active.")
        case .stalePreview:
            String(localized: "The application or library changed after the storage preview was prepared. Review the relocation again.")
        case .cancelled:
            String(localized: "Storage relocation was cancelled and the original storage location was preserved.")
        case .sourceChanged:
            String(localized: "Managed profile data changed after the storage preview was prepared.")
        case .unexpectedDestination:
            String(localized: "Storage relocation stopped because an unexpected destination already exists at \(path ?? "the selected location").")
        case .metadataCommitFailed:
            String(localized: "The relocated data could not be committed to the library: \(detail ?? "unknown error")")
        case .rollbackRequired:
            String(localized: "Storage relocation could not finish restoring the original state. Recovery information remains at \(path ?? "the transaction staging folder").")
        case .ambiguousLibraryState:
            String(localized: "The library matches neither the original nor relocated storage state. Both data copies were preserved for recovery.")
        case .invalidJournal:
            String(localized: "The storage relocation journal failed integrity validation.")
        case .transactionNotFound:
            String(localized: "The storage relocation transaction could not be found.")
        case .invalidReceipt:
            String(localized: "The storage relocation recovery receipt is invalid.")
        }
    }
}

struct StorageRelocationVersionToken: Codable, Equatable, Sendable {
    let revision: LibraryRevision
    let primarySHA256: String?

    init(_ token: LibraryVersionToken) {
        revision = token.revision
        primarySHA256 = token.primarySHA256
    }

    var libraryToken: LibraryVersionToken {
        LibraryVersionToken(
            revision: revision,
            primarySHA256: primarySHA256
        )
    }
}

struct StorageRelocationReceipt: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case prepared
        case staged
        case published
        case metadataCommitted
        case cleanupRequired
        case completed
        case rolledBack
    }

    let transactionID: UUID
    let applicationID: UUID
    let applicationStorageID: UUID
    let priorVersion: StorageRelocationVersionToken
    let targetVersion: StorageRelocationVersionToken
    let sourceBasePath: String
    let destinationBasePath: String
    var state: State
    var detail: String?
}
