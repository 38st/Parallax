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
    var isDataOperation = false
    var ownerProcess: ProcessStartIdentity?
}

enum DurableLaunchActivityStoreError: LocalizedError {
    case activityBusy
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
        case .activityBusy:
            String(localized: "Launch activity is being updated. Try again shortly.")
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

final class DurableLaunchActivityStore: Sendable {
    private static let rootMarker = ".root-identity"
    private static let acquisitionLockFile = ".profile-acquisition.lock"

    let rootURL: URL
    private let secureFileSystem: SecureManagedFileSystem
    private let codec = DurableLaunchJournalCodec()
    private let lock = NSLock()

    init(
        applicationSupportURL: URL,
        boundaryHook:
            (@Sendable (SecureManagedFileSystemBoundary) throws -> Void)? = nil
    ) throws {
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
        allowsConcurrentProfile: Bool = false,
        isDataOperation: Bool = false
    ) throws {
        try withActivityLock {
            try withInterprocessActivityLock {
                try ensureSafeRoot()
                let existing = try currentArtifacts()
                guard
                    !existing.contains(where: {
                        if case .corrupt = $0.state { return $0.identity == nil }
                        return false
                    })
                else {
                    throw DurableLaunchActivityStoreError
                        .persistence(
                            "existing activity could not be verified"
                        )
                }
                if existing.contains(where: {
                    guard case .corrupt = $0.state else { return false }
                    return $0.identity?.applicationStorageID == identity.applicationStorageID
                        && $0.identity?.profileStorageID == identity.profileStorageID
                }) {
                    throw DurableLaunchActivityStoreError.persistence(
                        "existing activity could not be verified")
                }
                if existing.contains(where: {
                    $0.isDataOperation
                        && $0.identity?.applicationStorageID == identity.applicationStorageID
                        && $0.identity?.profileStorageID == identity.profileStorageID
                }) {
                    throw ProfileActivityRegistryError.storageReservedForDataOperation
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
                        ownerProcess: ownerProcess,
                        isDataOperation: isDataOperation
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
        try withActivityLock {
            try withInterprocessActivityLock {
                _ = try validatedRequestDirectory(requestID)
                let file = try codec.encodeOpening(requestID: requestID)
                try writeImmutable(file.data, requestID: requestID, name: file.name)
            }
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
        try withActivityLock {
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
        try withActivityLock {
            try withInterprocessActivityLock {
                if case .missing = try secureFileSystem.itemState(
                    at: securePath(requestID: requestID)
                ) {
                    return
                }
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
                return try withInterprocessActivityLock {
                    try currentArtifacts()
                }
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

    func reconciliationArtifacts() throws -> [DurableLaunchArtifact] {
        guard lock.try() else { throw DurableLaunchActivityStoreError.activityBusy }
        defer { lock.unlock() }
        do {
            return try withInterprocessActivityLock(nonBlocking: true) { try currentArtifacts() }
        } catch DurableLaunchActivityStoreError.activityBusy {
            throw DurableLaunchActivityStoreError.activityBusy
        } catch {
            return [
                DurableLaunchArtifact(
                    requestID: nil, identity: nil, state: .corrupt, directoryURL: rootURL)
            ]
        }
    }

    @discardableResult
    func removeProvenDeadArtifact(
        requestID: UUID,
        processInspector: any ProcessIdentityInspecting
    ) throws -> Bool {
        try withActivityLock {
            try withInterprocessActivityLock {
                if case .missing = try secureFileSystem.itemState(
                    at: securePath(requestID: requestID)
                ) {
                    return true
                }
                let artifact = inspectArtifact(requestDirectory(requestID))
                let process: ProcessStartIdentity
                switch artifact.state {
                case .completed:
                    try removeRequestDirectory(requestID: requestID)
                    return true
                case .requestOnly(let owner):
                    process = owner
                case .running(let recorded):
                    process = recorded
                case .opening, .corrupt:
                    return false
                }
                switch processInspector.inspect(processIdentifier: process.processIdentifier) {
                case .dead:
                    break
                case .live(let current) where current != process:
                    break
                case .live, .ambiguous:
                    return false
                }
                try removeRequestDirectory(requestID: requestID)
                return true
            }
        }
    }

    func stuckLaunchRecords(
        identity: ProfileActivityIdentity,
        expectedApplication: WorkspaceApplicationBundleIdentity,
        processInspector: any ProcessIdentityInspecting,
        processSnapshotter: any WorkspaceLaunchProcessProvenanceInspecting,
        locallyRecoverableRequestIDs: Set<UUID> = []
    ) throws -> [StuckLaunchRecord] {
        try withActivityLock {
            try withInterprocessActivityLock {
                let artifacts = try currentArtifacts()
                guard !artifacts.contains(where: { $0.identity == nil }) else { return [] }
                let records = try artifacts.compactMap { artifact -> StuckLaunchRecord? in
                    guard artifact.identity == identity, let requestID = artifact.requestID else { return nil }
                    return try stuckLaunchRecord(requestID: requestID, identity: identity, processInspector: processInspector, locallyRecoverableRequestIDs: locallyRecoverableRequestIDs)
                }
                guard !records.isEmpty,
                    try applicationIsStopped(expectedApplication, processSnapshotter: processSnapshotter)
                else { return [] }
                return records
            }
        }
    }

    func clearStuckLaunchRecords(
        _ records: [StuckLaunchRecord],
        identity: ProfileActivityIdentity,
        expectedApplication: WorkspaceApplicationBundleIdentity,
        processInspector: any ProcessIdentityInspecting,
        processSnapshotter: any WorkspaceLaunchProcessProvenanceInspecting,
        locallyRecoverableRequestIDs: Set<UUID> = []
    ) throws {
        try withActivityLock {
            try withInterprocessActivityLock {
                guard !records.isEmpty,
                    Set(records.map(\.requestID)).count == records.count,
                    try applicationIsStopped(expectedApplication, processSnapshotter: processSnapshotter)
                else { throw StuckLaunchRecoveryError.changedOrActive }
                for record in records {
                    guard record.identity == identity,
                        try stuckLaunchRecord(requestID: record.requestID, identity: identity,
                                              processInspector: processInspector, locallyRecoverableRequestIDs: locallyRecoverableRequestIDs) == record
                    else { throw StuckLaunchRecoveryError.changedOrActive }
                }
                for record in records {
                    try removeRequestDirectory(requestID: record.requestID)
                }
            }
        }
    }

    private func applicationIsStopped(
        _ expected: WorkspaceApplicationBundleIdentity,
        processSnapshotter: any WorkspaceLaunchProcessProvenanceInspecting
    ) throws -> Bool {
        // These legacy receipts contain no process or data-path evidence. A
        // running instance cannot safely be ruled out by space attribution;
        // require the whole matching app to be stopped, including unknown instances.
        let snapshot = try processSnapshotter.snapshot(expectedApplication: expected)
        return snapshot.expectedApplication == expected && snapshot.processes.isEmpty
    }

    private func stuckLaunchRecord(
        requestID: UUID,
        identity: ProfileActivityIdentity,
        processInspector: any ProcessIdentityInspecting,
        locallyRecoverableRequestIDs: Set<UUID>
    ) throws -> StuckLaunchRecord? {
        let directory = requestDirectory(requestID)
        let artifact = inspectArtifact(directory)
        guard artifact.requestID == requestID, artifact.identity == identity,
            case .opening = artifact.state, !artifact.isDataOperation,
            let owner = artifact.ownerProcess, owner.processIdentifier > 0,
            owner.startTimeMicroseconds < 1_000_000,
            Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
                == ["request.json", "opening.json"]
        else { return nil }
        switch processInspector.inspect(processIdentifier: owner.processIdentifier) {
        case .dead:
            break
        case .live(let current) where current != owner:
            break
        case .live(let current) where current == owner && owner.processIdentifier == Darwin.getpid()
            && locallyRecoverableRequestIDs.contains(requestID):
            break
        case .live, .ambiguous:
            return nil
        }
        let path = try securePath(requestID: requestID)
        guard case .present(let directoryIdentity) = try secureFileSystem.itemState(at: path) else { return nil }
        return StuckLaunchRecord(requestID: requestID, identity: identity,
            directoryIdentity: directoryIdentity, manifest: try secureFileSystem.manifest(at: path))
    }

    private func currentArtifacts() throws -> [DurableLaunchArtifact] {
        try ensureSafeRoot()
        try verifyPinnedRoot()
        let artifacts = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: []
        ).compactMap { directory -> DurableLaunchArtifact? in
            let name = directory.lastPathComponent
            if name.hasPrefix(".removed-"), UUID(uuidString: String(name.dropFirst(9))) != nil {
                try validateDirectory(directory)
                try removeSecureItem(at: SecureManagedPath([name]))
                return nil
            }
            if name.hasPrefix(".") { return nil }
            guard let requestID = UUID(uuidString: directory.lastPathComponent),
                directory.lastPathComponent == requestID.uuidString.lowercased()
            else { return inspectArtifact(directory) }
            try validateDirectory(directory)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            if names.allSatisfy(DurableLaunchJournalCodec.isTemporaryFileName) {
                try removeRequestDirectory(requestID: requestID)
                return nil
            }
            for name in names where DurableLaunchJournalCodec.isTemporaryFileName(name) {
                try removeSecureItem(at: securePath(requestID: requestID, name: name))
            }
            return inspectArtifact(directory)
        }
        try verifyPinnedRoot()
        return artifacts
    }

    private func withActivityLock<Result>(_ body: () throws -> Result) throws -> Result {
        if Thread.isMainThread {
            guard lock.try() else { throw DurableLaunchActivityStoreError.activityBusy }
        } else {
            lock.lock()
        }
        defer { lock.unlock() }
        return try body()
    }

    private func withInterprocessActivityLock<Result>(
        nonBlocking: Bool = false,
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
            Self.retryInterrupted({
                flock(
                    lockDescriptor, LOCK_EX | ((nonBlocking || Thread.isMainThread) ? LOCK_NB : 0))
            }) == 0
        else {
            if errno == EWOULDBLOCK { throw DurableLaunchActivityStoreError.activityBusy }
            throw DurableLaunchActivityStoreError.persistence(
                "activity lock could not be acquired"
            )
        }
        defer { _ = Self.retryInterrupted { flock(lockDescriptor, LOCK_UN) } }

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
                try FileManager.default.contentsOfDirectory(
                    atPath: directory.path
                )
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
        guard FileManager.default.fileExists(atPath: directory.path) else {
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
                if count < 0, errno == EINTR { continue }
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
        let path = try securePath(requestID: requestID)
        if case .missing = try secureFileSystem.itemState(at: path) { return }
        // Retire the whole receipt before unlinking any marker. An interrupted
        // cleanup must never make a completed request look live again.
        let tombstone = try SecureManagedPath([".removed-\(UUID().uuidString)"])
        try secureFileSystem.rename(from: path, to: tombstone)
        try removeSecureItem(at: tombstone)
    }

    private static func retryInterrupted(_ operation: () -> Int32) -> Int32 {
        var result: Int32
        repeat { result = operation() } while result < 0 && errno == EINTR
        return result
    }

    private func removeSecureItem(at path: SecureManagedPath) throws {
        let state = try secureFileSystem.itemState(at: path)
        guard case .present(let identity) = state else { return }
        let manifest = try secureFileSystem.manifest(at: path)
        try secureFileSystem.removeOwnedTree(
            at: path,
            expectedIdentity: identity,
            expectedManifest: manifest
        )
    }
}
