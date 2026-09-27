import Foundation
import Darwin

final class LibraryMutationCommitCapability {
    let applications: [ManagedApplication]
    let versionToken: LibraryVersionToken

    private enum State {
        case active
        case consumed
        case expired
    }

    private let persistence: LibraryPersistence
    private let priorBytes: Data?
    private let backupHook: LibraryBackupHook?
    private let stateLock = NSLock()
    private var state: State = .active

    fileprivate init(
        applications: [ManagedApplication],
        versionToken: LibraryVersionToken,
        priorBytes: Data?,
        persistence: LibraryPersistence,
        backupHook: LibraryBackupHook?
    ) {
        self.applications = applications
        self.versionToken = versionToken
        self.priorBytes = priorBytes
        self.persistence = persistence
        self.backupHook = backupHook
    }

    func commit(
        _ prepared: PreparedLibraryCommit,
        backupReason: LibraryBackupReason? = nil
    ) throws -> LibraryPreparedCommitResult {
        try consume()
        guard prepared.priorVersion == versionToken else {
            throw LibraryRepositoryError.preparedVersionMismatch
        }
        guard versionToken.revision.rawValue < UInt64.max else {
            throw LibraryRepositoryError.revisionOverflow
        }
        let decoded = try LibraryPersistence.decodeCurrentDocument(
            from: prepared.targetBytes
        )
        guard
            prepared.targetVersion.primarySHA256
                == LibraryPersistence.sha256(prepared.targetBytes),
            prepared.targetVersion.revision.rawValue
                == versionToken.revision.rawValue + 1,
            decoded.revision == prepared.targetVersion.revision,
            decoded.applications == prepared.applications
        else {
            throw LibraryRepositoryError.preparedVersionMismatch
        }

        if let backupReason, let priorBytes {
            guard let backupHook else {
                throw LibraryRepositoryError.backupUnavailable
            }
            try backupHook(priorBytes, backupReason)
        }

        switch persistence.commitPreparedDocument(
            prepared.targetBytes,
            expectedVersion: prepared.priorVersion,
            targetVersion: prepared.targetVersion
        ) {
        case let .target(snapshot, failure):
            if let failure {
                throw LibraryRepositoryError.commitFailed(
                    state: .target,
                    failure: failure
                )
            }
            return LibraryPreparedCommitResult(
                primaryState: .target,
                snapshot: Self.snapshot(from: snapshot)
            )
        case let .stale(actual):
            throw LibraryRepositoryError.staleWriter(
                expected: versionToken,
                actual: actual
            )
        case let .prior(failure):
            throw LibraryRepositoryError.commitFailed(
                state: .prior,
                failure: failure
            )
        case let .neither(failure):
            throw LibraryRepositoryError.commitFailed(
                state: .neither,
                failure: failure
            )
        }
    }

    func publish(
        applications: [ManagedApplication],
        backupReason: LibraryBackupReason? = nil
    ) throws -> LibraryRepositorySnapshot {
        let prepared = try Self.prepare(
            applications,
            expectedVersion: versionToken,
            persistence: persistence
        )
        return try commit(
            prepared,
            backupReason: backupReason
        ).snapshot
    }

    fileprivate func invalidate() {
        stateLock.withLock {
            state = .expired
        }
    }

    fileprivate static func prepare(
        _ applications: [ManagedApplication],
        expectedVersion: LibraryVersionToken,
        persistence: LibraryPersistence
    ) throws -> PreparedLibraryCommit {
        guard expectedVersion.revision.rawValue < UInt64.max else {
            throw LibraryRepositoryError.revisionOverflow
        }
        try LibraryPersistence.validateCurrentApplications(applications)
        let document = LibraryDocument(
            revision: LibraryRevision(
                rawValue: expectedVersion.revision.rawValue + 1
            ),
            applications: applications
        )
        let bytes = try persistence.encodeDocument(document)
        return PreparedLibraryCommit(
            priorVersion: expectedVersion,
            targetVersion: LibraryVersionToken(
                revision: document.revision,
                primarySHA256: LibraryPersistence.sha256(bytes)
            ),
            targetBytes: bytes,
            applications: applications
        )
    }

    private static func snapshot(
        from snapshot: CurrentLibrarySnapshot
    ) -> LibraryRepositorySnapshot {
        LibraryRepositorySnapshot(
            applications: snapshot.document.applications,
            versionToken: LibraryVersionToken(
                revision: snapshot.document.revision,
                primarySHA256: snapshot.sourceSHA256
            ),
            originalBytes: snapshot.originalBytes
        )
    }

    private func consume() throws {
        try stateLock.withLock {
            switch state {
            case .active:
                state = .consumed
            case .consumed:
                throw LibraryRepositoryError.mutationAlreadyPublished
            case .expired:
                throw LibraryRepositoryError.mutationSessionExpired
            }
        }
    }
}

/// Proof of synchronous, exclusive access to one library. It cannot be created
/// outside the repository, transferred to another thread, or used after the body
/// returns. Recovery entry points should accept this value instead of re-locking.
final class LibraryExclusiveAccess {
    private let lockURL: URL
    private let thread = Thread.current
    private var isActive = true

    fileprivate init(lockURL: URL) {
        self.lockURL = lockURL.standardizedFileURL.resolvingSymlinksInPath()
    }

    fileprivate func invalidate() { isActive = false }

    func validate(for repository: any LibraryRepositoryPersisting) throws {
        try validate(applicationSupportURL: repository.persistence.resolvedApplicationSupportURL())
    }

    func validate(applicationSupportURL: URL) throws {
        let expected = applicationSupportURL.appendingPathComponent("Parallax/.library.lock")
            .standardizedFileURL.resolvingSymlinksInPath()
        guard isActive, Thread.current == thread, expected == lockURL else {
            throw LibraryRepositoryError.invalidExclusiveAccess
        }
    }
}

/// Coordinates durable, compare-and-swap access to one library document.
///
/// The advisory lock spans stale-version validation, caller filesystem work,
/// backup creation, and exact metadata publication. Closing its descriptor
/// releases ownership even after abnormal process termination.
struct LibraryRepository: LibraryRepositoryPersisting, Sendable {
    private let documentPersistence: LibraryPersistence
    var persistence: any LibraryRepositoryPersistence { documentPersistence }
    private let fileSystem: any FileSystem
    private let applicationSupportURL: URL?
    private let backupHook: LibraryBackupHook?
    private let lockTimeout: TimeInterval

    init(
        fileSystem: any FileSystem = LocalFileSystem(),
        applicationSupportURL: URL? = nil,
        backupHook: LibraryBackupHook? = nil,
        lockTimeout: TimeInterval = 2
    ) {
        precondition(
            lockTimeout.isFinite && lockTimeout >= 0,
            "Lock timeout must be finite and nonnegative"
        )
        self.fileSystem = fileSystem
        self.applicationSupportURL = applicationSupportURL
        self.backupHook = backupHook
        self.lockTimeout = lockTimeout
        documentPersistence = LibraryPersistence(
            fileSystem: fileSystem,
            applicationSupportURL: applicationSupportURL
        )
    }

    func load() -> LibraryRepositoryLoadOutcome {
        switch documentPersistence.inspect() {
        case .missing:
            return .missing
        case let .current(snapshot):
            return .loaded(
                LibraryRepositorySnapshot(
                    applications: snapshot.document.applications,
                    versionToken: LibraryVersionToken(
                        revision: snapshot.document.revision,
                        primarySHA256: snapshot.sourceSHA256
                    ),
                    originalBytes: snapshot.originalBytes
                )
            )
        case let .legacy(snapshot):
            return .migrationRequired(snapshot)
        case let .recoveryRequired(failure):
            if case LibraryPersistenceError.unsupportedVersion = failure.error {
                return .readOnly(failure)
            }
            return .recoveryRequired(failure)
        }
    }

    func prepare(
        _ applications: [ManagedApplication],
        expectedVersion: LibraryVersionToken
    ) throws -> PreparedLibraryCommit {
        try LibraryMutationCommitCapability.prepare(
            applications,
            expectedVersion: expectedVersion,
            persistence: documentPersistence
        )
    }

    @discardableResult
    func save(
        _ applications: [ManagedApplication],
        expectedVersion: LibraryVersionToken,
        backupReason: LibraryBackupReason? = nil
    ) throws -> LibraryRepositorySnapshot {
        let prepared = try prepare(
            applications,
            expectedVersion: expectedVersion
        )
        return try withExclusiveMutation(
            expectedVersion: expectedVersion
        ) { capability in
            try capability.commit(
                prepared,
                backupReason: backupReason
            ).snapshot
        }
    }

    func tryWithExclusiveAccess<T>(
        _ body: (LibraryExclusiveAccess) throws -> T
    ) throws -> LibraryExclusiveAccessResult<T> {
        let lock: LibraryAdvisoryLock
        do {
            lock = try advisoryLock()
        } catch {
            throw LibraryAdvisoryLockError.unavailable(error)
        }
        return try lock.tryWithExclusiveLock {
            let access = LibraryExclusiveAccess(lockURL: lock.url)
            defer { access.invalidate() }
            return try body(access)
        }
    }

    private func advisoryLock() throws -> LibraryAdvisoryLock {
        let applicationSupportURL = if let applicationSupportURL {
            applicationSupportURL
        } else {
            try fileSystem.applicationSupportURL(create: true)
        }
        let parallaxDirectory = applicationSupportURL
            .appendingPathComponent("Parallax", isDirectory: true)
        try fileSystem.createDirectory(
            at: parallaxDirectory,
            withIntermediateDirectories: true
        )
        return LibraryAdvisoryLock(
            url: parallaxDirectory.appendingPathComponent(
                ".library.lock",
                isDirectory: false
            ),
            timeout: lockTimeout
        )
    }

    func withExclusiveMutation<T>(
        expectedVersion: LibraryVersionToken,
        _ body: (LibraryMutationCommitCapability) throws -> T
    ) throws -> T {
        let lock = try advisoryLock()

        return try lock.withExclusiveLock {
            let actualVersion: LibraryVersionToken
            let applications: [ManagedApplication]
            let priorBytes: Data?
            switch documentPersistence.inspect() {
            case .missing:
                actualVersion = .missing
                applications = []
                priorBytes = nil
            case let .current(snapshot):
                actualVersion = LibraryVersionToken(
                    revision: snapshot.document.revision,
                    primarySHA256: snapshot.sourceSHA256
                )
                applications = snapshot.document.applications
                priorBytes = snapshot.originalBytes
            case let .legacy(snapshot):
                throw LibraryRepositoryError.migrationRequired(
                    snapshot.library.format
                )
            case let .recoveryRequired(failure):
                throw LibraryRepositoryError.libraryUnavailable(failure)
            }

            guard expectedVersion == actualVersion else {
                throw LibraryRepositoryError.staleWriter(
                    expected: expectedVersion,
                    actual: actualVersion
                )
            }

            let capability = LibraryMutationCommitCapability(
                applications: applications,
                versionToken: actualVersion,
                priorBytes: priorBytes,
                persistence: documentPersistence,
                backupHook: backupHook
            )
            defer { capability.invalidate() }
            return try body(capability)
        }
    }
}

enum LibraryAdvisoryLockError: LocalizedError {
    case timedOut(url: URL, timeout: TimeInterval)
    case nestedAcquisition
    case unavailable(any Error)

    var errorDescription: String? {
        switch self {
        case .nestedAcquisition:
            String(localized: "This operation already holds the library lock. Reuse its exclusive-access capability instead of starting another mutation.")
        case .unavailable(let error):
            String(localized: "The library is open read-only because its lock is unavailable. Recovery and changes are paused: \(error.localizedDescription)")
        case let .timedOut(url, timeout):
            String(
                localized: "The Parallax library is busy in another process. Wait for that operation to finish and retry (lock \(url.lastPathComponent), timeout \(timeout.formatted()) seconds)."
            )
        }
    }
}

struct LibraryAdvisoryLock: Sendable {
    let url: URL
    let timeout: TimeInterval
    let pollInterval: TimeInterval

    init(
        url: URL,
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.01
    ) {
        precondition(timeout.isFinite && timeout >= 0)
        precondition(pollInterval.isFinite && pollInterval > 0)
        self.url = url
        self.timeout = timeout
        self.pollInterval = pollInterval
    }

    func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        switch try withLock(wait: true, body) {
        case .acquired(let value):
            return value
        case .busy:
            throw LibraryAdvisoryLockError.timedOut(url: url, timeout: timeout)
        }
    }

    func tryWithExclusiveLock<T>(
        _ body: () throws -> T
    ) throws -> LibraryExclusiveAccessResult<T> {
        try withLock(wait: false, body)
    }

    private func withLock<T>(
        wait: Bool,
        _ body: () throws -> T
    ) throws -> LibraryExclusiveAccessResult<T> {
        let threadKey = "Parallax.library-lock."
            + url.standardizedFileURL.resolvingSymlinksInPath().path
        if wait, Thread.current.threadDictionary[threadKey] != nil {
            throw LibraryAdvisoryLockError.nestedAcquisition
        }
        let descriptor = open(
            url.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw LibraryAdvisoryLockError.unavailable(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let savedErrno = errno
            close(descriptor)
            throw LibraryAdvisoryLockError.unavailable(POSIXError(POSIXErrorCode(rawValue: savedErrno) ?? .EIO))
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        let started = DispatchTime.now().uptimeNanoseconds
        let timeoutNanoseconds = UInt64(
            min(timeout * 1_000_000_000, Double(UInt64.max))
        )
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR {
                continue
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN else {
                throw LibraryAdvisoryLockError.unavailable(POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
            }
            guard wait else { return .busy }
            let elapsed = DispatchTime.now().uptimeNanoseconds - started
            guard elapsed < timeoutNanoseconds else {
                throw LibraryAdvisoryLockError.timedOut(
                    url: url,
                    timeout: timeout
                )
            }
            usleep(useconds_t(min(pollInterval * 1_000_000, 50_000)))
        }
        Thread.current.threadDictionary[threadKey] = true
        defer { Thread.current.threadDictionary.removeObject(forKey: threadKey) }
        return .acquired(try body())
    }
}
