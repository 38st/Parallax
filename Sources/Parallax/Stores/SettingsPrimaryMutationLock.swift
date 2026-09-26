import Darwin
import Foundation

struct SettingsPrimaryMutationLock: Sendable {
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

    let trustedContainerURL: URL
    let timeout: TimeInterval
    let pollIntervalNanoseconds: UInt64
    let maximumConsecutiveFlockNoProgress: Int
    let boundaryHook: BoundaryHook
    let aclHook: ACLHook
    let systemCallHook: SystemCallHook
    let monotonicNow: MonotonicNow
    let sleeper: Sleeper
    let stagingNameSource: StagingNameSource
    let lockedInspectionReader: SettingsPrimaryFileAccess
    private let primaryPublication: SettingsPrimaryPublication
    let publicationResidualInventory:
        SettingsPublicationResidualInventory

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
            },
        publicationSystemCallHook:
            @escaping SettingsPrimaryPublication.SystemCallHook = {
                _ in nil
            },
        publicationWriteHook:
            @escaping SettingsPrimaryPublication.WriteHook = {
                _, _, _ in .system
            },
        publicationACLHook:
            @escaping SettingsPrimaryPublication.ACLHook = {
                _ in .system
            },
        publicationBoundaryHook:
            @escaping SettingsPrimaryPublication.BoundaryHook = {
                _ in
            },
        publicationNameSource:
            @escaping SettingsPrimaryPublication.NameSource = {
                UInt64.random(in: UInt64.min ... UInt64.max)
            },
        publicationResidualInventory:
            SettingsPublicationResidualInventory = .init()
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
        if let parent = realpath(trustedContainerURL.deletingLastPathComponent().path, nil) {
            self.trustedContainerURL = URL(fileURLWithPath: String(cString: parent))
                .appendingPathComponent(trustedContainerURL.lastPathComponent, isDirectory: true)
            free(parent)
        } else {
            self.trustedContainerURL = trustedContainerURL
        }
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
        primaryPublication = SettingsPrimaryPublication(
            systemCallHook: publicationSystemCallHook,
            writeHook: publicationWriteHook,
            aclHook: publicationACLHook,
            boundaryHook: publicationBoundaryHook,
            nameSource: publicationNameSource
        )
        self.publicationResidualInventory =
            publicationResidualInventory
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
        try withAcquiredResources { resources in
            let lease = SettingsPrimaryLockedInspectionLease {
                readPrimary(resources)
            }
            defer { lease.invalidate() }
            return try body(
                SettingsPrimaryLockedInspectionAuthority(
                    lease: lease
                )
            )
        }
    }

    func withMutationLock<T>(
        _ body: (SettingsPrimaryMutationAuthority) throws -> T
    ) throws -> T {
        try withAcquiredResources { resources in
            let lease = SettingsPrimaryMutationAuthorityLease(
                readOperation: {
                    readPrimary(resources)
                },
                publishOperation: { request in
                    primaryPublication.publish(
                        request,
                        settingsDescriptor: resources.settings,
                        readPrimary: {
                            readPrimaryAfterPublicationMutation(resources)
                        }
                    )
                },
                residualInventoryOperation: {
                    inspectPublicationResiduals(resources)
                },
                adoptTrustedContainerOperation: {
                    try TrustedParallaxContainer(
                        adoptingValidatedContainer: FileHandle(
                            fileDescriptor: resources.container,
                            closeOnDealloc: false
                        ),
                        url: trustedContainerURL
                    )
                },
                preserveResidualsOperation: {
                    // Bound each inventory and the number of recovery batches.
                    for _ in 0..<64 {
                        guard case .success(.missing) = readPrimary(resources) else {
                            throw SettingsPrimaryLockedInspectionError.fileAccess(.changedDuringRead)
                        }
                        let inventory = try inspectPublicationResiduals(resources).get()
                        guard try publicationResidualInventory.preserveRecoverableEntries(
                            inventory, settingsDescriptor: resources.settings
                        ) else { return inventory }
                        try refreshSettingsIdentity(resources)
                    }
                    return try inspectPublicationResiduals(resources).get()
                }
            )
            defer { lease.invalidate() }
            return try body(
                SettingsPrimaryMutationAuthority(lease: lease)
            )
        }
    }

    private func withAcquiredResources<T>(
        _ body: (Resources) throws -> T
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

        let result: Result<T, Error>
        do {
            result = .success(try body(resources))
        } catch {
            result = .failure(error)
        }
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
        try acquireFlock(resources.lock)
        resources.locked = true
        // A peer may have published while we waited for flock.
        try refreshSettingsIdentity(resources)
        boundaryHook(.afterFlock)

        try revalidateAfterFlock(resources)
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
        let outcome = SettingsDescriptorClose.descriptor(value) {
            systemCallHook(call)
        }
        if case .failure(let code) = outcome {
            failures.append(.init(operation: operation, code: code))
        }
    }
}
