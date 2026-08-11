import Darwin
import Foundation
import XCTest
@testable import Parallax

final class SettingsPrimaryFileAccessTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories.reversed() {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    func testMissingParentAndLeafDoNotCreateAnything() throws {
        let root = try temporaryRoot()
        let absent = root.appendingPathComponent("Absent", isDirectory: true)
        XCTAssertEqual(reader(absent).read(maximumBytes: 10), .success(.missing))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))

        let settings = try settingsDirectory(in: root)
        let before = try directoryEntries(settings)
        XCTAssertEqual(reader(settings).read(maximumBytes: 10), .success(.missing))
        XCTAssertEqual(try directoryEntries(settings), before)
    }

    func testReadsExactBytesAndIsDeterministic() throws {
        let settings = try settingsDirectory(in: temporaryRoot())
        let bytes = Data("exact settings bytes\n".utf8)
        try writePrimary(bytes, in: settings)
        let access = reader(settings, chunk: 3)

        XCTAssertEqual(access.read(maximumBytes: 100), .success(.bytes(bytes)))
        XCTAssertEqual(access.read(maximumBytes: 100), .success(.bytes(bytes)))
        XCTAssertEqual(try Data(contentsOf: primary(in: settings)), bytes)
    }

    func testExactFourMiBFutureDocumentPassesAndPlusOneRejects()
        throws
    {
        let settings = try settingsDirectory(in: temporaryRoot())
        let prefix = Data(#"{"schemaVersion":2,"payload":""#.utf8)
        let suffix = Data(#""}"#.utf8)
        let payloadCount =
            SettingsRepository.maximumPrimaryBytes
            - prefix.count - suffix.count
        let exact = prefix
            + Data(repeating: 0x61, count: payloadCount)
            + suffix
        try writePrimary(exact, in: settings)

        let started = ContinuousClock.now
        let result = reader(settings).read(
            maximumBytes: SettingsRepository.maximumPrimaryBytes
        )
        let elapsed = started.duration(to: .now)
        XCTAssertEqual(result, .success(.bytes(exact)))
        XCTAssertLessThan(elapsed, .seconds(10))

        try FileHandle(forWritingTo: primary(in: settings))
            .seekToEndAndWrite(Data([0x20]))
        XCTAssertEqual(
            reader(settings).read(
                maximumBytes: SettingsRepository.maximumPrimaryBytes
            ),
            .failure(
                .inputTooLarge(
                    actual: UInt64(
                        SettingsRepository.maximumPrimaryBytes + 1
                    ),
                    maximum: SettingsRepository.maximumPrimaryBytes
                )
            )
        )
    }

    func testParentAndLeafModesAndOwnersFailClosed() throws {
        let root = try temporaryRoot()
        let settings = try settingsDirectory(in: root)
        try writePrimary(Data("{}".utf8), in: settings)

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: settings.path
        )
        XCTAssertEqual(
            reader(settings).read(maximumBytes: 100),
            .failure(
                .unsafeItem(item: .parent, reason: .permissiveMode)
            )
        )
        try chmod(settings, 0o700)

        try chmod(primary(in: settings), 0o644)
        XCTAssertEqual(
            reader(settings).read(maximumBytes: 100),
            .failure(
                .unsafeItem(item: .primary, reason: .permissiveMode)
            )
        )
        try chmod(primary(in: settings), 0o600)

        let wrongParent = reader(
            settings,
            metadataHook: { item, metadata in
                var changed = metadata
                if item == .parent { changed.owner &+= 1 }
                return changed
            }
        )
        XCTAssertEqual(
            wrongParent.read(maximumBytes: 100),
            .failure(.unsafeItem(item: .parent, reason: .wrongOwner))
        )
        let wrongLeaf = reader(
            settings,
            metadataHook: { item, metadata in
                var changed = metadata
                if item == .primary { changed.owner &+= 1 }
                return changed
            }
        )
        XCTAssertEqual(
            wrongLeaf.read(maximumBytes: 100),
            .failure(.unsafeItem(item: .primary, reason: .wrongOwner))
        )
    }

    func testParentTypeAndAccessFailureRemainUnavailable() throws {
        let root = try temporaryRoot()
        let fileParent = root.appendingPathComponent("NotDirectory")
        try Data("file".utf8).write(to: fileParent)
        try chmod(fileParent, 0o600)
        XCTAssertEqual(
            reader(fileParent).read(maximumBytes: 100),
            .failure(.unsafeItem(item: .parent, reason: .unsupportedType))
        )

        let settings = try settingsDirectory(in: root)
        try writePrimary(Data("{}".utf8), in: settings)
        try chmod(settings, 0o000)
        defer { _ = Darwin.chmod(settings.path, 0o700) }
        XCTAssertEqual(
            reader(settings).read(maximumBytes: 100),
            .failure(
                .systemCall(
                    operation: "open settings directory",
                    code: EACCES
                )
            )
        )
    }

    func testSymlinkHardLinkDirectoryFIFOAndSocketRejectWithoutBlocking()
        throws
    {
        let root = try temporaryRoot()

        do {
            let target = try settingsDirectory(in: root, name: "Target")
            let link = root.appendingPathComponent("Linked")
            try FileManager.default.createSymbolicLink(
                at: link,
                withDestinationURL: target
            )
            XCTAssertEqual(
                reader(link).read(maximumBytes: 100),
                .failure(.unsafeItem(item: .parent, reason: .symbolicLink))
            )
        }

        let settings = try settingsDirectory(in: root, name: "Settings")
        let external = root.appendingPathComponent("external")
        try Data("outside".utf8).write(to: external)
        try chmod(external, 0o600)
        try FileManager.default.createSymbolicLink(
            at: primary(in: settings),
            withDestinationURL: external
        )
        XCTAssertEqual(
            reader(settings).read(maximumBytes: 100),
            .failure(.unsafeItem(item: .primary, reason: .symbolicLink))
        )
        try FileManager.default.removeItem(at: primary(in: settings))
        try FileManager.default.createSymbolicLink(
            atPath: primary(in: settings).path,
            withDestinationPath: "absent-target"
        )
        XCTAssertEqual(
            reader(settings).read(maximumBytes: 100),
            .failure(.unsafeItem(item: .primary, reason: .symbolicLink))
        )
        try FileManager.default.removeItem(at: primary(in: settings))

        try FileManager.default.linkItem(
            at: external,
            to: primary(in: settings)
        )
        XCTAssertEqual(
            reader(settings).read(maximumBytes: 100),
            .failure(.unsafeItem(item: .primary, reason: .multipleHardLinks))
        )
        try FileManager.default.removeItem(at: primary(in: settings))

        try FileManager.default.createDirectory(
            at: primary(in: settings),
            withIntermediateDirectories: false
        )
        XCTAssertEqual(
            reader(settings).read(maximumBytes: 100),
            .failure(.unsafeItem(item: .primary, reason: .unsupportedType))
        )
        try FileManager.default.removeItem(at: primary(in: settings))

        XCTAssertEqual(mkfifo(primary(in: settings).path, 0o600), 0)
        XCTAssertEqual(
            reader(settings).read(maximumBytes: 100),
            .failure(.unsafeItem(item: .primary, reason: .unsupportedType))
        )
        try FileManager.default.removeItem(at: primary(in: settings))

        let socketDescriptor = try createUNIXSocket(at: primary(in: settings))
        defer { close(socketDescriptor) }
        XCTAssertEqual(
            reader(settings).read(maximumBytes: 100),
            .failure(.unsafeItem(item: .primary, reason: .unsupportedType))
        )
    }

    func testInjectedEINTRShortReadsAndSystemFailuresAreDeterministic()
        throws
    {
        let settings = try settingsDirectory(in: temporaryRoot())
        let bytes = Data("short-read-fixture".utf8)
        try writePrimary(bytes, in: settings)
        let state = DirectiveState()
        let access = reader(
            settings,
            chunk: 8,
            readHook: { _, _ in
                return state.next()
            }
        )
        state.directives = [
            .failure(code: EINTR),
            .limit(2),
            .limit(3),
        ]
        XCTAssertEqual(access.read(maximumBytes: 100), .success(.bytes(bytes)))
        XCTAssertGreaterThanOrEqual(state.callCount, 4)

        for code in [EIO, EMFILE] {
            let failing = reader(
                settings,
                readHook: { _, _ in .failure(code: code) }
            )
            XCTAssertEqual(
                failing.read(maximumBytes: 100),
                .failure(
                    .systemCall(
                        operation: "read settings primary",
                        code: code
                    )
                )
            )
        }
    }

    func testConsecutiveReadEINTRBudgetFailsClosed() throws {
        let settings = try settingsDirectory(in: temporaryRoot())
        try writePrimary(Data("bounded".utf8), in: settings)
        let state = DirectiveState()
        state.directives = [
            .failure(code: EINTR),
            .failure(code: EINTR),
            .failure(code: EINTR),
        ]
        let access = reader(
            settings,
            maximumConsecutiveInterruptedReads: 2,
            readHook: { _, _ in state.next() }
        )

        XCTAssertEqual(
            access.read(maximumBytes: 100),
            .failure(
                .systemCall(
                    operation: "read settings primary",
                    code: EINTR
                )
            )
        )
        XCTAssertEqual(state.callCount, 3)
    }

    func testGrowthMetadataMutationAndPathReplacementAreRejected()
        throws
    {
        let settings = try settingsDirectory(in: temporaryRoot())
        let original = Data(repeating: 0x61, count: 32)
        try writePrimary(original, in: settings)
        let primaryURL = primary(in: settings)

        let grew = MutationFlag()
        let growing = reader(
            settings,
            chunk: 4,
            hook: { boundary in
                if case .afterRead = boundary, grew.claim() {
                    let handle = try? FileHandle(
                        forWritingTo: primaryURL
                    )
                    handle?.seekToEndAndWrite(Data([0x62]))
                }
            }
        )
        XCTAssertEqual(
            growing.read(maximumBytes: 100),
            .failure(.changedDuringRead)
        )

        try writePrimary(original, in: settings, replace: true)
        let changedMetadata = MutationFlag()
        let metadataMutation = reader(
            settings,
            hook: { boundary in
                if boundary == .beforePostflight,
                   changedMetadata.claim()
                {
                    _ = Darwin.chmod(primaryURL.path, 0o400)
                }
            }
        )
        XCTAssertEqual(
            metadataMutation.read(maximumBytes: 100),
            .failure(.changedDuringRead)
        )

        try writePrimary(original, in: settings, replace: true)
        let replaced = MutationFlag()
        let replacement = Data("replacement".utf8)
        let pathSwap = reader(
            settings,
            hook: { boundary in
                if boundary == .beforeFinalPathValidation,
                   replaced.claim()
                {
                    let old = settings.appendingPathComponent("old")
                    try? FileManager.default.moveItem(
                        at: primaryURL,
                        to: old
                    )
                    try? replacement.write(to: primaryURL)
                    _ = Darwin.chmod(primaryURL.path, 0o600)
                }
            }
        )
        XCTAssertEqual(
            pathSwap.read(maximumBytes: 100),
            .failure(.changedDuringRead)
        )
    }

    func testMidReadFailureAndSyntheticTypeChecksFailClosed() throws {
        let settings = try settingsDirectory(in: temporaryRoot())
        try writePrimary(Data(repeating: 0x61, count: 64), in: settings)
        let failed = MutationFlag()
        let midRead = reader(
            settings,
            chunk: 8,
            readHook: { _, _ in
                if failed.claim() {
                    return .limit(8)
                }
                return .failure(code: EIO)
            }
        )
        XCTAssertEqual(
            midRead.read(maximumBytes: 100),
            .failure(
                .systemCall(
                    operation: "read settings primary",
                    code: EIO
                )
            )
        )

        let syntheticSocket = reader(
            settings,
            metadataHook: { item, metadata in
                var changed = metadata
                if item == .primary { changed.kind = .other }
                return changed
            }
        )
        XCTAssertEqual(
            syntheticSocket.read(maximumBytes: 100),
            .failure(.unsafeItem(item: .primary, reason: .unsupportedType))
        )
    }

    func testNegativeAndExtremeMaximumsAreTotalAndOverflowSafe() throws {
        let root = try temporaryRoot()
        let absent = root.appendingPathComponent("Absent", isDirectory: true)
        for invalid in [-1, Int.min] {
            XCTAssertEqual(
                reader(absent).read(maximumBytes: invalid),
                .failure(.invalidMaximumBytes(invalid))
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))

        let settings = try settingsDirectory(in: root)
        let bytes = Data("small".utf8)
        try writePrimary(bytes, in: settings)
        XCTAssertEqual(
            reader(settings, chunk: 3).read(maximumBytes: Int.max),
            .success(.bytes(bytes))
        )
    }

    func testSpecialModeBitsArePreservedAndRejectedExactly() throws {
        let settings = try settingsDirectory(in: temporaryRoot())
        try writePrimary(Data("{}".utf8), in: settings)
        for mode: mode_t in [0o1700, 0o2700, 0o4700] {
            try chmod(settings, mode)
            XCTAssertEqual(
                reader(settings).read(maximumBytes: 100),
                .failure(.unsafeItem(item: .parent, reason: .specialMode))
            )
            try chmod(settings, 0o700)
        }
        for mode: mode_t in [0o1600, 0o2600, 0o4600] {
            try chmod(primary(in: settings), mode)
            XCTAssertEqual(
                reader(settings).read(maximumBytes: 100),
                .failure(.unsafeItem(item: .primary, reason: .specialMode))
            )
            try chmod(primary(in: settings), 0o600)
        }
    }

    func testRealParentAndLeafExtendedACLsAreRejected() throws {
        let settings = try settingsDirectory(in: temporaryRoot())
        try writePrimary(Data("{}".utf8), in: settings)

        try setExtendedACL(on: settings)
        defer { try? removeExtendedACL(from: settings) }
        XCTAssertEqual(
            reader(settings).read(maximumBytes: 100),
            .failure(.unsafeItem(item: .parent, reason: .extendedACL))
        )
        try removeExtendedACL(from: settings)

        let primaryURL = primary(in: settings)
        try setExtendedACL(on: primaryURL)
        defer { try? removeExtendedACL(from: primaryURL) }
        XCTAssertEqual(
            reader(settings).read(maximumBytes: 100),
            .failure(.unsafeItem(item: .primary, reason: .extendedACL))
        )
    }

    func testACLFailuresAndPostOpenChangesFailClosed() throws {
        let settings = try settingsDirectory(in: temporaryRoot())
        try writePrimary(Data("{}".utf8), in: settings)

        XCTAssertEqual(
            reader(
                settings,
                aclHook: { item, _ in
                    item == .parent
                        ? .failure(code: EIO)
                        : .absent
                }
            ).read(maximumBytes: 100),
            .failure(
                .systemCall(
                    operation: "inspect settings directory ACL",
                    code: EIO
                )
            )
        )

        let leafACL = ACLDirectiveState(
            item: .primary,
            directives: [.absent, .present]
        )
        XCTAssertEqual(
            reader(
                settings,
                aclHook: { item, _ in leafACL.next(for: item) }
            ).read(maximumBytes: 100),
            .failure(.unsafeItem(item: .primary, reason: .extendedACL))
        )

        let parentACL = ACLDirectiveState(
            item: .parent,
            directives: [.absent, .present]
        )
        XCTAssertEqual(
            reader(
                settings,
                aclHook: { item, _ in parentACL.next(for: item) }
            ).read(maximumBytes: 100),
            .failure(.unsafeItem(item: .parent, reason: .extendedACL))
        )
    }

    func testInjectedOpenFstatatAndFstatFailuresUseTypedBranches()
        throws
    {
        let settings = try settingsDirectory(in: temporaryRoot())
        try writePrimary(Data("{}".utf8), in: settings)
        let cases: [
            (
                SettingsPrimarySystemCall,
                String,
                Int32
            )
        ] = [
            (.openParent, "open settings directory", EIO),
            (.inspectParent, "inspect settings directory", EBADF),
            (.inspectPrimaryPath, "inspect settings primary", EIO),
            (.openPrimary, "open settings primary", EMFILE),
            (
                .inspectPrimary,
                "inspect opened settings primary",
                EBADF
            ),
            (.reinspectPrimary, "reinspect settings primary", EIO),
            (
                .reinspectPrimaryPath,
                "reinspect settings primary path",
                EIO
            ),
        ]
        for (call, operation, code) in cases {
            XCTAssertEqual(
                reader(
                    settings,
                    systemCallHook: { $0 == call ? code : nil }
                ).read(maximumBytes: 100),
                .failure(
                    .systemCall(operation: operation, code: code)
                )
            )
        }
    }

    private func temporaryRoot() throws -> URL {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("px-\(suffix)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        temporaryDirectories.append(url)
        return url
    }

    private func settingsDirectory(
        in root: URL,
        name: String = "Settings"
    ) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        try chmod(url, 0o700)
        return url
    }

    private func primary(in settings: URL) -> URL {
        settings.appendingPathComponent(
            SettingsPrimaryFileAccess.primaryName,
            isDirectory: false
        )
    }

    private func writePrimary(
        _ data: Data,
        in settings: URL,
        replace: Bool = false
    ) throws {
        let url = primary(in: settings)
        if replace, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try data.write(to: url, options: .withoutOverwriting)
        try chmod(url, 0o600)
    }

    private func reader(
        _ settings: URL,
        chunk: Int = 64 * 1_024,
        maximumConsecutiveInterruptedReads: Int =
            SettingsPrimaryFileAccess
                .defaultMaximumConsecutiveInterruptedReads,
        hook: @escaping SettingsPrimaryFileAccess.BoundaryHook = { _ in },
        readHook: @escaping SettingsPrimaryFileAccess.ReadHook = {
            _, _ in .system
        },
        metadataHook: @escaping SettingsPrimaryFileAccess.MetadataHook = {
            _, metadata in metadata
        },
        aclHook: @escaping SettingsPrimaryFileAccess.ACLHook = {
            _, _ in .system
        },
        systemCallHook: @escaping SettingsPrimaryFileAccess.SystemCallHook = {
            _ in nil
        }
    ) -> SettingsPrimaryFileAccess {
        SettingsPrimaryFileAccess(
            settingsDirectoryURL: settings,
            readChunkBytes: chunk,
            maximumConsecutiveInterruptedReads:
                maximumConsecutiveInterruptedReads,
            boundaryHook: hook,
            readHook: readHook,
            metadataHook: metadataHook,
            aclHook: aclHook,
            systemCallHook: systemCallHook
        )
    }

    private func chmod(_ url: URL, _ mode: mode_t) throws {
        try POSIXTestSupport.chmod(url, mode)
    }

    private func directoryEntries(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    private func setExtendedACL(on url: URL) throws {
        try runChmod(["+a", "everyone allow read", url.path])
    }

    private func removeExtendedACL(from url: URL) throws {
        try runChmod(["-N", url.path])
    }

    private func runChmod(_ arguments: [String]) throws {
        try POSIXTestSupport.runChmod(arguments)
    }

    private func createUNIXSocket(at url: URL) throws -> Int32 {
        try POSIXTestSupport.createUNIXSocket(at: url)
    }
}

private final class DirectiveState: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SettingsPrimaryReadDirective] = []
    private var storedCallCount = 0

    var directives: [SettingsPrimaryReadDirective] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var callCount: Int {
        lock.withLock { storedCallCount }
    }

    func next() -> SettingsPrimaryReadDirective {
        lock.withLock {
            storedCallCount += 1
            guard !stored.isEmpty else { return .system }
            return stored.removeFirst()
        }
    }
}

private final class ACLDirectiveState: @unchecked Sendable {
    private let lock = NSLock()
    private let item: SettingsPrimaryFileItem
    private var directives: [SettingsPrimaryACLDirective]

    init(
        item: SettingsPrimaryFileItem,
        directives: [SettingsPrimaryACLDirective]
    ) {
        self.item = item
        self.directives = directives
    }

    func next(
        for candidate: SettingsPrimaryFileItem
    ) -> SettingsPrimaryACLDirective {
        lock.withLock {
            guard candidate == item else { return .absent }
            guard !directives.isEmpty else { return .absent }
            return directives.removeFirst()
        }
    }
}

private final class MutationFlag: @unchecked Sendable {
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

private extension FileHandle {
    func seekToEndAndWrite(_ data: Data) {
        seekToEndOfFile()
        write(data)
        closeFile()
    }
}
