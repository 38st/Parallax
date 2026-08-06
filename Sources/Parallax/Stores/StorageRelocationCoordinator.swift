import Darwin
import Foundation

/// Prepares and executes an application-wide managed-storage relocation.
///
/// Application and archive namespaces move together. Explicit isolation paths
/// are metadata owned by the user and are never copied or rewritten here.
struct StorageRelocationCoordinator: @unchecked Sendable {
    static let controlComponents = [
        "Parallax",
        "StorageRelocations",
    ]

    let fileSystem: any FileSystem
    let pathResolver: ManagedPathResolver
    let activityProvider: any StorageRelocationActivityProviding
    let capacityProvider: (URL) -> UInt64?
    let makeTransactionID: () -> UUID
    let now: () -> Date
    let transactionBoundary:
        (@Sendable (StorageRelocationBoundary) throws -> Void)?
    let controlRootURL: URL
    let controlRootIdentity: FileSystemObjectIdentity
    let control: SecureManagedFileSystem
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    init(
        applicationSupportURL: URL,
        fileSystem: any FileSystem,
        pathResolver: ManagedPathResolver? = nil,
        activityProvider: any StorageRelocationActivityProviding,
        availableCapacity: ((URL) -> UInt64?)? = nil,
        transactionID: @escaping () -> UUID = UUID.init,
        now: @escaping () -> Date = Date.init,
        transactionBoundary:
            (@Sendable (StorageRelocationBoundary) throws -> Void)? = nil
    ) throws {
        self.fileSystem = fileSystem
        self.pathResolver = pathResolver ?? ManagedPathResolver(fileSystem: fileSystem)
        self.activityProvider = activityProvider
        capacityProvider = availableCapacity ?? Self.systemAvailableCapacity
        self.makeTransactionID = transactionID
        self.now = now
        self.transactionBoundary = transactionBoundary
        control = try SecureManagedFileSystem(
            anchorURL: applicationSupportURL,
            rootComponents: Self.controlComponents,
            createIfMissing: true
        )
        controlRootURL = Self.controlComponents.reduce(
            applicationSupportURL
        ) {
            $0.appendingPathComponent($1, isDirectory: true)
        }
        let controlAttributes = try fileSystem.attributesOfItem(
            at: controlRootURL
        )
        guard
            controlAttributes.kind == .directory,
            let controlIdentity = controlAttributes.identity
        else {
            throw StorageRelocationError(
                .invalidJournal,
                path: controlRootURL.path
            )
        }
        try fileSystem.setPOSIXPermissions(0o700, at: controlRootURL)
        controlRootIdentity = controlIdentity
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

}
