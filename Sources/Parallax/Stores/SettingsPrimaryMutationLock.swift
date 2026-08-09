import Darwin
import Foundation

enum SettingsPrimaryMutationLockItem: Sendable, Equatable {
    case trustedContainer
    case settingsDirectory
    case lock
}

enum SettingsPrimaryMutationLockUnsafeReason: Sendable, Equatable {
    case symbolicLink
    case wrongOwner
    case incorrectMode(expected: UInt16, actual: UInt16)
    case extendedACL
    case unsupportedType
    case multipleHardLinks
}

struct SettingsPrimaryMutationLockSystemFailure: Error, Sendable, Equatable {
    let operation: String
    let code: Int32
}

enum SettingsPrimaryMutationLockError: Error, Sendable, Equatable {
    case missingTrustedContainer
    case unsafeItem(
        item: SettingsPrimaryMutationLockItem,
        reason: SettingsPrimaryMutationLockUnsafeReason
    )
    case changedDuringAcquisition(item: SettingsPrimaryMutationLockItem)
    case timedOut(timeout: TimeInterval)
    case systemCall(SettingsPrimaryMutationLockSystemFailure)
}

struct SettingsPrimaryMutationLockCleanupError: Error, Sendable, Equatable {
    let failures: [SettingsPrimaryMutationLockSystemFailure]
}

struct SettingsPrimaryMutationLockPrimaryAndCleanupError:
    Error,
    @unchecked Sendable
{
    let primary: any Error
    let cleanup: SettingsPrimaryMutationLockCleanupError
}

enum SettingsPrimaryLockedInspectionError: Error, Sendable, Equatable {
    case expiredAuthority
    case reentrantAuthorityOperation
    case lockValidation(SettingsPrimaryMutationLockError)
    case fileAccess(SettingsPrimaryFileAccessError)
    case authorityContainerClose(SettingsPrimaryMutationLockSystemFailure)
    case lockValidationAndAuthorityContainerClose(
        validation: SettingsPrimaryMutationLockError,
        close: SettingsPrimaryMutationLockSystemFailure
    )
}

struct SettingsPrimaryLockedInspectionAuthority: @unchecked Sendable {
    fileprivate let lease: SettingsPrimaryLockedInspectionLease

    func readPrimary() -> Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    > {
        lease.readPrimary()
    }
}

fileprivate final class SettingsPrimaryLockedInspectionLease:
    @unchecked Sendable
{
    typealias Operation = @Sendable () -> Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    >

    private let lock = NSLock()
    private var active = true
    private var inFlight = false
    private let operation: Operation
    private let ownerThread: pthread_t

    init(operation: @escaping Operation) {
        self.operation = operation
        ownerThread = pthread_self()
    }

    func readPrimary() -> Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    > {
        lock.lock()
        guard active,
              pthread_equal(pthread_self(), ownerThread) != 0
        else {
            lock.unlock()
            return .failure(.expiredAuthority)
        }
        guard !inFlight else {
            lock.unlock()
            return .failure(.reentrantAuthorityOperation)
        }
        inFlight = true
        lock.unlock()

        let result = operation()
        lock.withLock {
            inFlight = false
        }
        return result
    }

    func invalidate() {
        lock.withLock {
            active = false
        }
    }
}

enum SettingsPrimaryMutationLockBoundary: Sendable, Equatable {
    case afterContainerOpen
    case afterSettingsPreflight
    case afterSettingsCreatedIdentity
    case beforeSettingsPublish
    case afterSettingsPublish
    case afterSettingsOpen
    case afterLockPreflight
    case afterLockOpen
    case beforeFlock
    case afterFlock
}

enum SettingsPrimaryMutationLockSystemCall: Sendable, Equatable {
    case openContainer
    case inspectContainer
    case inspectSettingsPath
    case createSettings
    case inspectCreatedSettingsPath
    case openSettings
    case inspectSettings
    case setSettingsMode
    case reinspectSettings
    case reinspectSettingsPath
    case publishSettings
    case inspectPublishedSettingsPath
    case syncContainer
    case inspectLockPath
    case createLock
    case reopenLock
    case inspectLock
    case setLockMode
    case reinspectLock
    case reinspectLockPath
    case syncSettings
    case flock
    case reopenContainer
    case inspectReopenedContainer
    case reinspectPinnedContainer
    case reinspectPinnedSettings
    case reinspectSettingsPathAfterLock
    case reinspectPinnedLock
    case reinspectLockPathAfterLock
    case closeAuthorityContainer
    case unlock
    case closeLock
    case closeReopenedContainer
    case closeSettings
    case closeContainer
}

struct SettingsPrimaryMutationLock: @unchecked Sendable {
    typealias BoundaryHook =
        @Sendable (SettingsPrimaryMutationLockBoundary) -> Void
    typealias ACLHook = @Sendable (
        SettingsPrimaryMutationLockItem,
        Int32
    ) -> SettingsPrimaryACLDirective
    typealias SystemCallHook =
        @Sendable (SettingsPrimaryMutationLockSystemCall) -> Int32?
    typealias MonotonicNow = @Sendable () -> UInt64
    typealias Sleeper = @Sendable (UInt64) -> Void
    typealias StagingNameSource = @Sendable () -> UInt64

    static let settingsName = "Settings"
    static let lockName = ".settings.lock"
    static let settingsStagingPrefix = ".Settings.create-"
    static let settingsStagingAttemptLimit = 8
    static let defaultMaximumConsecutiveFlockNoProgress = 256
    static let maximumConsecutiveInterruptedStatusCalls = 64

    private let trustedContainerURL: URL
    private let timeout: TimeInterval
    private let pollIntervalNanoseconds: UInt64
    private let maximumConsecutiveFlockNoProgress: Int
    private let boundaryHook: BoundaryHook
    private let aclHook: ACLHook
    private let systemCallHook: SystemCallHook
    private let monotonicNow: MonotonicNow
    private let sleeper: Sleeper
    private let stagingNameSource: StagingNameSource
    private let lockedInspectionReader: SettingsPrimaryFileAccess

    init(
        trustedContainerURL: URL,
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.01,
        maximumConsecutiveFlockNoProgress: Int =
            Self.defaultMaximumConsecutiveFlockNoProgress,
        boundaryHook: @escaping BoundaryHook = { _ in },
        aclHook: @escaping ACLHook = { _, _ in .system },
        systemCallHook: @escaping SystemCallHook = { _ in nil },
        monotonicNow: @escaping MonotonicNow = {
            DispatchTime.now().uptimeNanoseconds
        },
        sleeper: @escaping Sleeper = { nanoseconds in
            let microseconds = min(
                nanoseconds / 1_000,
                UInt64(useconds_t.max)
            )
            usleep(useconds_t(microseconds))
        },
        stagingNameSource: @escaping StagingNameSource = {
            UInt64.random(in: UInt64.min ... UInt64.max)
        },
        inspectionReadChunkBytes: Int = 64 * 1_024,
        inspectionMaximumConsecutiveInterruptedReads: Int =
            SettingsPrimaryFileAccess
                .defaultMaximumConsecutiveInterruptedReads,
        inspectionBoundaryHook:
            @escaping SettingsPrimaryFileAccess.BoundaryHook = { _ in },
        inspectionReadHook:
            @escaping SettingsPrimaryFileAccess.ReadHook = { _, _ in .system },
        inspectionMetadataHook:
            @escaping SettingsPrimaryFileAccess.MetadataHook = {
                _, metadata in metadata
            },
        inspectionACLHook:
            @escaping SettingsPrimaryFileAccess.ACLHook = {
                _, _ in .system
            },
        inspectionSystemCallHook:
            @escaping SettingsPrimaryFileAccess.SystemCallHook = {
                _ in nil
            }
    ) {
        precondition(trustedContainerURL.isFileURL)
        precondition(trustedContainerURL.path.hasPrefix("/"))
        precondition(timeout.isFinite && timeout >= 0 && timeout <= 2)
        precondition(
            pollInterval.isFinite
                && pollInterval > 0
                && pollInterval <= 0.05
        )
        precondition(maximumConsecutiveFlockNoProgress >= 0)
        precondition(
            inspectionMaximumConsecutiveInterruptedReads >= 0
        )
        self.trustedContainerURL = trustedContainerURL
        self.timeout = timeout
        pollIntervalNanoseconds = UInt64(pollInterval * 1_000_000_000)
        self.maximumConsecutiveFlockNoProgress =
            maximumConsecutiveFlockNoProgress
        self.boundaryHook = boundaryHook
        self.aclHook = aclHook
        self.systemCallHook = systemCallHook
        self.monotonicNow = monotonicNow
        self.sleeper = sleeper
        self.stagingNameSource = stagingNameSource
        lockedInspectionReader = SettingsPrimaryFileAccess(
            pinnedReadChunkBytes: inspectionReadChunkBytes,
            maximumConsecutiveInterruptedReads:
                inspectionMaximumConsecutiveInterruptedReads,
            boundaryHook: inspectionBoundaryHook,
            readHook: inspectionReadHook,
            metadataHook: inspectionMetadataHook,
            aclHook: inspectionACLHook,
            systemCallHook: inspectionSystemCallHook
        )
    }

    func withLock<T>(
        _ body: () throws -> T
    ) throws -> T {
        try withAcquiredLock { _ in
            try body()
        }
    }

    func withLock<T>(
        _ body: (SettingsPrimaryLockedInspectionAuthority) throws -> T
    ) throws -> T {
        try withAcquiredLock(body)
    }

    private func withAcquiredLock<T>(
        _ body: (SettingsPrimaryLockedInspectionAuthority) throws -> T
    ) throws -> T {
        let resources = Resources()
        do {
            try acquire(resources)
        } catch {
            let cleanup = cleanup(resources)
            if cleanup.failures.isEmpty {
                throw error
            }
            throw SettingsPrimaryMutationLockPrimaryAndCleanupError(
                primary: error,
                cleanup: cleanup
            )
        }

        let lease = SettingsPrimaryLockedInspectionLease {
            readPrimary(resources)
        }
        let authority = SettingsPrimaryLockedInspectionAuthority(
            lease: lease
        )
        let result: Result<T, Error>
        do {
            result = .success(try body(authority))
        } catch {
            result = .failure(error)
        }
        lease.invalidate()
        let cleanup = cleanup(resources)
        switch result {
        case .success(let value):
            guard cleanup.failures.isEmpty else {
                throw cleanup
            }
            return value
        case .failure(let error):
            guard cleanup.failures.isEmpty else {
                throw SettingsPrimaryMutationLockPrimaryAndCleanupError(
                    primary: error,
                    cleanup: cleanup
                )
            }
            throw error
        }
    }

    private func acquire(
        _ resources: Resources
    ) throws {
        let container = try openContainer(call: .openContainer)
        resources.container = container
        let containerBefore = try descriptorMetadata(
            container,
            call: .inspectContainer,
            operation: "inspect trusted settings container"
        )
        try validateDirectory(
            containerBefore,
            item: .trustedContainer,
            exactMode: 0o700
        )
        try validateACL(
            container,
            item: .trustedContainer,
            operation: "inspect trusted settings container ACL"
        )
        resources.containerIdentity = containerBefore
        boundaryHook(.afterContainerOpen)

        try openOrCreateSettings(resources)
        try refreshContainerIdentity(resources)
        try openOrCreateLock(resources)
        try refreshSettingsIdentity(resources)

        boundaryHook(.beforeFlock)
        resources.lockAttempted = true
        try acquireFlock(resources.lock)
        resources.locked = true
        boundaryHook(.afterFlock)

        try revalidateAfterFlock(resources)
    }

    private func openOrCreateSettings(
        _ resources: Resources
    ) throws {
        let preflight = pathMetadata(
            parent: resources.container,
            name: Self.settingsName,
            call: .inspectSettingsPath
        )
        let expectedBefore: SettingsPrimaryFileMetadata?
        switch preflight {
        case .metadata(let metadata):
            try validateDirectory(
                metadata,
                item: .settingsDirectory,
                exactMode: 0o700
            )
            expectedBefore = metadata
        case .failure(let code):
            guard code == ENOENT else {
                throw system(
                    "inspect Settings directory path",
                    code
                )
            }
            expectedBefore = nil
        }
        boundaryHook(.afterSettingsPreflight)

        if let expectedBefore {
            let settings = try openSettings(
                parent: resources.container,
                name: Self.settingsName
            )
            resources.settings = settings
            let opened = try descriptorMetadata(
                settings,
                call: .inspectSettings,
                operation: "inspect opened Settings directory"
            )
            try validateDirectory(
                opened,
                item: .settingsDirectory,
                exactMode: 0o700
            )
            guard opened == expectedBefore else {
                throw changed(.settingsDirectory)
            }
            try finishSettingsValidation(
                resources,
                pathName: Self.settingsName
            )
        } else {
            try createAndPublishSettings(resources)
        }
        boundaryHook(.afterSettingsOpen)
    }

    private func createAndPublishSettings(
        _ resources: Resources
    ) throws {
        var stagingName: String?
        for _ in 0 ..< Self.settingsStagingAttemptLimit {
            let candidate = Self.settingsStagingPrefix
                + String(stagingNameSource(), radix: 16)
            let result: Int32
            let code: Int32
            if let injected = systemCallHook(.createSettings) {
                result = -1
                code = injected
            } else {
                result = mkdirat(resources.container, candidate, 0o700)
                code = result == 0 ? 0 : errno
            }
            if result == 0 {
                stagingName = candidate
                break
            }
            guard code == EEXIST else {
                throw system("create staging Settings directory", code)
            }
        }
        guard let stagingName else {
            throw system(
                "exhaust staging Settings directory names",
                EEXIST
            )
        }

        let settings = tryOpenSettings(
            parent: resources.container,
            name: stagingName
        )
        guard settings.descriptor >= 0 else {
            if settings.errorCode == ELOOP {
                throw unsafe(.settingsDirectory, .symbolicLink)
            }
            if settings.errorCode == ENOTDIR {
                throw unsafe(.settingsDirectory, .unsupportedType)
            }
            throw system(
                "open staging Settings directory \(stagingName)",
                settings.errorCode
            )
        }
        resources.settings = settings.descriptor

        let created = try descriptorMetadata(
            settings.descriptor,
            call: .inspectSettings,
            operation: "inspect staging Settings directory"
        )
        guard created.kind == .directory,
              created.owner == geteuid()
        else {
            throw changed(.settingsDirectory)
        }
        let createdPath = try requiredPathMetadata(
            parent: resources.container,
            name: stagingName,
            call: .inspectCreatedSettingsPath,
            operation: "inspect staging Settings directory path"
        )
        guard sameIdentity(created, createdPath) else {
            throw changed(.settingsDirectory)
        }
        boundaryHook(.afterSettingsCreatedIdentity)

        try callStatus(
            .setSettingsMode,
            operation: "set staging Settings directory mode"
        ) {
            fchmod(settings.descriptor, 0o700)
        }

        let final = try descriptorMetadata(
            settings.descriptor,
            call: .reinspectSettings,
            operation: "reinspect staging Settings directory"
        )
        try validateDirectory(
            final,
            item: .settingsDirectory,
            exactMode: 0o700
        )
        try validateACL(
            settings.descriptor,
            item: .settingsDirectory,
            operation: "inspect staging Settings directory ACL"
        )
        let stagingPath = try requiredPathMetadata(
            parent: resources.container,
            name: stagingName,
            call: .reinspectSettingsPath,
            operation: "reinspect staging Settings directory path"
        )
        guard final == stagingPath else {
            throw changed(.settingsDirectory)
        }
        resources.settingsIdentity = final
        boundaryHook(.beforeSettingsPublish)

        try callStatus(
            .publishSettings,
            operation: "publish Settings directory"
        ) {
            renameatx_np(
                resources.container,
                stagingName,
                resources.container,
                Self.settingsName,
                UInt32(RENAME_EXCL)
            )
        }
        boundaryHook(.afterSettingsPublish)

        let publishedDescriptor = try descriptorMetadata(
            settings.descriptor,
            call: .reinspectSettings,
            operation: "verify published Settings directory descriptor"
        )
        try validateDirectory(
            publishedDescriptor,
            item: .settingsDirectory,
            exactMode: 0o700
        )
        let published = try requiredPathMetadata(
            parent: resources.container,
            name: Self.settingsName,
            call: .inspectPublishedSettingsPath,
            operation: "verify published Settings directory path"
        )
        guard publishedDescriptor == published else {
            throw changed(.settingsDirectory)
        }
        resources.settingsIdentity = publishedDescriptor
        try fullSync(
            resources.container,
            call: .syncContainer,
            operation: "synchronize trusted settings container"
        )
    }

    private func finishSettingsValidation(
        _ resources: Resources,
        pathName: String
    ) throws {
        let final = try descriptorMetadata(
            resources.settings,
            call: .reinspectSettings,
            operation: "reinspect Settings directory"
        )
        try validateDirectory(
            final,
            item: .settingsDirectory,
            exactMode: 0o700
        )
        try validateACL(
            resources.settings,
            item: .settingsDirectory,
            operation: "inspect Settings directory ACL"
        )
        let finalPath = try requiredPathMetadata(
            parent: resources.container,
            name: pathName,
            call: .reinspectSettingsPath,
            operation: "reinspect Settings directory path"
        )
        guard final == finalPath else {
            throw changed(.settingsDirectory)
        }
        resources.settingsIdentity = final
    }

    private func openOrCreateLock(
        _ resources: Resources
    ) throws {
        let preflight = pathMetadata(
            parent: resources.settings,
            name: Self.lockName,
            call: .inspectLockPath
        )
        var existing: SettingsPrimaryFileMetadata?
        switch preflight {
        case .metadata(let metadata):
            try validateLock(metadata)
            existing = metadata
        case .failure(let code):
            guard code == ENOENT else {
                throw system("inspect settings lock path", code)
            }
        }
        boundaryHook(.afterLockPreflight)

        var lock: Int32
        if existing == nil {
            let created = createLock(parent: resources.settings)
            if created.descriptor >= 0 {
                lock = created.descriptor
                resources.lockCreated = true
            } else if created.errorCode == EEXIST {
                let raced = try requiredPathMetadata(
                    parent: resources.settings,
                    name: Self.lockName,
                    call: .inspectLockPath,
                    operation: "reinspect existing settings lock"
                )
                try validateLock(raced)
                existing = raced
                lock = try reopenLock(parent: resources.settings)
            } else {
                throw system("create settings lock", created.errorCode)
            }
        } else {
            lock = try reopenLock(parent: resources.settings)
        }
        resources.lock = lock

        let opened = try descriptorMetadata(
            lock,
            call: .inspectLock,
            operation: "inspect opened settings lock"
        )
        if resources.lockCreated {
            resources.lockIdentity = opened
            try callStatus(
                .setLockMode,
                operation: "set created settings lock mode"
            ) {
                fchmod(lock, 0o600)
            }
        } else {
            try validateLock(opened)
            guard opened == existing else {
                throw changed(.lock)
            }
        }

        let final = try descriptorMetadata(
            lock,
            call: .reinspectLock,
            operation: "reinspect settings lock"
        )
        try validateLock(final)
        try validateACL(
            lock,
            item: .lock,
            operation: "inspect settings lock ACL"
        )
        let path = try requiredPathMetadata(
            parent: resources.settings,
            name: Self.lockName,
            call: .reinspectLockPath,
            operation: "reinspect settings lock path"
        )
        guard final == path else {
            throw changed(.lock)
        }
        resources.lockIdentity = final
        boundaryHook(.afterLockOpen)

        if resources.lockCreated {
            try fullSync(
                resources.settings,
                call: .syncSettings,
                operation: "synchronize Settings directory"
            )
        }
    }

    private func refreshContainerIdentity(
        _ resources: Resources
    ) throws {
        let metadata = try descriptorMetadata(
            resources.container,
            call: .inspectContainer,
            operation: "refresh trusted settings container"
        )
        try validateDirectory(
            metadata,
            item: .trustedContainer,
            exactMode: 0o700
        )
        try validateACL(
            resources.container,
            item: .trustedContainer,
            operation: "refresh trusted settings container ACL"
        )
        resources.containerIdentity = metadata
    }

    private func refreshSettingsIdentity(
        _ resources: Resources
    ) throws {
        let metadata = try descriptorMetadata(
            resources.settings,
            call: .reinspectSettings,
            operation: "refresh Settings directory"
        )
        try validateDirectory(
            metadata,
            item: .settingsDirectory,
            exactMode: 0o700
        )
        try validateACL(
            resources.settings,
            item: .settingsDirectory,
            operation: "refresh Settings directory ACL"
        )
        let path = try requiredPathMetadata(
            parent: resources.container,
            name: Self.settingsName,
            call: .reinspectSettingsPath,
            operation: "refresh Settings directory path"
        )
        guard metadata == path else {
            throw changed(.settingsDirectory)
        }
        resources.settingsIdentity = metadata
    }

    private func revalidateAfterFlock(
        _ resources: Resources
    ) throws {
        let reopened = try openContainer(call: .reopenContainer)
        resources.reopenedContainer = reopened
        try validatePinnedState(resources, reopenedContainer: reopened)
    }

    private func validatePinnedState(
        _ resources: Resources,
        reopenedContainer: Int32
    ) throws {
        let reopenedMetadata = try descriptorMetadata(
            reopenedContainer,
            call: .inspectReopenedContainer,
            operation: "reinspect trusted settings container path"
        )
        try validateDirectory(
            reopenedMetadata,
            item: .trustedContainer,
            exactMode: 0o700
        )
        try validateACL(
            reopenedContainer,
            item: .trustedContainer,
            operation: "reinspect trusted settings container path ACL"
        )

        let pinnedContainer = try descriptorMetadata(
            resources.container,
            call: .reinspectPinnedContainer,
            operation: "reinspect pinned trusted settings container"
        )
        try validateACL(
            resources.container,
            item: .trustedContainer,
            operation: "reinspect pinned trusted settings container ACL"
        )
        guard reopenedMetadata == resources.containerIdentity,
              pinnedContainer == resources.containerIdentity
        else {
            throw changed(.trustedContainer)
        }

        let settings = try descriptorMetadata(
            resources.settings,
            call: .reinspectPinnedSettings,
            operation: "reinspect pinned Settings directory"
        )
        try validateDirectory(
            settings,
            item: .settingsDirectory,
            exactMode: 0o700
        )
        try validateACL(
            resources.settings,
            item: .settingsDirectory,
            operation: "reinspect pinned Settings directory ACL"
        )
        let settingsPath = try requiredPathMetadata(
            parent: resources.container,
            name: Self.settingsName,
            call: .reinspectSettingsPathAfterLock,
            operation: "reinspect Settings directory path after lock"
        )
        guard settings == resources.settingsIdentity,
              settingsPath == resources.settingsIdentity
        else {
            throw changed(.settingsDirectory)
        }

        let lock = try descriptorMetadata(
            resources.lock,
            call: .reinspectPinnedLock,
            operation: "reinspect pinned settings lock"
        )
        try validateLock(lock)
        try validateACL(
            resources.lock,
            item: .lock,
            operation: "reinspect settings lock ACL"
        )
        let lockPath = try requiredPathMetadata(
            parent: resources.settings,
            name: Self.lockName,
            call: .reinspectLockPathAfterLock,
            operation: "reinspect settings lock path after lock"
        )
        guard lock == resources.lockIdentity,
              lockPath == resources.lockIdentity
        else {
            throw changed(.lock)
        }
    }

    private func readPrimary(
        _ resources: Resources
    ) -> Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    > {
        do {
            let parentBefore = try revalidateAuthority(resources)
            let result = try lockedInspectionReader.readPinnedThrowing(
                parent: resources.settings,
                parentBefore: parentBefore,
                maximumBytes:
                    SettingsPrimaryFileAccess.maximumLockedInspectionBytes
            ) {
                _ = try revalidateAuthority(resources)
            }
            return .success(result)
        } catch let error as SettingsPrimaryLockedInspectionError {
            return .failure(error)
        } catch let error as SettingsPrimaryMutationLockError {
            return .failure(.lockValidation(error))
        } catch let error as SettingsPrimaryFileAccessError {
            return .failure(.fileAccess(error))
        } catch {
            return .failure(
                .lockValidation(
                    system(
                        "unexpected locked inspection validation",
                        EIO
                    )
                )
            )
        }
    }

    private func revalidateAuthority(
        _ resources: Resources
    ) throws -> SettingsPrimaryFileMetadata {
        let reopened = try openContainer(call: .reopenContainer)
        let validation: Result<
            SettingsPrimaryFileMetadata,
            SettingsPrimaryMutationLockError
        >
        do {
            try validatePinnedState(
                resources,
                reopenedContainer: reopened
            )
            guard let identity = resources.settingsIdentity else {
                throw changed(.settingsDirectory)
            }
            validation = .success(identity)
        } catch let error as SettingsPrimaryMutationLockError {
            validation = .failure(error)
        } catch {
            validation = .failure(
                system(
                    "unexpected locked inspection validation",
                    EIO
                )
            )
        }

        let closeFailure = closeAuthorityContainer(reopened)
        switch (validation, closeFailure) {
        case (.success(let identity), nil):
            return identity
        case (.success, .some(let close)):
            throw SettingsPrimaryLockedInspectionError
                .authorityContainerClose(close)
        case (.failure(let validation), nil):
            throw validation
        case (.failure(let validation), .some(let close)):
            throw SettingsPrimaryLockedInspectionError
                .lockValidationAndAuthorityContainerClose(
                    validation: validation,
                    close: close
                )
        }
    }

    private func closeAuthorityContainer(
        _ descriptor: Int32
    ) -> SettingsPrimaryMutationLockSystemFailure? {
        let injected = systemCallHook(.closeAuthorityContainer)
        let result = Darwin.close(descriptor)
        if let code = injected {
            return .init(
                operation: "close transient trusted settings container",
                code: code
            )
        }
        guard result != 0 else {
            return nil
        }
        return .init(
            operation: "close transient trusted settings container",
            code: errno
        )
    }

    private func acquireFlock(
        _ descriptor: Int32
    ) throws {
        let started = monotonicNow()
        let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
        var consecutiveNoProgress = 0
        while true {
            let status: Int32
            let code: Int32
            if let injected = systemCallHook(.flock) {
                status = -1
                code = injected
            } else {
                status = flock(descriptor, LOCK_EX | LOCK_NB)
                code = status == 0 ? 0 : errno
            }
            if status == 0 {
                return
            }
            guard code == EINTR
                    || code == EWOULDBLOCK
                    || code == EAGAIN
            else {
                throw system("acquire settings lock", code)
            }
            let (next, overflow) =
                consecutiveNoProgress.addingReportingOverflow(1)
            guard !overflow,
                  next <= maximumConsecutiveFlockNoProgress
            else {
                throw SettingsPrimaryMutationLockError.timedOut(
                    timeout: timeout
                )
            }
            consecutiveNoProgress = next
            let now = monotonicNow()
            let elapsed = now >= started ? now - started : UInt64.max
            guard elapsed < timeoutNanoseconds else {
                throw SettingsPrimaryMutationLockError.timedOut(
                    timeout: timeout
                )
            }
            sleeper(
                min(
                    pollIntervalNanoseconds,
                    timeoutNanoseconds - elapsed
                )
            )
        }
    }

    private func openContainer(
        call: SettingsPrimaryMutationLockSystemCall
    ) throws -> Int32 {
        if let code = systemCallHook(call) {
            if code == ENOENT {
                throw SettingsPrimaryMutationLockError
                    .missingTrustedContainer
            }
            throw system("open trusted settings container", code)
        }
        let descriptor = open(
            trustedContainerURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ENOENT {
                throw SettingsPrimaryMutationLockError
                    .missingTrustedContainer
            }
            if errno == ELOOP {
                throw unsafe(.trustedContainer, .symbolicLink)
            }
            if errno == ENOTDIR {
                throw unsafe(.trustedContainer, .unsupportedType)
            }
            throw system("open trusted settings container", errno)
        }
        return descriptor
    }

    private func openSettings(
        parent: Int32,
        name: String
    ) throws -> Int32 {
        let opened = tryOpenSettings(parent: parent, name: name)
        guard opened.descriptor >= 0 else {
            if opened.errorCode == ELOOP {
                throw unsafe(.settingsDirectory, .symbolicLink)
            }
            if opened.errorCode == ENOTDIR {
                throw unsafe(.settingsDirectory, .unsupportedType)
            }
            throw system("open Settings directory", opened.errorCode)
        }
        return opened.descriptor
    }

    private func tryOpenSettings(
        parent: Int32,
        name: String
    ) -> (descriptor: Int32, errorCode: Int32) {
        if let code = systemCallHook(.openSettings) {
            return (-1, code)
        }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        return (descriptor, descriptor < 0 ? errno : 0)
    }

    private func createLock(
        parent: Int32
    ) -> (descriptor: Int32, errorCode: Int32) {
        if let code = systemCallHook(.createLock) {
            return (-1, code)
        }
        let descriptor = openat(
            parent,
            Self.lockName,
            O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC,
            0o600
        )
        return (descriptor, descriptor < 0 ? errno : 0)
    }

    private func reopenLock(
        parent: Int32
    ) throws -> Int32 {
        if let code = systemCallHook(.reopenLock) {
            if code == ELOOP {
                throw unsafe(.lock, .symbolicLink)
            }
            throw system("open existing settings lock", code)
        }
        let descriptor = openat(
            parent,
            Self.lockName,
            O_RDWR | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC | O_UNIQUE
        )
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw unsafe(.lock, .symbolicLink)
            }
            throw system("open existing settings lock", errno)
        }
        return descriptor
    }

    private func descriptorMetadata(
        _ descriptor: Int32,
        call: SettingsPrimaryMutationLockSystemCall,
        operation: String
    ) throws -> SettingsPrimaryFileMetadata {
        if let code = systemCallHook(call) {
            throw system(operation, code)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw system(operation, errno)
        }
        return SettingsPrimaryDescriptorSecurity.metadata(from: status)
    }

    private func requiredPathMetadata(
        parent: Int32,
        name: String,
        call: SettingsPrimaryMutationLockSystemCall,
        operation: String
    ) throws -> SettingsPrimaryFileMetadata {
        switch pathMetadata(parent: parent, name: name, call: call) {
        case .metadata(let metadata):
            return metadata
        case .failure(let code):
            throw system(operation, code)
        }
    }

    private func pathMetadata(
        parent: Int32,
        name: String,
        call: SettingsPrimaryMutationLockSystemCall
    ) -> PathMetadataResult {
        if let code = systemCallHook(call) {
            return .failure(code)
        }
        var status = stat()
        let result = fstatat(
            parent,
            name,
            &status,
            AT_SYMLINK_NOFOLLOW
        )
        guard result == 0 else {
            return .failure(errno)
        }
        return .metadata(
            SettingsPrimaryDescriptorSecurity.metadata(from: status)
        )
    }

    private func validateDirectory(
        _ metadata: SettingsPrimaryFileMetadata,
        item: SettingsPrimaryMutationLockItem,
        exactMode: UInt16
    ) throws {
        if metadata.kind == .symbolicLink {
            throw unsafe(item, .symbolicLink)
        }
        guard metadata.kind == .directory else {
            throw unsafe(item, .unsupportedType)
        }
        try validateAuthority(
            metadata,
            item: item,
            exactMode: exactMode
        )
    }

    private func validateLock(
        _ metadata: SettingsPrimaryFileMetadata
    ) throws {
        if metadata.kind == .symbolicLink {
            throw unsafe(.lock, .symbolicLink)
        }
        guard metadata.kind == .regularFile else {
            throw unsafe(.lock, .unsupportedType)
        }
        guard metadata.linkCount == 1 else {
            throw unsafe(.lock, .multipleHardLinks)
        }
        try validateAuthority(
            metadata,
            item: .lock,
            exactMode: 0o600
        )
    }

    private func validateAuthority(
        _ metadata: SettingsPrimaryFileMetadata,
        item: SettingsPrimaryMutationLockItem,
        exactMode: UInt16
    ) throws {
        if let reason =
            SettingsPrimaryDescriptorSecurity.ownershipAndModeReason(metadata)
        {
            switch reason {
            case .wrongOwner:
                throw unsafe(item, .wrongOwner)
            case .permissiveMode:
                throw unsafe(
                    item,
                    .incorrectMode(
                        expected: exactMode,
                        actual: metadata.mode
                    )
                )
            case .specialMode:
                throw unsafe(
                    item,
                    .incorrectMode(
                        expected: exactMode,
                        actual: metadata.mode
                    )
                )
            default:
                throw unsafe(item, .unsupportedType)
            }
        }
        guard metadata.mode == exactMode else {
            throw unsafe(
                item,
                .incorrectMode(
                    expected: exactMode,
                    actual: metadata.mode
                )
            )
        }
    }

    private func validateACL(
        _ descriptor: Int32,
        item: SettingsPrimaryMutationLockItem,
        operation: String
    ) throws {
        let directive = aclHook(item, descriptor)
        let result: SettingsPrimaryDescriptorACLResult
        switch directive {
        case .system:
            result = SettingsPrimaryDescriptorSecurity.extendedACL(
                descriptor: descriptor
            )
        case .absent:
            result = .absent
        case .present:
            result = .present
        case .failure(let code):
            result = .failure(code: code)
        }
        switch result {
        case .absent:
            return
        case .present:
            throw unsafe(item, .extendedACL)
        case .failure(let code):
            throw system(operation, code)
        }
    }

    private func callStatus(
        _ call: SettingsPrimaryMutationLockSystemCall,
        operation: String,
        _ body: () -> Int32
    ) throws {
        var consecutiveInterruptions = 0
        while true {
            let result: Int32
            let code: Int32
            if let injected = systemCallHook(call) {
                result = -1
                code = injected
            } else {
                result = body()
                code = result == 0 ? 0 : errno
            }
            if result == 0 {
                return
            }
            guard code == EINTR else {
                throw system(operation, code)
            }
            consecutiveInterruptions += 1
            guard consecutiveInterruptions
                    <= Self.maximumConsecutiveInterruptedStatusCalls
            else {
                throw system(operation, EINTR)
            }
        }
    }

    private func fullSync(
        _ descriptor: Int32,
        call: SettingsPrimaryMutationLockSystemCall,
        operation: String
    ) throws {
        try callStatus(call, operation: operation) {
            fcntl(descriptor, F_FULLFSYNC)
        }
    }

    private func cleanup(
        _ resources: Resources
    ) -> SettingsPrimaryMutationLockCleanupError {
        // Preserve every created filesystem object after acquisition failure.
        // Darwin has no conditional unlink-by-validated-descriptor primitive;
        // unlinking a validated name could delete a swapped replacement.
        var failures: [SettingsPrimaryMutationLockSystemFailure] = []

        if resources.locked {
            let injected = systemCallHook(.unlock)
            let result = flock(resources.lock, LOCK_UN)
            if let code = injected {
                failures.append(
                    .init(operation: "unlock settings lock", code: code)
                )
            } else if result != 0 {
                failures.append(
                    .init(operation: "unlock settings lock", code: errno)
                )
            }
            resources.locked = false
        }

        close(
            &resources.lock,
            call: .closeLock,
            operation: "close settings lock",
            failures: &failures
        )
        close(
            &resources.reopenedContainer,
            call: .closeReopenedContainer,
            operation: "close revalidated trusted settings container",
            failures: &failures
        )
        close(
            &resources.settings,
            call: .closeSettings,
            operation: "close Settings directory",
            failures: &failures
        )
        close(
            &resources.container,
            call: .closeContainer,
            operation: "close trusted settings container",
            failures: &failures
        )
        return SettingsPrimaryMutationLockCleanupError(
            failures: failures
        )
    }

    private func close(
        _ descriptor: inout Int32,
        call: SettingsPrimaryMutationLockSystemCall,
        operation: String,
        failures: inout [SettingsPrimaryMutationLockSystemFailure]
    ) {
        guard descriptor >= 0 else { return }
        let value = descriptor
        descriptor = -1
        let injected = systemCallHook(call)
        let result = Darwin.close(value)
        if let code = injected {
            failures.append(.init(operation: operation, code: code))
        } else if result != 0 {
            failures.append(.init(operation: operation, code: errno))
        }
    }

    private func sameIdentity(
        _ lhs: SettingsPrimaryFileMetadata?,
        _ rhs: SettingsPrimaryFileMetadata?
    ) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs.device == rhs.device && lhs.inode == rhs.inode
    }

    private func unsafe(
        _ item: SettingsPrimaryMutationLockItem,
        _ reason: SettingsPrimaryMutationLockUnsafeReason
    ) -> SettingsPrimaryMutationLockError {
        .unsafeItem(item: item, reason: reason)
    }

    private func changed(
        _ item: SettingsPrimaryMutationLockItem
    ) -> SettingsPrimaryMutationLockError {
        .changedDuringAcquisition(item: item)
    }

    private func system(
        _ operation: String,
        _ code: Int32
    ) -> SettingsPrimaryMutationLockError {
        .systemCall(
            SettingsPrimaryMutationLockSystemFailure(
                operation: operation,
                code: code
            )
        )
    }
}

private final class Resources: @unchecked Sendable {
    var container: Int32 = -1
    var settings: Int32 = -1
    var lock: Int32 = -1
    var reopenedContainer: Int32 = -1
    var containerIdentity: SettingsPrimaryFileMetadata?
    var settingsIdentity: SettingsPrimaryFileMetadata?
    var lockIdentity: SettingsPrimaryFileMetadata?
    var lockCreated = false
    var lockAttempted = false
    var locked = false
}

private enum PathMetadataResult {
    case metadata(SettingsPrimaryFileMetadata)
    case failure(Int32)
}
