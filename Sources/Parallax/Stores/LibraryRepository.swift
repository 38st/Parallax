import Foundation
import Darwin

struct LibraryVersionToken: Hashable, Sendable {
    static let missing = LibraryVersionToken(
        revision: .initial,
        primarySHA256: nil
    )

    let revision: LibraryRevision
    let primarySHA256: String?
}

struct LibraryRepositorySnapshot: Hashable, Sendable {
    let applications: [ManagedApplication]
    let versionToken: LibraryVersionToken
    let originalBytes: Data

    var revision: LibraryRevision {
        versionToken.revision
    }

    var sourceSHA256: String {
        versionToken.primarySHA256 ?? ""
    }
}

struct PreparedLibraryCommit: Hashable, Sendable {
    let priorVersion: LibraryVersionToken
    let targetVersion: LibraryVersionToken
    let targetBytes: Data
    let applications: [ManagedApplication]
}

enum LibraryCommitPrimaryState: String, Sendable, Equatable {
    case prior
    case target
    case neither
}

struct LibraryPreparedCommitResult: Hashable, Sendable {
    let primaryState: LibraryCommitPrimaryState
    let snapshot: LibraryRepositorySnapshot
}

enum LibraryRepositoryLoadOutcome: Sendable {
    case missing
    case loaded(LibraryRepositorySnapshot)
    case migrationRequired(LegacyLibrarySnapshot)
    case recoveryRequired(LibraryPersistenceFailure)
    case readOnly(LibraryPersistenceFailure)
}

enum LibraryRepositoryError: LocalizedError {
    case staleWriter(expected: LibraryVersionToken, actual: LibraryVersionToken)
    case libraryUnavailable(LibraryPersistenceFailure)
    case migrationRequired(LegacyLibrary.Format)
    case revisionOverflow
    case mutationAlreadyPublished
    case mutationSessionExpired
    case preparedVersionMismatch
    case backupUnavailable
    case invalidExclusiveAccess
    case commitFailed(
        state: LibraryCommitPrimaryState,
        failure: LibraryPersistenceFailure
    )

    var errorDescription: String? {
        switch self {
        case let .staleWriter(expected, actual):
            String(
                localized: "The library changed in another Parallax process (expected revision \(expected.revision.rawValue, specifier: "%llu"), found \(actual.revision.rawValue, specifier: "%llu")). Reload before saving."
            )
        case let .libraryUnavailable(failure):
            String(
                localized: "The library is not writable until its load problem is resolved: \(failure.error.localizedDescription)"
            )
        case .migrationRequired:
            String(localized: "The legacy library must finish migration before it can be edited.")
        case .revisionOverflow:
            String(localized: "The library revision cannot be advanced. Preserve the library and contact support.")
        case .mutationAlreadyPublished:
            String(localized: "A library mutation session can publish metadata only once.")
        case .mutationSessionExpired:
            String(localized: "The library mutation session has ended. Start a new operation and revalidate the library before committing.")
        case .preparedVersionMismatch:
            String(localized: "The prepared library update does not belong to the currently locked library version.")
        case .invalidExclusiveAccess:
            String(localized: "The library lock capability has expired or belongs to another library. Start a new operation.")
        case .backupUnavailable:
            String(localized: "This library update requires a backup, but no backup service is configured.")
        case let .commitFailed(state, failure):
            switch state {
            case .prior:
                String(
                    localized: "The library update was not committed and the prior library remains active: \(failure.error.localizedDescription)"
                )
            case .target:
                String(
                    localized: "The target library is active, but commit verification reported an error: \(failure.error.localizedDescription)"
                )
            case .neither:
                String(
                    localized: "The library no longer matches either the prior or prepared version. Stop editing and recover the library: \(failure.error.localizedDescription)"
                )
            }
        }
    }
}

typealias LibraryBackupHook = @Sendable (
    _ priorBytes: Data,
    _ reason: LibraryBackupReason
) throws -> Void

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

typealias LibraryMutationSession = LibraryMutationCommitCapability

enum LibraryExclusiveAccessResult<Value> {
    case acquired(Value)
    case busy
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

protocol LibraryRepositoryPersisting: Sendable {
    var persistence: any LibraryRepositoryPersistence { get }

    /// Tries the library's interprocess lock once, without waiting. The body
    /// may inspect/recover missing, legacy, or current libraries. It must not
    /// acquire this lock again (including via save or withExclusiveMutation).
    /// Errors from the body propagate unchanged; busy never runs the body.
    func tryWithExclusiveAccess<T>(
        _ body: (LibraryExclusiveAccess) throws -> T
    ) throws -> LibraryExclusiveAccessResult<T>

    func load() -> LibraryRepositoryLoadOutcome

    func prepare(
        _ applications: [ManagedApplication],
        expectedVersion: LibraryVersionToken
    ) throws -> PreparedLibraryCommit

    func withExclusiveMutation<T>(
        expectedVersion: LibraryVersionToken,
        _ body: (LibraryMutationCommitCapability) throws -> T
    ) throws -> T

    @discardableResult
    func save(
        _ applications: [ManagedApplication],
        expectedVersion: LibraryVersionToken,
        backupReason: LibraryBackupReason?
    ) throws -> LibraryRepositorySnapshot
}

extension LibraryRepositoryPersisting {
    func tryWithExclusiveAccess<T>(
        _ body: () throws -> T
    ) throws -> LibraryExclusiveAccessResult<T> {
        try tryWithExclusiveAccess { _ in try body() }
    }

    @discardableResult
    func save(
        _ applications: [ManagedApplication],
        expectedVersion: LibraryVersionToken
    ) throws -> LibraryRepositorySnapshot {
        try save(
            applications,
            expectedVersion: expectedVersion,
            backupReason: nil
        )
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
