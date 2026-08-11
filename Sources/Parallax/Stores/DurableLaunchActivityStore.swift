import Darwin
import CryptoKit
import Foundation


enum DurableLaunchCompletion: String, Codable, Sendable {
    case failed
    case terminated
}

struct DurableLaunchArtifact: Sendable {
    enum State: Sendable {
        case requestOnly(owner: ProcessStartIdentity)
        case opening
        case running(ProcessStartIdentity)
        case completed
        case corrupt
    }

    let requestID: UUID?
    let identity: ProfileActivityIdentity?
    let state: State
    let directoryURL: URL
}

enum DurableLaunchActivityStoreError: LocalizedError {
    case invalidRoot(String)
    case requestAlreadyExists(UUID)
    case profileAlreadyActive
    case processAlreadyTracked(pid_t)
    case missingRequest(UUID)
    case immutableMarkerExists(String)
    case invalidProcessIdentity(pid_t)
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .invalidRoot(let path):
            String(localized: "The active-launch journal is unsafe at \(path).")
        case .requestAlreadyExists(let requestID):
            String(localized: "Launch request \(requestID.uuidString) already exists.")
        case .profileAlreadyActive:
            String(localized: "This profile is already launching or running.")
        case .processAlreadyTracked(let processIdentifier):
            String(
                localized:
                    "Process \(processIdentifier) is already attributed to another profile."
            )
        case .missingRequest(let requestID):
            String(localized: "Launch request \(requestID.uuidString) is missing.")
        case .immutableMarkerExists(let name):
            String(localized: "The immutable launch marker \(name) already exists.")
        case .invalidProcessIdentity(let processIdentifier):
            String(localized: "Process \(processIdentifier) has no verifiable start identity.")
        case .persistence(let detail):
            String(localized: "The active-launch journal could not be updated: \(detail)")
        }
    }
}

final class DurableLaunchActivityStore: @unchecked Sendable {
    private static let rootMarker = ".root-identity"
    private static let acquisitionLockFile = ".profile-acquisition.lock"

    let rootURL: URL
    private let fileManager: FileManager
    private let secureFileSystem: SecureManagedFileSystem
    private let codec = DurableLaunchJournalCodec()
    private let lock = NSLock()

    init(
        applicationSupportURL: URL,
        fileManager: FileManager = .default,
        boundaryHook:
            (@Sendable (SecureManagedFileSystemBoundary) throws -> Void)? = nil
    ) throws {
        self.fileManager = fileManager
        rootURL = applicationSupportURL
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("ActiveLaunches", isDirectory: true)
        secureFileSystem = try SecureManagedFileSystem(
            anchorURL: applicationSupportURL,
            rootComponents: ["Parallax", "ActiveLaunches"],
            createIfMissing: true,
            boundaryHook: boundaryHook
        )
        try ensureSafeRoot()
        try ensureRootMarker()
    }

    func createRequest(
        requestID: UUID,
        identity: ProfileActivityIdentity,
        ownerProcess: ProcessStartIdentity,
        allowsConcurrentProfile: Bool = false
    ) throws {
        try lock.withLock {
            try withInterprocessActivityLock {
                try ensureSafeRoot()
                let existing = try currentArtifacts()
                guard
                    !existing.contains(where: {
                        if case .corrupt = $0.state { return true }
                        return false
                    })
                else {
                    throw DurableLaunchActivityStoreError
                        .persistence(
                            "existing activity could not be verified"
                        )
                }
                if !allowsConcurrentProfile,
                   existing.contains(where: {
                       guard let existingIdentity = $0.identity else {
                           return false
                       }
                       if case .completed = $0.state { return false }
                       return existingIdentity.applicationStorageID
                               == identity.applicationStorageID
                           && existingIdentity.profileStorageID
                               == identity.profileStorageID
                   })
                {
                    throw DurableLaunchActivityStoreError
                        .profileAlreadyActive
                }

                let requestPath = try securePath(requestID: requestID)
                do {
                    try secureFileSystem.createDirectory(
                        at: requestPath,
                        permissions: 0o700
                    )
                } catch SecureManagedFileSystemError.unexpectedDestination {
                    throw DurableLaunchActivityStoreError
                        .requestAlreadyExists(requestID)
                } catch SecureManagedFileSystemError.systemCall(_, let code)
                    where code == EEXIST
                {
                        throw DurableLaunchActivityStoreError
                            .requestAlreadyExists(requestID)
                } catch {
                    throw error
                }
                do {
                    let file = try codec.encodeRequest(
                        requestID: requestID,
                        identity: identity,
                        ownerProcess: ownerProcess
                    )
                    try writeImmutable(
                        file.data,
                        requestID: requestID,
                        name: file.name
                    )
                } catch {
                    try? removeRequestDirectory(requestID: requestID)
                    throw error
                }
            }
        }
    }

    func markOpening(requestID: UUID) throws {
        try lock.withLock {
            _ = try validatedRequestDirectory(requestID)
            let file = try codec.encodeOpening(requestID: requestID)
            try writeImmutable(
                file.data,
                requestID: requestID,
                name: file.name
            )
        }
    }

    func recordProcess(
        requestID: UUID,
        process: ProcessStartIdentity
    ) throws {
        guard process.processIdentifier > 0 else {
            throw DurableLaunchActivityStoreError.invalidProcessIdentity(
                process.processIdentifier
            )
        }
        try lock.withLock {
            try withInterprocessActivityLock {
                _ = try validatedRequestDirectory(requestID)
                let duplicate = try currentArtifacts().contains {
                    artifact in
                    guard artifact.requestID != requestID else {
                        return false
                    }
                    if case .running(let existing) = artifact.state {
                        return existing == process
                    }
                    return false
                }
                guard !duplicate else {
                    throw DurableLaunchActivityStoreError
                        .processAlreadyTracked(process.processIdentifier)
                }
                let file = try codec.encodeProcess(
                    requestID: requestID,
                    process: process
                )
                try writeImmutable(
                    file.data,
                    requestID: requestID,
                    name: file.name
                )
            }
        }
    }

    func complete(
        requestID: UUID,
        completion: DurableLaunchCompletion
    ) throws {
        try lock.withLock {
            try withInterprocessActivityLock {
                _ = try validatedRequestDirectory(requestID)
                let completionPath = try securePath(
                    requestID: requestID,
                    name: codec.completionFileName
                )
                if case .missing = try secureFileSystem.itemState(
                    at: completionPath
                ) {
                    let file = try codec.encodeCompletion(
                        requestID: requestID,
                        completion: completion
                    )
                    try writeImmutable(
                        file.data,
                        requestID: requestID,
                        name: file.name
                    )
                }
                try removeRequestDirectory(requestID: requestID)
            }
        }
    }

    func artifacts() -> [DurableLaunchArtifact] {
        lock.withLock {
            do {
                try ensureSafeRoot()
                try verifyPinnedRoot()
                let artifacts = try fileManager.contentsOfDirectory(
                    at: rootURL,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).map(inspectArtifact)
                try verifyPinnedRoot()
                return artifacts
            } catch {
                return [
                    DurableLaunchArtifact(
                        requestID: nil,
                        identity: nil,
                        state: .corrupt,
                        directoryURL: rootURL
                    )
                ]
            }
        }
    }

    func removeProvenDeadArtifact(requestID: UUID) throws {
        try lock.withLock {
            try withInterprocessActivityLock {
                try ensureSafeRoot()
                try removeRequestDirectory(requestID: requestID)
            }
        }
    }

    private func currentArtifacts() throws -> [DurableLaunchArtifact] {
        try ensureSafeRoot()
        try verifyPinnedRoot()
        let artifacts = try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).map(inspectArtifact)
        try verifyPinnedRoot()
        return artifacts
    }

    private func withInterprocessActivityLock<Result>(
        _ body: () throws -> Result
    ) throws -> Result {
        try ensureSafeRoot()
        let directoryDescriptor = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw DurableLaunchActivityStoreError.invalidRoot(rootURL.path)
        }
        defer { Darwin.close(directoryDescriptor) }

        var pathInfo = stat()
        var descriptorInfo = stat()
        guard
            lstat(rootURL.path, &pathInfo) == 0,
            fstat(directoryDescriptor, &descriptorInfo) == 0,
            pathInfo.st_dev == descriptorInfo.st_dev,
            pathInfo.st_ino == descriptorInfo.st_ino
        else {
            throw DurableLaunchActivityStoreError.invalidRoot(rootURL.path)
        }

        let lockDescriptor = Self.acquisitionLockFile.withCString {
            Darwin.openat(
                directoryDescriptor,
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600)
            )
        }
        guard lockDescriptor >= 0 else {
            throw DurableLaunchActivityStoreError.persistence(
                "activity lock could not be opened"
            )
        }
        defer { Darwin.close(lockDescriptor) }
        guard
            fchmod(lockDescriptor, mode_t(0o600)) == 0,
            flock(lockDescriptor, LOCK_EX) == 0
        else {
            throw DurableLaunchActivityStoreError.persistence(
                "activity lock could not be acquired"
            )
        }
        defer { _ = flock(lockDescriptor, LOCK_UN) }

        guard
            lstat(rootURL.path, &pathInfo) == 0,
            fstat(directoryDescriptor, &descriptorInfo) == 0,
            pathInfo.st_dev == descriptorInfo.st_dev,
            pathInfo.st_ino == descriptorInfo.st_ino
        else {
            throw DurableLaunchActivityStoreError.invalidRoot(rootURL.path)
        }
        try verifyPinnedRoot()
        return try body()
    }

    private func inspectArtifact(_ directory: URL) -> DurableLaunchArtifact {
        do {
            try validateDirectory(directory)
            guard let directoryRequestID = UUID(
                uuidString: directory.lastPathComponent
            ) else {
                throw DurableLaunchActivityStoreError.persistence(
                    "invalid request directory"
                )
            }
            let pinnedManifest = try secureFileSystem.manifest(
                at: securePath(requestID: directoryRequestID)
            )
            let names = Set(
                try fileManager.contentsOfDirectory(atPath: directory.path)
            )
            var namedData: [String: DurableLaunchJournalCodec.NamedData] = [:]
            for name in codec.requiredFileNames(in: names) {
                do {
                    namedData[name] = .bytes(
                        try readJournalFile(
                            directory.appendingPathComponent(name),
                            expectedManifest: pinnedManifest,
                            relativeName: name
                        )
                    )
                } catch {
                    namedData[name] = .unreadable
                    break
                }
            }
            return codec.materialize(
                DurableLaunchJournalCodec.Snapshot(
                    directoryName: directory.lastPathComponent,
                    directoryURL: directory,
                    presentNames: names,
                    namedData: namedData
                )
            )
        } catch {
            return DurableLaunchArtifact(
                requestID: nil,
                identity: nil,
                state: .corrupt,
                directoryURL: directory
            )
        }
    }

    private func requestDirectory(_ requestID: UUID) -> URL {
        rootURL.appendingPathComponent(
            requestID.uuidString.lowercased(),
            isDirectory: true
        )
    }

    private func validatedRequestDirectory(_ requestID: UUID) throws -> URL {
        let directory = requestDirectory(requestID)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw DurableLaunchActivityStoreError.missingRequest(requestID)
        }
        try validateDirectory(directory)
        return directory
    }

    private func ensureSafeRoot() throws {
        try validateDirectory(rootURL)
    }

    private func ensureRootMarker() throws {
        let path = try SecureManagedPath([Self.rootMarker])
        switch try secureFileSystem.itemState(at: path) {
        case .missing:
            try secureFileSystem.write(
                Data("Parallax active-launch journal v1".utf8),
                to: path,
                permissions: 0o600
            )
        case .present(let identity):
            guard identity.kind == .regularFile else {
                throw DurableLaunchActivityStoreError.invalidRoot(rootURL.path)
            }
        }
    }

    private func verifyPinnedRoot() throws {
        let path = try SecureManagedPath([Self.rootMarker])
        guard case .present(let identity) =
            try secureFileSystem.itemState(at: path),
            identity.kind == .regularFile
        else {
            throw DurableLaunchActivityStoreError.invalidRoot(rootURL.path)
        }
    }

    private func validateDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            throw DurableLaunchActivityStoreError.invalidRoot(url.path)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            throw DurableLaunchActivityStoreError.invalidRoot(url.path)
        }
        guard (info.st_mode & mode_t(0o077)) == 0 else {
            throw DurableLaunchActivityStoreError.invalidRoot(url.path)
        }
    }

    private func readJournalFile(
        _ url: URL,
        expectedManifest: SecureManagedManifest,
        relativeName: String
    ) throws -> Data {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw DurableLaunchActivityStoreError.persistence(
                "missing or unsafe journal marker"
            )
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw DurableLaunchActivityStoreError.persistence(
                "missing journal marker"
            )
        }
        guard
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_nlink == 1,
            (info.st_mode & mode_t(0o077)) == 0,
            info.st_size >= 0,
            info.st_size <= 65_536
        else {
            throw DurableLaunchActivityStoreError.persistence(
                "unsafe journal marker"
            )
        }
        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { buffer in
            guard var pointer = buffer.baseAddress else { return }
            var remaining = buffer.count
            while remaining > 0 {
                let count = Darwin.read(descriptor, pointer, remaining)
                guard count > 0 else {
                    throw DurableLaunchActivityStoreError.persistence(
                        "truncated journal marker"
                    )
                }
                remaining -= count
                pointer = pointer.advanced(by: count)
            }
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard
            expectedManifest.entries.contains(where: {
                $0.relativeComponents == [relativeName]
                    && $0.kind == .regularFile
                    && $0.byteCount == UInt64(data.count)
                    && $0.sha256 == digest
            })
        else {
            throw DurableLaunchActivityStoreError.persistence(
                "journal marker identity changed"
            )
        }
        return data
    }

    private func writeImmutable(
        _ data: Data,
        requestID: UUID,
        name: String
    ) throws {
        let temporaryName = ".tmp-\(UUID().uuidString)"
        let temporaryPath = try securePath(
            requestID: requestID,
            name: temporaryName
        )
        let destinationPath = try securePath(
            requestID: requestID,
            name: name
        )
        do {
            try secureFileSystem.write(
                data,
                to: temporaryPath,
                permissions: 0o600
            )
            try secureFileSystem.rename(
                from: temporaryPath,
                to: destinationPath
            )
        } catch SecureManagedFileSystemError.unexpectedDestination {
            try? removeSecureItem(at: temporaryPath)
            throw DurableLaunchActivityStoreError.immutableMarkerExists(name)
        } catch {
            try? removeSecureItem(at: temporaryPath)
            throw error
        }
    }

    private func securePath(
        requestID: UUID,
        name: String? = nil
    ) throws -> SecureManagedPath {
        var components = [requestID.uuidString.lowercased()]
        if let name {
            components.append(name)
        }
        return try SecureManagedPath(components)
    }

    private func removeRequestDirectory(requestID: UUID) throws {
        try removeSecureItem(at: securePath(requestID: requestID))
    }

    private func removeSecureItem(at path: SecureManagedPath) throws {
        let state = try secureFileSystem.itemState(at: path)
        guard case .present(let identity) = state else {
            throw DurableLaunchActivityStoreError.persistence(
                "journal item is missing"
            )
        }
        let manifest = try secureFileSystem.manifest(at: path)
        try secureFileSystem.removeOwnedTree(
            at: path,
            expectedIdentity: identity,
            expectedManifest: manifest
        )
    }
}
