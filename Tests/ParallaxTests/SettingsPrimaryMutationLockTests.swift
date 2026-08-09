import Darwin
import Foundation
import XCTest
@testable import Parallax

final class SettingsPrimaryMutationLockTests:
    XCTestCase,
    @unchecked Sendable
{
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories.reversed() {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    func testOwnerMaskingUmaskFailsClosedAndPreservesUnpinnedStaging()
        throws
    {
        let container = try temporaryContainer()
        let previous = umask(0o777)
        defer { _ = umask(previous) }

        var entered = false
        XCTAssertThrowsError(
            try makeLock(container).withLock {
                entered = true
            }
        ) { error in
            guard case .systemCall(let primary) =
                error as? SettingsPrimaryMutationLockError
            else {
                return XCTFail("Expected setup failure, got \(error)")
            }
            XCTAssertEqual(primary.code, EACCES)
        }
        XCTAssertFalse(entered)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: settings(in: container).path
            )
        )
        XCTAssertEqual(mode(settingsStaging(in: container)), 0)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: lockFile(in: container).path
            )
        )
    }

    func testMissingDirectoryPublishesPinnedStageAndCreatesLock()
        throws
    {
        let container = try temporaryContainer()
        let previous = umask(0o077)
        defer { _ = umask(previous) }

        var entered = false
        try makeLock(container).withLock {
            entered = true
            XCTAssertEqual(mode(settings(in: container)), 0o700)
            XCTAssertEqual(mode(lockFile(in: container)), 0o600)
        }

        XCTAssertTrue(entered)
        XCTAssertEqual(
            try entries(settings(in: container)),
            [SettingsPrimaryMutationLock.lockName]
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: settingsStaging(in: container).path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: settings(in: container)
                    .appendingPathComponent(
                        SettingsPrimaryFileAccess.primaryName
                    ).path
            )
        )
        XCTAssertNoThrow(try makeLock(container).withLock {})
    }

    func testExistingSafeDirectoryAndLockAreReusedWithoutRepair()
        throws
    {
        let container = try temporaryContainer()
        try createSettingsAndLock(in: container)
        let beforeDirectory = try metadata(settings(in: container))
        let beforeLock = try metadata(lockFile(in: container))

        try makeLock(container).withLock {}

        XCTAssertEqual(try metadata(settings(in: container)), beforeDirectory)
        XCTAssertEqual(try metadata(lockFile(in: container)), beforeLock)
    }

    func testMissingAndUnsafeTrustedContainersFailClosed() throws {
        let root = try temporaryRoot()
        let missing = root.appendingPathComponent("missing")
        assertLockError(
            .missingTrustedContainer,
            from: makeLock(missing)
        )

        let target = try temporaryContainer(in: root, name: "target")
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )
        assertLockError(
            .unsafeItem(
                item: .trustedContainer,
                reason: .symbolicLink
            ),
            from: makeLock(link)
        )

        try chmod(target, 0o755)
        assertUnsafeMode(
            item: .trustedContainer,
            expected: 0o700,
            actual: 0o755,
            from: makeLock(target)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: settings(in: target).path
            )
        )

        var wrongOwner = try metadata(root)
        wrongOwner.owner &+= 1
        XCTAssertEqual(
            SettingsPrimaryDescriptorSecurity
                .ownershipAndModeReason(wrongOwner),
            .wrongOwner
        )

        let systemOwned = URL(
            fileURLWithPath: "/private/tmp",
            isDirectory: true
        )
        assertUnsafe(
            item: .trustedContainer,
            reason: .wrongOwner,
            from: makeLock(systemOwned)
        )
    }

    func testExistingSettingsObjectsRejectWithoutRepairOrBlocking()
        throws
    {
        let container = try temporaryContainer()
        let settingsURL = settings(in: container)
        let outside = container.appendingPathComponent("outside")
        try Data("x".utf8).write(to: outside)
        try chmod(outside, 0o600)

        try FileManager.default.createSymbolicLink(
            at: settingsURL,
            withDestinationURL: outside
        )
        assertUnsafe(
            item: .settingsDirectory,
            reason: .symbolicLink,
            from: makeLock(container)
        )
        try FileManager.default.removeItem(at: settingsURL)

        try Data("file".utf8).write(to: settingsURL)
        try chmod(settingsURL, 0o700)
        assertUnsafe(
            item: .settingsDirectory,
            reason: .unsupportedType,
            from: makeLock(container)
        )
        try FileManager.default.removeItem(at: settingsURL)

        XCTAssertEqual(mkfifo(settingsURL.path, 0o700), 0)
        assertUnsafe(
            item: .settingsDirectory,
            reason: .unsupportedType,
            from: makeLock(container)
        )
        try FileManager.default.removeItem(at: settingsURL)

        let socket = try createUNIXSocket(at: settingsURL)
        defer { close(socket) }
        assertUnsafe(
            item: .settingsDirectory,
            reason: .unsupportedType,
            from: makeLock(container)
        )
    }

    func testExistingLockObjectsRejectWithoutRepairOrBlocking() throws {
        let container = try temporaryContainer()
        try createSettings(in: container)
        let lockURL = lockFile(in: container)
        let outside = container.appendingPathComponent("outside")
        try Data("x".utf8).write(to: outside)
        try chmod(outside, 0o600)

        try FileManager.default.createSymbolicLink(
            at: lockURL,
            withDestinationURL: outside
        )
        assertUnsafe(item: .lock, reason: .symbolicLink, from: makeLock(container))
        try FileManager.default.removeItem(at: lockURL)

        try FileManager.default.linkItem(at: outside, to: lockURL)
        assertUnsafe(
            item: .lock,
            reason: .multipleHardLinks,
            from: makeLock(container)
        )
        XCTAssertEqual(mode(lockURL), 0o600)
        try FileManager.default.removeItem(at: lockURL)

        XCTAssertEqual(mkfifo(lockURL.path, 0o600), 0)
        assertUnsafe(
            item: .lock,
            reason: .unsupportedType,
            from: makeLock(container)
        )
        try FileManager.default.removeItem(at: lockURL)

        try FileManager.default.createDirectory(
            at: lockURL,
            withIntermediateDirectories: false
        )
        try chmod(lockURL, 0o600)
        assertUnsafe(
            item: .lock,
            reason: .unsupportedType,
            from: makeLock(container)
        )
        try FileManager.default.removeItem(at: lockURL)

        let socket = try createUNIXSocket(at: lockURL)
        defer { close(socket) }
        assertUnsafe(
            item: .lock,
            reason: .unsupportedType,
            from: makeLock(container)
        )
    }

    func testExistingModesAndSpecialBitsRejectWithoutRepair() throws {
        let container = try temporaryContainer()
        try createSettingsAndLock(in: container)
        let settingsURL = settings(in: container)
        let lockURL = lockFile(in: container)

        for candidate: mode_t in [0o755, 0o1700, 0o2700, 0o4700] {
            try chmod(settingsURL, candidate)
            assertUnsafeMode(
                item: .settingsDirectory,
                expected: 0o700,
                actual: UInt16(candidate),
                from: makeLock(container)
            )
            XCTAssertEqual(mode(settingsURL), UInt16(candidate))
            try chmod(settingsURL, 0o700)
        }

        for candidate: mode_t in [0o644, 0o1600, 0o2600, 0o4600] {
            try chmod(lockURL, candidate)
            assertUnsafeMode(
                item: .lock,
                expected: 0o600,
                actual: UInt16(candidate),
                from: makeLock(container)
            )
            XCTAssertEqual(mode(lockURL), UInt16(candidate))
            try chmod(lockURL, 0o600)
        }
    }

    func testRealContainerSettingsAndLockACLsReject() throws {
        let container = try temporaryContainer()
        try createSettingsAndLock(in: container)
        let fixtures: [
            (
                URL,
                SettingsPrimaryMutationLockItem
            )
        ] = [
            (container, .trustedContainer),
            (settings(in: container), .settingsDirectory),
            (lockFile(in: container), .lock),
        ]

        for (url, item) in fixtures {
            try setExtendedACL(on: url)
            assertUnsafe(
                item: item,
                reason: .extendedACL,
                from: makeLock(container)
            )
            try removeExtendedACL(from: url)
        }
    }

    func testACLFailureIsTypedAndCreatedObjectsArePreserved() throws {
        let container = try temporaryContainer()
        let access = makeLock(
            container,
            aclHook: { item, _ in
                item == .settingsDirectory
                    ? .failure(code: EIO)
                    : .absent
            }
        )
        assertSystemCode(EIO, from: access)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: settingsStaging(in: container).path
            )
        )
    }

    func testSettingsLockAndContainerSwapsFailClosed() throws {
        do {
            let container = try temporaryContainer()
            try createSettings(in: container)
            let flag = Once()
            let access = makeLock(
                container,
                hook: { boundary in
                    if boundary == .afterSettingsPreflight, flag.claim() {
                        let original = self.settings(in: container)
                        let old = container.appendingPathComponent("old-settings")
                        try? FileManager.default.moveItem(at: original, to: old)
                        try? FileManager.default.createDirectory(
                            at: original,
                            withIntermediateDirectories: false
                        )
                        try? self.chmod(original, 0o700)
                    }
                }
            )
            assertLockError(
                .changedDuringAcquisition(item: .settingsDirectory),
                from: access
            )
        }

        do {
            let container = try temporaryContainer()
            try createSettingsAndLock(in: container)
            let flag = Once()
            let access = makeLock(
                container,
                hook: { boundary in
                    if boundary == .afterLockOpen, flag.claim() {
                        let lock = self.lockFile(in: container)
                        let old = self.settings(in: container)
                            .appendingPathComponent("old-lock")
                        try? FileManager.default.moveItem(at: lock, to: old)
                        _ = FileManager.default.createFile(
                            atPath: lock.path,
                            contents: Data()
                        )
                        try? self.chmod(lock, 0o600)
                    }
                }
            )
            assertLockError(
                .changedDuringAcquisition(item: .lock),
                from: access
            )
        }

        do {
            let root = try temporaryRoot()
            let container = try temporaryContainer(
                in: root,
                name: "container"
            )
            try createSettingsAndLock(in: container)
            let flag = Once()
            let access = makeLock(
                container,
                hook: { boundary in
                    if boundary == .afterFlock, flag.claim() {
                        let old = root.appendingPathComponent("old-container")
                        try? FileManager.default.moveItem(
                            at: container,
                            to: old
                        )
                        try? FileManager.default.createDirectory(
                            at: container,
                            withIntermediateDirectories: false
                        )
                        try? self.chmod(container, 0o700)
                    }
                }
            )
            assertLockError(
                .changedDuringAcquisition(item: .trustedContainer),
                from: access
            )
        }
    }

    func testCreatedIdentitySwapIsPreservedAndNeverRepairedOrDeleted()
        throws
    {
        let container = try temporaryContainer()
        let replacementMode: mode_t = 0o755
        let flag = Once()
        let access = makeLock(
            container,
            hook: { boundary in
                if boundary == .afterSettingsCreatedIdentity, flag.claim() {
                    let created = self.settingsStaging(in: container)
                    let old = container.appendingPathComponent("created-old")
                    try? FileManager.default.moveItem(at: created, to: old)
                    try? FileManager.default.createDirectory(
                        at: created,
                        withIntermediateDirectories: false
                    )
                    try? self.chmod(created, replacementMode)
                }
            }
        )

        assertLockError(
            .changedDuringAcquisition(item: .settingsDirectory),
            from: access
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: settingsStaging(in: container).path
            )
        )
        XCTAssertEqual(
            mode(settingsStaging(in: container)),
            UInt16(replacementMode)
        )
        XCTAssertEqual(
            mode(container.appendingPathComponent("created-old")),
            0o700
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: settings(in: container).path
            )
        )
    }

    func testStagingNameCollisionLimitPreservesExistingEntry() throws {
        let container = try temporaryContainer()
        let collision = settingsStaging(in: container)
        try FileManager.default.createDirectory(
            at: collision,
            withIntermediateDirectories: false
        )
        try chmod(collision, 0o755)

        assertSystemCode(EEXIST, from: makeLock(container))

        XCTAssertEqual(mode(collision), 0o755)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: settings(in: container).path
            )
        )
    }

    func testConcurrentSettingsPublicationNeverOverwritesExisting()
        throws
    {
        let container = try temporaryContainer()
        let marker = settings(in: container)
            .appendingPathComponent("racing-owner")
        let once = Once()
        let access = makeLock(
            container,
            hook: { boundary in
                guard boundary == .beforeSettingsPublish,
                      once.claim()
                else {
                    return
                }
                try? FileManager.default.createDirectory(
                    at: self.settings(in: container),
                    withIntermediateDirectories: false
                )
                try? self.chmod(self.settings(in: container), 0o700)
                _ = FileManager.default.createFile(
                    atPath: marker.path,
                    contents: Data("racing".utf8)
                )
            }
        )

        assertSystemCode(EEXIST, from: access)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: marker.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: settingsStaging(in: container).path
            )
        )
    }

    func testPublicationFailureAndPostEffectFailuresPreserveArtifacts()
        throws
    {
        let failures: [SettingsPrimaryMutationLockSystemCall] = [
            .publishSettings,
            .inspectPublishedSettingsPath,
            .syncContainer,
        ]
        for call in failures {
            let container = try temporaryContainer()
            assertSystemCode(
                EIO,
                from: makeLock(
                    container,
                    systemCallHook: { $0 == call ? EIO : nil }
                )
            )
            let expected = call == .publishSettings
                ? [".Settings.create-1"]
                : [SettingsPrimaryMutationLock.settingsName]
            XCTAssertEqual(try entries(container), expected)
        }
    }

    func testPublishedDirectorySwapPreservesBothUnknownPaths() throws {
        let container = try temporaryContainer()
        let moved = container.appendingPathComponent("published-old")
        let once = Once()
        let access = makeLock(
            container,
            hook: { boundary in
                guard boundary == .afterSettingsPublish,
                      once.claim()
                else {
                    return
                }
                try? FileManager.default.moveItem(
                    at: self.settings(in: container),
                    to: moved
                )
                try? FileManager.default.createDirectory(
                    at: self.settings(in: container),
                    withIntermediateDirectories: false
                )
                try? self.chmod(self.settings(in: container), 0o755)
            }
        )

        assertLockError(
            .changedDuringAcquisition(item: .settingsDirectory),
            from: access
        )
        XCTAssertEqual(mode(settings(in: container)), 0o755)
        XCTAssertEqual(mode(moved), 0o700)
    }

    func testSetupSyscallFailuresAreTypedAndDoNotEnterBody() throws {
        let missingFlow: [SettingsPrimaryMutationLockSystemCall] = [
            .openContainer,
            .inspectContainer,
            .inspectSettingsPath,
            .createSettings,
            .inspectCreatedSettingsPath,
            .openSettings,
            .inspectSettings,
            .setSettingsMode,
            .reinspectSettings,
            .reinspectSettingsPath,
            .publishSettings,
            .inspectPublishedSettingsPath,
            .syncContainer,
            .inspectLockPath,
            .createLock,
            .inspectLock,
            .setLockMode,
            .reinspectLock,
            .reinspectLockPath,
            .syncSettings,
            .flock,
            .reopenContainer,
            .inspectReopenedContainer,
            .reinspectPinnedContainer,
            .reinspectPinnedSettings,
            .reinspectSettingsPathAfterLock,
            .reinspectPinnedLock,
            .reinspectLockPathAfterLock,
        ]

        for call in missingFlow {
            let container = try temporaryContainer()
            var entered = false
            let access = makeLock(
                container,
                systemCallHook: { $0 == call ? EIO : nil }
            )
            XCTAssertThrowsError(
                try access.withLock { entered = true },
                "Expected injected failure for \(call)"
            )
            XCTAssertFalse(entered)
        }

        let container = try temporaryContainer()
        try createSettingsAndLock(in: container)
        assertSystemCode(
            EMFILE,
            from: makeLock(
                container,
                systemCallHook: {
                    $0 == .reopenLock ? EMFILE : nil
                }
            )
        )
    }

    func testInjectedFlockEINTRRetriesAndDeterministicTimeout() throws {
        let container = try temporaryContainer()
        let calls = FlockDirectiveState([EINTR, EINTR, 0])
        var entered = false
        try makeLock(
            container,
            systemCallHook: { call in
                guard call == .flock else { return nil }
                let code = calls.next()
                return code == 0 ? nil : code
            }
        ).withLock {
            entered = true
        }
        XCTAssertTrue(entered)
        XCTAssertGreaterThanOrEqual(calls.count, 3)

        let clock = MonotonicFixture(
            values: [0, 0, 5_000_000, 10_000_000]
        )
        let timeout = makeLock(
            container,
            timeout: 0.01,
            pollInterval: 0.005,
            systemCallHook: {
                $0 == .flock ? EWOULDBLOCK : nil
            },
            monotonicNow: { clock.next() },
            sleeper: { clock.recordSleep($0) }
        )
        assertLockError(
            .timedOut(timeout: 0.01),
            from: timeout
        )
        XCTAssertEqual(clock.sleeps, [5_000_000, 5_000_000])

        let interruptedClock = MonotonicFixture(
            values: [0, 2_000_000, 4_000_000, 10_000_000]
        )
        let interruptedCalls = FlockDirectiveState([])
        let perpetuallyInterrupted = makeLock(
            container,
            timeout: 0.01,
            pollInterval: 0.005,
            systemCallHook: { call in
                guard call == .flock else { return nil }
                _ = interruptedCalls.next()
                return EINTR
            },
            monotonicNow: { interruptedClock.next() },
            sleeper: { interruptedClock.recordSleep($0) }
        )
        assertLockError(
            .timedOut(timeout: 0.01),
            from: perpetuallyInterrupted
        )
        XCTAssertEqual(interruptedCalls.count, 3)
        XCTAssertEqual(
            interruptedClock.sleeps,
            [5_000_000, 5_000_000]
        )
    }

    func testFlockNoProgressBudgetSurvivesFrozenClock() throws {
        let container = try temporaryContainer()
        let calls = FlockDirectiveState([
            EWOULDBLOCK,
            EAGAIN,
            EINTR,
            EWOULDBLOCK,
        ])
        let lock = makeLock(
            container,
            maximumConsecutiveFlockNoProgress: 3,
            systemCallHook: { call in
                guard call == .flock else { return nil }
                return calls.next()
            },
            monotonicNow: { 0 },
            sleeper: { _ in }
        )

        assertLockError(.timedOut(timeout: 2), from: lock)
        XCTAssertEqual(calls.count, 4)
    }

    func testStatusCallEINTRBudgetFailsClosed() throws {
        let container = try temporaryContainer()
        let calls = FlockDirectiveState(
            Array(
                repeating: EINTR,
                count: SettingsPrimaryMutationLock
                    .maximumConsecutiveInterruptedStatusCalls + 1
            )
        )
        let lock = makeLock(
            container,
            systemCallHook: { call in
                guard call == .setSettingsMode else { return nil }
                return calls.next()
            }
        )

        assertSystemCode(EINTR, from: lock)
        XCTAssertEqual(
            calls.count,
            SettingsPrimaryMutationLock
                .maximumConsecutiveInterruptedStatusCalls + 1
        )
    }

    func testTwoContendersPermitExactlyOneLeaseThenReleasePermitsNext()
        throws
    {
        let container = try temporaryContainer()
        try createSettingsAndLock(in: container)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let firstResult = ErrorBox()

        DispatchQueue.global().async {
            do {
                try self.makeLock(container).withLock {
                    entered.signal()
                    release.wait()
                }
            } catch {
                firstResult.store(error)
            }
            finished.signal()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)

        var secondEntered = false
        assertLockError(
            .timedOut(timeout: 0),
            from: makeLock(container, timeout: 0),
            body: { secondEntered = true }
        )
        XCTAssertFalse(secondEntered)

        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertNil(firstResult.error)
        XCTAssertNoThrow(
            try makeLock(container).withLock {}
        )
    }

    func testBodyAndCleanupFailurePrecedenceIsExplicit() throws {
        let container = try temporaryContainer()
        let bodyError = FixtureError.body
        let access = makeLock(
            container,
            systemCallHook: {
                $0 == .unlock ? EIO : nil
            }
        )

        XCTAssertThrowsError(
            try access.withLock {
                throw bodyError
            }
        ) { error in
            guard let combined =
                error as? SettingsPrimaryMutationLockPrimaryAndCleanupError
            else {
                return XCTFail("Expected combined error, got \(error)")
            }
            XCTAssertEqual(combined.primary as? FixtureError, bodyError)
            XCTAssertEqual(
                combined.cleanup.failures,
                [
                    .init(
                        operation: "unlock settings lock",
                        code: EIO
                    )
                ]
            )
        }

        let cleanupOnly = makeLock(
            container,
            systemCallHook: {
                $0 == .closeLock ? EBADF : nil
            }
        )
        XCTAssertThrowsError(try cleanupOnly.withLock {}) { error in
            XCTAssertEqual(
                error as? SettingsPrimaryMutationLockCleanupError,
                .init(
                    failures: [
                        .init(
                            operation: "close settings lock",
                            code: EBADF
                        )
                    ]
                )
            )
        }
    }

    func testEveryUnlockAndCloseFailureIsReportedAfterRealCleanup()
        throws
    {
        let calls: [
            (
                SettingsPrimaryMutationLockSystemCall,
                String
            )
        ] = [
            (.unlock, "unlock settings lock"),
            (.closeLock, "close settings lock"),
            (
                .closeReopenedContainer,
                "close revalidated trusted settings container"
            ),
            (.closeSettings, "close Settings directory"),
            (
                .closeContainer,
                "close trusted settings container"
            ),
        ]

        for (call, operation) in calls {
            let container = try temporaryContainer()
            let access = makeLock(
                container,
                systemCallHook: { $0 == call ? EIO : nil }
            )
            XCTAssertThrowsError(try access.withLock {}) { error in
                XCTAssertEqual(
                    error as? SettingsPrimaryMutationLockCleanupError,
                    .init(
                        failures: [
                            .init(operation: operation, code: EIO)
                        ]
                    )
                )
            }
            XCTAssertNoThrow(
                try makeLock(container).withLock {}
            )
        }
    }

    func testFailedAcquisitionPreservesCreatedObjectsAtEveryStage()
        throws
    {
        let stagingContainer = try temporaryContainer()
        let stagingFailure = makeLock(
            stagingContainer,
            systemCallHook: {
                $0 == .setSettingsMode ? EIO : nil
            }
        )
        assertSystemCode(EIO, from: stagingFailure)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: settingsStaging(in: stagingContainer).path
            )
        )

        let preAuthorityContainer = try temporaryContainer()
        let preAuthorityFailure = makeLock(
            preAuthorityContainer,
            systemCallHook: {
                $0 == .setLockMode ? EIO : nil
            }
        )
        assertSystemCode(EIO, from: preAuthorityFailure)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: settings(in: preAuthorityContainer).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: lockFile(in: preAuthorityContainer).path
            )
        )

        let postAuthorityContainer = try temporaryContainer()
        let postAuthorityFailure = makeLock(
            postAuthorityContainer,
            systemCallHook: {
                $0 == .flock ? EIO : nil
            }
        )
        assertSystemCode(EIO, from: postAuthorityFailure)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: settings(in: postAuthorityContainer).path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: lockFile(in: postAuthorityContainer).path
            )
        )
    }

    func testFinalValidatedLockSwapPreservesOriginalAndReplacement() throws {
        let container = try temporaryContainer()
        let moved = settings(in: container)
            .appendingPathComponent("moved-original-lock")
        let replacement = Data("replacement-lock".utf8)
        let once = Once()
        let access = makeLock(
            container,
            hook: { boundary in
                guard boundary == .afterLockOpen, once.claim() else {
                    return
                }
                try? FileManager.default.moveItem(
                    at: self.lockFile(in: container),
                    to: moved
                )
                _ = FileManager.default.createFile(
                    atPath: self.lockFile(in: container).path,
                    contents: replacement
                )
                try? self.chmod(self.lockFile(in: container), 0o600)
            },
            systemCallHook: { call in
                call == .syncSettings ? EIO : nil
            }
        )

        assertSystemCode(EIO, from: access)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: moved.path)
        )
        XCTAssertEqual(
            try Data(contentsOf: lockFile(in: container)),
            replacement
        )
    }

    func testFinalValidatedSettingsSwapPreservesOriginalAndReplacement()
        throws
    {
        let container = try temporaryContainer()
        let moved = container.appendingPathComponent(
            "moved-original-settings",
            isDirectory: true
        )
        let marker = settings(in: container).appendingPathComponent(
            "replacement-marker"
        )
        let once = Once()
        let access = makeLock(
            container,
            hook: { boundary in
                guard boundary == .afterLockOpen, once.claim() else {
                    return
                }
                try? FileManager.default.moveItem(
                    at: self.settings(in: container),
                    to: moved
                )
                try? FileManager.default.createDirectory(
                    at: self.settings(in: container),
                    withIntermediateDirectories: false
                )
                try? self.chmod(self.settings(in: container), 0o700)
                _ = FileManager.default.createFile(
                    atPath: marker.path,
                    contents: Data("replacement-settings".utf8)
                )
            },
            systemCallHook: { call in
                call == .syncSettings ? EIO : nil
            }
        )

        assertSystemCode(EIO, from: access)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: moved
                    .appendingPathComponent(
                        SettingsPrimaryMutationLock.lockName
                    ).path
            )
        )
        XCTAssertEqual(
            try Data(contentsOf: marker),
            Data("replacement-settings".utf8)
        )
    }

    func testMissingCreatedPathDoesNotSuppressPrimaryFailure()
        throws
    {
        let container = try temporaryContainer()
        let access = makeLock(
            container,
            systemCallHook: { call in
                guard call == .reinspectLock else {
                    return nil
                }
                try? FileManager.default.removeItem(
                    at: self.lockFile(in: container)
                )
                return EIO
            }
        )

        assertSystemCode(EIO, from: access)
        XCTAssertEqual(
            try entries(container),
            [SettingsPrimaryMutationLock.settingsName]
        )
        XCTAssertEqual(try entries(settings(in: container)), [])
    }

    private func makeLock(
        _ container: URL,
        timeout: TimeInterval = 2,
        pollInterval: TimeInterval = 0.01,
        maximumConsecutiveFlockNoProgress: Int =
            SettingsPrimaryMutationLock
                .defaultMaximumConsecutiveFlockNoProgress,
        hook: @escaping SettingsPrimaryMutationLock.BoundaryHook = {
            _ in
        },
        aclHook: @escaping SettingsPrimaryMutationLock.ACLHook = {
            _, _ in .system
        },
        systemCallHook:
            @escaping SettingsPrimaryMutationLock.SystemCallHook = {
                _ in nil
            },
        monotonicNow:
            @escaping SettingsPrimaryMutationLock.MonotonicNow = {
                DispatchTime.now().uptimeNanoseconds
            },
        sleeper: @escaping SettingsPrimaryMutationLock.Sleeper = {
            nanoseconds in
            usleep(useconds_t(nanoseconds / 1_000))
        },
        stagingNameSource:
            @escaping SettingsPrimaryMutationLock.StagingNameSource = {
                1
        }
    ) -> SettingsPrimaryMutationLock {
        SettingsPrimaryMutationLock(
            trustedContainerURL: container,
            timeout: timeout,
            pollInterval: pollInterval,
            maximumConsecutiveFlockNoProgress:
                maximumConsecutiveFlockNoProgress,
            boundaryHook: hook,
            aclHook: aclHook,
            systemCallHook: systemCallHook,
            monotonicNow: monotonicNow,
            sleeper: sleeper,
            stagingNameSource: stagingNameSource
        )
    }

    private func temporaryRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "px-lock-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try chmod(root, 0o700)
        temporaryDirectories.append(root)
        return root
    }

    private func temporaryContainer(
        in root: URL? = nil,
        name: String = "container"
    ) throws -> URL {
        if let root {
            return try temporaryContainer(in: root, name: name)
        }
        return try temporaryRoot()
    }

    private func temporaryContainer(
        in root: URL,
        name: String
    ) throws -> URL {
        let container = root.appendingPathComponent(
            name,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: false
        )
        try chmod(container, 0o700)
        return container
    }

    private func settings(in container: URL) -> URL {
        container.appendingPathComponent(
            SettingsPrimaryMutationLock.settingsName,
            isDirectory: true
        )
    }

    private func settingsStaging(
        in container: URL,
        value: UInt64 = 1
    ) -> URL {
        container.appendingPathComponent(
            SettingsPrimaryMutationLock.settingsStagingPrefix
                + String(value, radix: 16),
            isDirectory: true
        )
    }

    private func lockFile(in container: URL) -> URL {
        settings(in: container).appendingPathComponent(
            SettingsPrimaryMutationLock.lockName,
            isDirectory: false
        )
    }

    private func createSettings(in container: URL) throws {
        let url = settings(in: container)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        try chmod(url, 0o700)
    }

    private func createSettingsAndLock(in container: URL) throws {
        try createSettings(in: container)
        let url = lockFile(in: container)
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: url.path,
                contents: Data()
            )
        )
        try chmod(url, 0o600)
    }

    private func entries(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private func chmod(_ url: URL, _ value: mode_t) throws {
        guard Darwin.chmod(url.path, value) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
    }

    private func mode(_ url: URL) -> UInt16 {
        (try? metadata(url).mode) ?? UInt16.max
    }

    private func metadata(
        _ url: URL
    ) throws -> SettingsPrimaryFileMetadata {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        return SettingsPrimaryDescriptorSecurity.metadata(from: value)
    }

    private func assertUnsafe(
        item: SettingsPrimaryMutationLockItem,
        reason: SettingsPrimaryMutationLockUnsafeReason,
        from access: SettingsPrimaryMutationLock,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertLockError(
            .unsafeItem(item: item, reason: reason),
            from: access,
            file: file,
            line: line
        )
    }

    private func assertUnsafeMode(
        item: SettingsPrimaryMutationLockItem,
        expected: UInt16,
        actual: UInt16,
        from access: SettingsPrimaryMutationLock,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertUnsafe(
            item: item,
            reason: .incorrectMode(
                expected: expected,
                actual: actual
            ),
            from: access,
            file: file,
            line: line
        )
    }

    private func assertSystemCode(
        _ code: Int32,
        from access: SettingsPrimaryMutationLock,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try access.withLock {},
            file: file,
            line: line
        ) { error in
            let primary: any Error
            if let combined =
                error as? SettingsPrimaryMutationLockPrimaryAndCleanupError
            {
                primary = combined.primary
            } else {
                primary = error
            }
            guard case .systemCall(let failure) =
                primary as? SettingsPrimaryMutationLockError
            else {
                return XCTFail(
                    "Expected system failure, got \(error)",
                    file: file,
                    line: line
                )
            }
            XCTAssertEqual(failure.code, code, file: file, line: line)
        }
    }

    private func assertLockError(
        _ expected: SettingsPrimaryMutationLockError,
        from access: SettingsPrimaryMutationLock,
        body: () throws -> Void = {},
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try access.withLock(body),
            file: file,
            line: line
        ) { error in
            let primary: any Error
            if let combined =
                error as? SettingsPrimaryMutationLockPrimaryAndCleanupError
            {
                primary = combined.primary
            } else {
                primary = error
            }
            XCTAssertEqual(
                primary as? SettingsPrimaryMutationLockError,
                expected,
                file: file,
                line: line
            )
        }
    }

    private func setExtendedACL(on url: URL) throws {
        try runChmod(["+a", "everyone allow read", url.path])
    }

    private func removeExtendedACL(from url: URL) throws {
        try runChmod(["-N", url.path])
    }

    private func runChmod(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw POSIXError(.EIO)
        }
    }

    private func createUNIXSocket(at url: URL) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(url.path.utf8) + [0]
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(
                to: UInt8.self,
                capacity: capacity
            ) { bytes in
                for index in pathBytes.indices {
                    bytes[index] = pathBytes[index]
                }
            }
        }
        let length = socklen_t(
            MemoryLayout<sa_family_t>.size + pathBytes.count
        )
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, length)
            }
        }
        guard result == 0 else {
            let code = errno
            close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }
}

private enum FixtureError: Error, Equatable {
    case body
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var available = true

    func claim() -> Bool {
        lock.withLock {
            guard available else { return false }
            available = false
            return true
        }
    }
}

private final class FlockDirectiveState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int32]
    private var storedCount = 0

    init(_ values: [Int32]) {
        self.values = values
    }

    var count: Int {
        lock.withLock { storedCount }
    }

    func next() -> Int32 {
        lock.withLock {
            storedCount += 1
            guard !values.isEmpty else { return 0 }
            return values.removeFirst()
        }
    }
}

private final class MonotonicFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64]
    private var storedSleeps: [UInt64] = []

    init(values: [UInt64]) {
        self.values = values
    }

    var sleeps: [UInt64] {
        lock.withLock { storedSleeps }
    }

    func next() -> UInt64 {
        lock.withLock {
            guard !values.isEmpty else { return UInt64.max }
            return values.removeFirst()
        }
    }

    func recordSleep(_ value: UInt64) {
        lock.withLock {
            storedSleeps.append(value)
        }
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (any Error)?

    var error: (any Error)? {
        lock.withLock { stored }
    }

    func store(_ error: any Error) {
        lock.withLock {
            stored = error
        }
    }
}
