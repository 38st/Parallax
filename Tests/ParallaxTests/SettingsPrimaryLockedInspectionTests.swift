import Darwin
import Foundation
import XCTest
@testable import Parallax

final class SettingsPrimaryLockedInspectionTests:
    XCTestCase,
    @unchecked Sendable
{
    private var temporaryRoots: [URL] = []

    override func tearDownWithError() throws {
        for root in temporaryRoots.reversed() {
            try? FileManager.default.removeItem(at: root)
        }
        temporaryRoots = []
    }

    func testMissingAndCurrentBytesUsePinnedSettingsDirectory() throws {
        let fixture = try makeFixture()

        try makeLock(fixture.container).withLock { authority in
            XCTAssertEqual(authority.readPrimary(), .success(.missing))
        }

        let expected = Data("{\"revision\":1}".utf8)
        try writePrimary(expected, fixture: fixture)
        try makeLock(fixture.container).withLock { authority in
            XCTAssertEqual(
                authority.readPrimary(),
                .success(.bytes(expected))
            )
        }
    }

    func testEscapedCopiesExpireBeforeCleanupAndCannotTouchReusedFD()
        throws
    {
        let fixture = try makeFixture()
        try writePrimary(Data("lease".utf8), fixture: fixture)
        let reads = DescriptorReadState()
        var escaped: SettingsPrimaryLockedInspectionAuthority?
        var copied: SettingsPrimaryLockedInspectionAuthority?
        let crossThread = InspectionResultBox()

        try makeLock(
            fixture.container,
            inspectionReadHook: { descriptor, _ in
                reads.record(descriptor)
                return .system
            }
        ).withLock { authority in
            escaped = authority
            copied = authority
            XCTAssertEqual(
                authority.readPrimary(),
                .success(.bytes(Data("lease".utf8)))
            )
            let finished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                crossThread.store(authority.readPrimary())
                finished.signal()
            }
            XCTAssertEqual(
                finished.wait(timeout: .now() + 2),
                .success
            )
            XCTAssertEqual(
                crossThread.result,
                .failure(.expiredAuthority)
            )
        }

        let readCount = reads.count
        let leafDescriptor = try XCTUnwrap(reads.firstDescriptor)
        var reusedDescriptors: [Int32] = []
        defer {
            for descriptor in reusedDescriptors {
                close(descriptor)
            }
        }
        while reusedDescriptors.count < 32 {
            let descriptor = open("/dev/null", O_RDONLY | O_CLOEXEC)
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            reusedDescriptors.append(descriptor)
            if descriptor == leafDescriptor {
                break
            }
        }
        XCTAssertTrue(reusedDescriptors.contains(leafDescriptor))

        XCTAssertEqual(escaped?.readPrimary(), .failure(.expiredAuthority))
        XCTAssertEqual(copied?.readPrimary(), .failure(.expiredAuthority))
        XCTAssertEqual(reads.count, readCount)
    }

    func testHookReentryReturnsImmediatelyWithoutHoldingLeaseLock()
        throws
    {
        let fixture = try makeFixture()
        try writePrimary(Data("reentry".utf8), fixture: fixture)
        let authorityBox = InspectionAuthorityBox()
        let sameThread = InspectionResultBox()
        let crossThread = InspectionResultBox()
        let once = OnceFlag()
        let access = makeLock(
            fixture.container,
            inspectionBoundaryHook: { boundary in
                guard boundary == .afterLeafOpen,
                      once.claim(),
                      let authority = authorityBox.authority
                else {
                    return
                }
                sameThread.store(authority.readPrimary())

                let finished = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    crossThread.store(authority.readPrimary())
                    finished.signal()
                }
                XCTAssertEqual(
                    finished.wait(timeout: .now() + 2),
                    .success
                )
            }
        )

        try access.withLock { authority in
            authorityBox.store(authority)
            XCTAssertEqual(
                authority.readPrimary(),
                .success(.bytes(Data("reentry".utf8)))
            )
        }
        XCTAssertEqual(
            sameThread.result,
            .failure(.reentrantAuthorityOperation)
        )
        XCTAssertEqual(
            crossThread.result,
            .failure(.expiredAuthority)
        )
    }

    func testTransientContainerCloseFailureAndCombinedPrecedence()
        throws
    {
        do {
            let fixture = try makeFixture()
            let closeState = TransientCloseObservation()
            let access = makeLock(
                fixture.container,
                systemCallHook: { call in
                    guard call == .closeAuthorityContainer else {
                        return nil
                    }
                    closeState.observeAndFail()
                    return EBADF
                }
            )
            try access.withLock { authority in
                closeState.setBaseline(openDescriptors())
                XCTAssertEqual(
                    authority.readPrimary(),
                    .failure(
                        .authorityContainerClose(
                            .init(
                                operation:
                                    "close transient trusted settings container",
                                code: EBADF
                            )
                        )
                    )
                )
                XCTAssertEqual(closeState.count, 1)
                let closed = try XCTUnwrap(
                    closeState.transientDescriptor
                )
                var opened: [Int32] = []
                defer {
                    for descriptor in opened {
                        close(descriptor)
                    }
                }
                while opened.count < 32 {
                    let descriptor = open(
                        "/dev/null",
                        O_RDONLY | O_CLOEXEC
                    )
                    XCTAssertGreaterThanOrEqual(descriptor, 0)
                    opened.append(descriptor)
                    if descriptor == closed {
                        break
                    }
                }
                XCTAssertTrue(opened.contains(closed))
            }
        }

        do {
            let fixture = try makeFixture()
            let failures = CombinedValidationCloseFailure()
            let access = makeLock(
                fixture.container,
                systemCallHook: { failures.result(for: $0) }
            )
            try access.withLock { authority in
                XCTAssertEqual(
                    authority.readPrimary(),
                    .failure(
                        .lockValidationAndAuthorityContainerClose(
                            validation: .systemCall(
                                .init(
                                    operation:
                                        "reinspect trusted settings container path",
                                    code: EIO
                                )
                            ),
                            close: .init(
                                operation:
                                    "close transient trusted settings container",
                                code: EBADF
                            )
                        )
                    )
                )
            }
            XCTAssertEqual(failures.closeCount, 1)
        }
    }

    func testContainerAndSettingsPathSwapsFailLockRevalidation()
        throws
    {
        do {
            let fixture = try makeFixture()
            try writePrimary(Data("container".utf8), fixture: fixture)
            let once = OnceFlag()
            let access = makeLock(
                fixture.container,
                inspectionBoundaryHook: { boundary in
                    guard boundary == .afterLeafOpen, once.claim() else {
                        return
                    }
                    let old = fixture.root.appendingPathComponent("old-container")
                    try? FileManager.default.moveItem(
                        at: fixture.container,
                        to: old
                    )
                    try? FileManager.default.createDirectory(
                        at: fixture.container,
                        withIntermediateDirectories: false
                    )
                    try? self.chmod(fixture.container, 0o700)
                }
            )
            try access.withLock { authority in
                XCTAssertEqual(
                    authority.readPrimary(),
                    .failure(
                        .lockValidation(
                            .changedDuringAcquisition(
                                item: .trustedContainer
                            )
                        )
                    )
                )
            }
        }

        do {
            let fixture = try makeFixture()
            try writePrimary(Data("settings".utf8), fixture: fixture)
            let once = OnceFlag()
            let access = makeLock(
                fixture.container,
                inspectionBoundaryHook: { boundary in
                    guard boundary == .afterLeafOpen, once.claim() else {
                        return
                    }
                    let old = fixture.container
                        .appendingPathComponent("old-settings")
                    try? FileManager.default.moveItem(
                        at: fixture.settings,
                        to: old
                    )
                    try? FileManager.default.createDirectory(
                        at: fixture.settings,
                        withIntermediateDirectories: false
                    )
                    try? self.chmod(fixture.settings, 0o700)
                }
            )
            try access.withLock { authority in
                XCTAssertEqual(
                    authority.readPrimary(),
                    .failure(.fileAccess(.changedDuringRead))
                )
            }
        }
    }

    func testLeafSwapAndGrowthFailPostflight() throws {
        do {
            let fixture = try makeFixture()
            try writePrimary(Data("prior".utf8), fixture: fixture)
            let once = OnceFlag()
            let access = makeLock(
                fixture.container,
                inspectionBoundaryHook: { boundary in
                    guard boundary == .afterLeafOpen, once.claim() else {
                        return
                    }
                    let old = fixture.settings
                        .appendingPathComponent("settings-old.json")
                    try? FileManager.default.moveItem(
                        at: fixture.primary,
                        to: old
                    )
                    _ = FileManager.default.createFile(
                        atPath: fixture.primary.path,
                        contents: Data("target".utf8)
                    )
                    try? self.chmod(fixture.primary, 0o600)
                }
            )
            try access.withLock { authority in
                XCTAssertEqual(
                    authority.readPrimary(),
                    .failure(.fileAccess(.changedDuringRead))
                )
            }
        }

        do {
            let fixture = try makeFixture()
            try writePrimary(Data("grow".utf8), fixture: fixture)
            let once = OnceFlag()
            let access = makeLock(
                fixture.container,
                inspectionBoundaryHook: { boundary in
                    guard case .afterRead = boundary, once.claim() else {
                        return
                    }
                    guard let handle = try? FileHandle(
                        forWritingTo: fixture.primary
                    ) else {
                        return
                    }
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data("!".utf8))
                }
            )
            try access.withLock { authority in
                XCTAssertEqual(
                    authority.readPrimary(),
                    .failure(.fileAccess(.changedDuringRead))
                )
            }
        }
    }

    func testPinnedSettingsAndLockSecurityRevalidateBeforeEveryRead()
        throws
    {
        do {
            let fixture = try makeFixture()
            try makeLock(fixture.container).withLock { authority in
                try chmod(fixture.settings, 0o755)
                XCTAssertEqual(
                    authority.readPrimary(),
                    .failure(
                        .lockValidation(
                            .unsafeItem(
                                item: .settingsDirectory,
                                reason: .incorrectMode(
                                    expected: 0o700,
                                    actual: 0o755
                                )
                            )
                        )
                    )
                )
            }
        }

        do {
            let fixture = try makeFixture()
            let lock = fixture.settings.appendingPathComponent(
                SettingsPrimaryMutationLock.lockName
            )
            try makeLock(fixture.container).withLock { authority in
                try chmod(lock, 0o644)
                XCTAssertEqual(
                    authority.readPrimary(),
                    .failure(
                        .lockValidation(
                            .unsafeItem(
                                item: .lock,
                                reason: .incorrectMode(
                                    expected: 0o600,
                                    actual: 0o644
                                )
                            )
                        )
                    )
                )
            }
        }
    }

    func testLeafACLModeLinkAndTypeDefensesMatchReader() throws {
        do {
            let fixture = try makeFixture()
            try writePrimary(Data("acl".utf8), fixture: fixture)
            try runChmod([
                "+a",
                "everyone allow read",
                fixture.primary.path,
            ])
            try makeLock(fixture.container).withLock { authority in
                assertFileFailure(
                    .unsafeItem(item: .primary, reason: .extendedACL),
                    authority.readPrimary()
                )
            }
        }

        do {
            let fixture = try makeFixture()
            try writePrimary(Data("mode".utf8), fixture: fixture)
            try chmod(fixture.primary, 0o644)
            try makeLock(fixture.container).withLock { authority in
                assertFileFailure(
                    .unsafeItem(item: .primary, reason: .permissiveMode),
                    authority.readPrimary()
                )
            }
        }

        do {
            let fixture = try makeFixture()
            try writePrimary(Data("link".utf8), fixture: fixture)
            try FileManager.default.linkItem(
                at: fixture.primary,
                to: fixture.settings.appendingPathComponent("linked.json")
            )
            try makeLock(fixture.container).withLock { authority in
                assertFileFailure(
                    .unsafeItem(item: .primary, reason: .multipleHardLinks),
                    authority.readPrimary()
                )
            }
        }

        do {
            let fixture = try makeFixture()
            try FileManager.default.createDirectory(
                at: fixture.primary,
                withIntermediateDirectories: false
            )
            try chmod(fixture.primary, 0o600)
            try makeLock(fixture.container).withLock { authority in
                assertFileFailure(
                    .unsafeItem(item: .primary, reason: .unsupportedType),
                    authority.readPrimary()
                )
            }
        }
    }

    func testExactFourMiBBoundShortReadAndEINTRRemainBounded() throws {
        let fixture = try makeFixture()
        let maximum = SettingsPrimaryFileAccess.maximumLockedInspectionBytes
        let exact = Data(repeating: 0x61, count: maximum)
        try writePrimary(exact, fixture: fixture)
        let directives = ReadDirectiveState([
            .failure(code: EINTR),
            .limit(3),
        ])
        try makeLock(
            fixture.container,
            inspectionReadChunkBytes: 4_097,
            inspectionReadHook: { _, _ in directives.next() }
        ).withLock { authority in
            XCTAssertEqual(authority.readPrimary(), .success(.bytes(exact)))
        }
        XCTAssertGreaterThan(directives.count, 2)

        try writePrimary(
            Data(repeating: 0x62, count: maximum + 1),
            fixture: fixture
        )
        try makeLock(fixture.container).withLock { authority in
            assertFileFailure(
                .inputTooLarge(
                    actual: UInt64(maximum + 1),
                    maximum: maximum
                ),
                authority.readPrimary()
            )
        }
    }

    func testLockedReadConsecutiveEINTRBudgetFailsClosed() throws {
        let fixture = try makeFixture()
        try writePrimary(Data("bounded".utf8), fixture: fixture)
        let directives = ReadDirectiveState([
            .failure(code: EINTR),
            .failure(code: EINTR),
            .failure(code: EINTR),
        ])

        try makeLock(
            fixture.container,
            inspectionMaximumConsecutiveInterruptedReads: 2,
            inspectionReadHook: { _, _ in directives.next() }
        ).withLock { authority in
            assertFileFailure(
                .systemCall(
                    operation: "read settings primary",
                    code: EINTR
                ),
                authority.readPrimary()
            )
        }
        XCTAssertEqual(directives.count, 3)
    }

    func testPinnedReaderValidatesMaximumAndParentFactsInternally()
        throws
    {
        do {
            let fixture = try makeFixture()
            let bytes = Data("parent".utf8)
            try writePrimary(bytes, fixture: fixture)
            let descriptor = try openDirectory(fixture.settings)
            defer { close(descriptor) }
            let expected = try descriptorMetadata(descriptor)
            let reader = SettingsPrimaryFileAccess(
                pinnedReadChunkBytes: 3
            )

            XCTAssertThrowsError(
                try reader.readPinnedThrowing(
                    parent: descriptor,
                    parentBefore: expected,
                    maximumBytes: -1,
                    parentPostflight: {}
                )
            ) { error in
                XCTAssertEqual(
                    error as? SettingsPrimaryFileAccessError,
                    .invalidMaximumBytes(-1)
                )
            }
            XCTAssertEqual(
                try reader.readPinnedThrowing(
                    parent: descriptor,
                    parentBefore: expected,
                    maximumBytes: Int.max,
                    parentPostflight: {}
                ),
                .bytes(bytes)
            )

            var forged = expected
            forged.inode &+= 1
            assertPinnedReadFailure(
                .changedDuringRead,
                reader: reader,
                descriptor: descriptor,
                expected: forged
            )

            var wrongOwner = expected
            wrongOwner.owner &+= 1
            assertPinnedReadFailure(
                .unsafeItem(item: .parent, reason: .wrongOwner),
                reader: reader,
                descriptor: descriptor,
                expected: wrongOwner
            )

            XCTAssertThrowsError(
                try reader.readPinnedThrowing(
                    parent: descriptor,
                    parentBefore: expected,
                    maximumBytes: Int.max
                ) {
                    throw InspectionFixtureError.postflight
                }
            ) { error in
                XCTAssertEqual(
                    error as? InspectionFixtureError,
                    .postflight
                )
            }
        }

        for unsafeMode: mode_t in [0o755, 0o1700] {
            let fixture = try makeFixture()
            try chmod(fixture.settings, unsafeMode)
            let descriptor = try openDirectory(fixture.settings)
            defer { close(descriptor) }
            let expected = try descriptorMetadata(descriptor)
            let reason: SettingsPrimaryFileUnsafeReason =
                unsafeMode == 0o755 ? .permissiveMode : .specialMode
            assertPinnedReadFailure(
                .unsafeItem(item: .parent, reason: reason),
                reader: SettingsPrimaryFileAccess(
                    pinnedReadChunkBytes: 64 * 1_024
                ),
                descriptor: descriptor,
                expected: expected
            )
        }

        do {
            let fixture = try makeFixture()
            let descriptor = try openDirectory(fixture.settings)
            defer { close(descriptor) }
            let expected = try descriptorMetadata(descriptor)
            try runChmod([
                "+a",
                "everyone allow read",
                fixture.settings.path,
            ])
            assertPinnedReadFailure(
                .unsafeItem(item: .parent, reason: .extendedACL),
                reader: SettingsPrimaryFileAccess(
                    pinnedReadChunkBytes: 64 * 1_024
                ),
                descriptor: descriptor,
                expected: expected
            )
        }

        do {
            let fixture = try makeFixture()
            try writePrimary(Data("not-directory".utf8), fixture: fixture)
            let descriptor = open(
                fixture.primary.path,
                O_RDONLY | O_NOFOLLOW | O_CLOEXEC
            )
            XCTAssertGreaterThanOrEqual(descriptor, 0)
            defer { close(descriptor) }
            let expected = try descriptorMetadata(descriptor)
            assertPinnedReadFailure(
                .unsafeItem(item: .parent, reason: .unsupportedType),
                reader: SettingsPrimaryFileAccess(
                    pinnedReadChunkBytes: 64 * 1_024
                ),
                descriptor: descriptor,
                expected: expected
            )
        }
    }

    func testInjectedReaderAndLockValidationFailuresAreTyped()
        throws
    {
        let readerCalls: [SettingsPrimarySystemCall] = [
            .inspectPinnedParentBeforeRead,
            .inspectPrimaryPath,
            .openPrimary,
            .inspectPrimary,
            .reinspectPrimary,
            .reinspectPrimaryPath,
            .inspectPinnedParentAfterRead,
        ]
        for call in readerCalls {
            let fixture = try makeFixture()
            try writePrimary(Data("injected".utf8), fixture: fixture)
            let access = makeLock(
                fixture.container,
                inspectionSystemCallHook: { $0 == call ? EIO : nil }
            )
            try access.withLock { authority in
                guard case .failure(.fileAccess(.systemCall(_, EIO))) =
                    authority.readPrimary()
                else {
                    return XCTFail("Expected reader failure for \(call)")
                }
            }
        }

        do {
            let fixture = try makeFixture()
            try writePrimary(Data("read".utf8), fixture: fixture)
            let access = makeLock(
                fixture.container,
                inspectionReadHook: { _, _ in .failure(code: EIO) }
            )
            try access.withLock { authority in
                assertFileFailure(
                    .systemCall(
                        operation: "read settings primary",
                        code: EIO
                    ),
                    authority.readPrimary()
                )
            }
        }

        do {
            let fixture = try makeFixture()
            try writePrimary(Data("acl".utf8), fixture: fixture)
            let access = makeLock(
                fixture.container,
                inspectionACLHook: { item, _ in
                    item == .primary ? .failure(code: EIO) : .system
                }
            )
            try access.withLock { authority in
                assertFileFailure(
                    .systemCall(
                        operation: "inspect settings primary ACL",
                        code: EIO
                    ),
                    authority.readPrimary()
                )
            }
        }

        do {
            let fixture = try makeFixture()
            let failure = NthLockCallFailure(
                call: .reopenContainer,
                occurrence: 2,
                code: EIO
            )
            let access = makeLock(
                fixture.container,
                systemCallHook: { failure.result(for: $0) }
            )
            try access.withLock { authority in
                XCTAssertEqual(
                    authority.readPrimary(),
                    .failure(
                        .lockValidation(
                            .systemCall(
                                .init(
                                    operation:
                                        "open trusted settings container",
                                    code: EIO
                                )
                            )
                        )
                    )
                )
            }
        }
    }

    func testAuthorityBodyAndCleanupFailurePrecedenceIsPreserved()
        throws
    {
        let fixture = try makeFixture()
        try writePrimary(Data("body".utf8), fixture: fixture)
        let access = makeLock(
            fixture.container,
            systemCallHook: { $0 == .unlock ? EIO : nil }
        )

        XCTAssertThrowsError(
            try access.withLock { authority in
                XCTAssertEqual(
                    authority.readPrimary(),
                    .success(.bytes(Data("body".utf8)))
                )
                throw InspectionFixtureError.body
            }
        ) { error in
            guard let combined =
                error as? SettingsPrimaryMutationLockPrimaryAndCleanupError
            else {
                return XCTFail("Expected combined failure, got \(error)")
            }
            XCTAssertEqual(
                combined.primary as? InspectionFixtureError,
                .body
            )
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
    }

    func testStandaloneAndLockedReaderResultsRemainIdentical() throws {
        let fixture = try makeFixture()
        let standalone = SettingsPrimaryFileAccess(
            settingsDirectoryURL: fixture.settings
        )
        let maximum = SettingsPrimaryFileAccess.maximumLockedInspectionBytes

        let standaloneMissing = standalone.read(maximumBytes: maximum)
        try makeLock(fixture.container).withLock { authority in
            XCTAssertEqual(
                authority.readPrimary().mapError(fileError),
                standaloneMissing
            )
        }

        let bytes = Data("parity".utf8)
        try writePrimary(bytes, fixture: fixture)
        let standaloneCurrent = standalone.read(maximumBytes: maximum)
        try makeLock(fixture.container).withLock { authority in
            XCTAssertEqual(
                authority.readPrimary().mapError(fileError),
                standaloneCurrent
            )
        }
    }

    private func fileError(
        _ error: SettingsPrimaryLockedInspectionError
    ) -> SettingsPrimaryFileAccessError {
        guard case .fileAccess(let fileError) = error else {
            return .systemCall(
                operation: "unexpected locked validation",
                code: EIO
            )
        }
        return fileError
    }

    private func assertFileFailure(
        _ expected: SettingsPrimaryFileAccessError,
        _ result: Result<
            SettingsPrimaryFileReadResult,
            SettingsPrimaryLockedInspectionError
        >,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            result,
            .failure(.fileAccess(expected)),
            file: file,
            line: line
        )
    }

    private func assertPinnedReadFailure(
        _ expectedError: SettingsPrimaryFileAccessError,
        reader: SettingsPrimaryFileAccess,
        descriptor: Int32,
        expected: SettingsPrimaryFileMetadata,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try reader.readPinnedThrowing(
                parent: descriptor,
                parentBefore: expected,
                maximumBytes: Int.max,
                parentPostflight: {}
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(
                error as? SettingsPrimaryFileAccessError,
                expectedError,
                file: file,
                line: line
            )
        }
    }

    private func openDirectory(_ url: URL) throws -> Int32 {
        let descriptor = open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        return descriptor
    }

    private func descriptorMetadata(
        _ descriptor: Int32
    ) throws -> SettingsPrimaryFileMetadata {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
        return SettingsPrimaryDescriptorSecurity.metadata(from: status)
    }

    private func openDescriptors() -> Set<Int32> {
        Set(
            (0 ..< 128).compactMap { candidate -> Int32? in
                fcntl(Int32(candidate), F_GETFD) >= 0
                    ? Int32(candidate)
                    : nil
            }
        )
    }

    private func makeLock(
        _ container: URL,
        systemCallHook:
            @escaping SettingsPrimaryMutationLock.SystemCallHook = {
                _ in nil
            },
        inspectionReadChunkBytes: Int = 64 * 1_024,
        inspectionMaximumConsecutiveInterruptedReads: Int =
            SettingsPrimaryFileAccess
                .defaultMaximumConsecutiveInterruptedReads,
        inspectionBoundaryHook:
            @escaping SettingsPrimaryFileAccess.BoundaryHook = { _ in },
        inspectionReadHook:
            @escaping SettingsPrimaryFileAccess.ReadHook = {
                _, _ in .system
            },
        inspectionACLHook:
            @escaping SettingsPrimaryFileAccess.ACLHook = {
                _, _ in .system
            },
        inspectionSystemCallHook:
            @escaping SettingsPrimaryFileAccess.SystemCallHook = {
                _ in nil
            }
    ) -> SettingsPrimaryMutationLock {
        SettingsPrimaryMutationLock(
            trustedContainerURL: container,
            systemCallHook: systemCallHook,
            stagingNameSource: { 1 },
            inspectionReadChunkBytes: inspectionReadChunkBytes,
            inspectionMaximumConsecutiveInterruptedReads:
                inspectionMaximumConsecutiveInterruptedReads,
            inspectionBoundaryHook: inspectionBoundaryHook,
            inspectionReadHook: inspectionReadHook,
            inspectionACLHook: inspectionACLHook,
            inspectionSystemCallHook: inspectionSystemCallHook
        )
    }

    private func makeFixture() throws -> InspectionFixture {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "px-locked-read-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        let container = root.appendingPathComponent(
            "container",
            isDirectory: true
        )
        let settings = container.appendingPathComponent(
            SettingsPrimaryMutationLock.settingsName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: settings,
            withIntermediateDirectories: true
        )
        try chmod(root, 0o700)
        try chmod(container, 0o700)
        try chmod(settings, 0o700)
        let lock = settings.appendingPathComponent(
            SettingsPrimaryMutationLock.lockName
        )
        XCTAssertTrue(
            FileManager.default.createFile(
                atPath: lock.path,
                contents: Data()
            )
        )
        try chmod(lock, 0o600)
        temporaryRoots.append(root)
        return InspectionFixture(
            root: root,
            container: container,
            settings: settings,
            primary: settings.appendingPathComponent(
                SettingsPrimaryFileAccess.primaryName
            )
        )
    }

    private func writePrimary(
        _ data: Data,
        fixture: InspectionFixture
    ) throws {
        try data.write(to: fixture.primary)
        try chmod(fixture.primary, 0o600)
    }

    private func chmod(_ url: URL, _ mode: mode_t) throws {
        guard Darwin.chmod(url.path, mode) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
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
}

private struct InspectionFixture: Sendable {
    let root: URL
    let container: URL
    let settings: URL
    let primary: URL
}

private enum InspectionFixtureError: Error, Equatable {
    case body
    case postflight
}

private final class OnceFlag: @unchecked Sendable {
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

private final class DescriptorReadState: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [Int32] = []

    var count: Int {
        lock.withLock { descriptors.count }
    }

    var firstDescriptor: Int32? {
        lock.withLock { descriptors.first }
    }

    func record(_ descriptor: Int32) {
        lock.withLock {
            descriptors.append(descriptor)
        }
    }
}

private final class InspectionResultBox: @unchecked Sendable {
    typealias StoredResult = Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    >

    private let lock = NSLock()
    private var stored: StoredResult?

    var result: StoredResult? {
        lock.withLock { stored }
    }

    func store(_ result: StoredResult) {
        lock.withLock {
            stored = result
        }
    }
}

private final class InspectionAuthorityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SettingsPrimaryLockedInspectionAuthority?

    var authority: SettingsPrimaryLockedInspectionAuthority? {
        lock.withLock { stored }
    }

    func store(_ authority: SettingsPrimaryLockedInspectionAuthority) {
        lock.withLock {
            stored = authority
        }
    }
}

private final class TransientCloseObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var baseline: Set<Int32> = []
    private var observed: Int32?
    private var storedCount = 0

    var transientDescriptor: Int32? {
        lock.withLock { observed }
    }

    var count: Int {
        lock.withLock { storedCount }
    }

    func setBaseline(_ descriptors: Set<Int32>) {
        lock.withLock {
            baseline = descriptors
        }
    }

    func observeAndFail() {
        let current = Set(
            (0 ..< 128).compactMap { candidate -> Int32? in
                fcntl(Int32(candidate), F_GETFD) >= 0
                    ? Int32(candidate)
                    : nil
            }
        )
        lock.withLock {
            storedCount += 1
            observed = current.subtracting(baseline).sorted().first
        }
    }
}

private final class CombinedValidationCloseFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var inspectCount = 0
    private var storedCloseCount = 0

    var closeCount: Int {
        lock.withLock { storedCloseCount }
    }

    func result(
        for call: SettingsPrimaryMutationLockSystemCall
    ) -> Int32? {
        lock.withLock {
            switch call {
            case .inspectReopenedContainer:
                inspectCount += 1
                return inspectCount == 2 ? EIO : nil
            case .closeAuthorityContainer:
                storedCloseCount += 1
                return EBADF
            default:
                return nil
            }
        }
    }
}

private final class ReadDirectiveState: @unchecked Sendable {
    private let lock = NSLock()
    private var directives: [SettingsPrimaryReadDirective]
    private var storedCount = 0

    init(_ directives: [SettingsPrimaryReadDirective]) {
        self.directives = directives
    }

    var count: Int {
        lock.withLock { storedCount }
    }

    func next() -> SettingsPrimaryReadDirective {
        lock.withLock {
            storedCount += 1
            guard !directives.isEmpty else {
                return .system
            }
            return directives.removeFirst()
        }
    }
}

private final class NthLockCallFailure: @unchecked Sendable {
    private let lock = NSLock()
    private let call: SettingsPrimaryMutationLockSystemCall
    private let occurrence: Int
    private let code: Int32
    private var count = 0

    init(
        call: SettingsPrimaryMutationLockSystemCall,
        occurrence: Int,
        code: Int32
    ) {
        self.call = call
        self.occurrence = occurrence
        self.code = code
    }

    func result(
        for candidate: SettingsPrimaryMutationLockSystemCall
    ) -> Int32? {
        lock.withLock {
            guard candidate == call else {
                return nil
            }
            count += 1
            return count == occurrence ? code : nil
        }
    }
}
