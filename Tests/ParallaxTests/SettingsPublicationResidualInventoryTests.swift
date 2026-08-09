import Darwin
import Foundation
import XCTest
@testable import Parallax

final class SettingsPublicationResidualInventoryTests: XCTestCase {
    private var roots: [URL] = []

    override func tearDownWithError() throws {
        for root in roots.reversed() {
            try? FileManager.default.removeItem(at: root)
        }
        roots = []
    }

    func testCleanScanIgnoresUnrelatedEntriesAndPerformsNoMutation()
        throws
    {
        let root = try fixture()
        let unrelated = settings(root).appendingPathComponent("ordinary")
        try write(Data("unchanged".utf8), to: unrelated, mode: 0o640)
        let before = try directoryFacts(settings(root))

        let snapshot = try inventory(root)

        XCTAssertEqual(snapshot.completion, .complete)
        XCTAssertEqual(snapshot.entries, [])
        XCTAssertEqual(snapshot.retainedByteCount, 0)
        XCTAssertEqual(try directoryFacts(settings(root)), before)
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("unchanged".utf8))
        XCTAssertEqual(mode(unrelated), 0o640)
    }

    func testRetainsExactCurrentFutureAndCorruptFactsInRawByteOrder()
        throws
    {
        let root = try fixture()
        let current = try SettingsDocumentCodec().encode(document(revision: 7))
        let future = Data(#"{"schemaVersion":2,"future":true}"#.utf8)
        let corrupt = Data(#"{"schemaVersion":1}"#.utf8)
        try plant(current, name: canonical("b"), in: root)
        try plant(future, name: canonical("a"), in: root)
        try plant(corrupt, name: canonical("c"), in: root)

        let snapshot = try inventory(root)

        XCTAssertEqual(snapshot.completion, .complete)
        XCTAssertEqual(
            snapshot.entries.map(\.rawName),
            [canonical("a"), canonical("b"), canonical("c")]
        )
        assertRetained(
            snapshot.entries[0],
            bytes: future,
            content: .future(schemaVersion: 2)
        )
        guard case .retained(
            let bytes,
            let sha,
            .current(let token)
        ) = snapshot.entries[1].observation else {
            return XCTFail("Expected current residual facts.")
        }
        XCTAssertEqual(bytes, current)
        XCTAssertEqual(sha, SettingsSourceSHA256(current))
        XCTAssertEqual(token.revision.rawValue, 7)
        XCTAssertEqual(token.sourceSHA256, sha)
        guard case .retained(
            let bytes,
            let sha,
            .corrupt
        ) = snapshot.entries[2].observation else {
            return XCTFail("Expected corrupt residual facts.")
        }
        XCTAssertEqual(bytes, corrupt)
        XCTAssertEqual(sha, SettingsSourceSHA256(corrupt))
    }

    func testRawInvalidUTF8AndMalformedReservedNamesRemainVisible()
        throws
    {
        let root = try fixture()
        let prefix = [UInt8](
            SettingsPublicationResidualNaming.prefixBytes
        )
        let invalidUTF8 = Data(prefix + [0xff])
        let uppercase = Data(prefix + Array("A".utf8))
        let emptySuffix = Data(prefix)
        let tooLong = Data(prefix + Array(repeating: UInt8(ascii: "a"), count: 17))
        let placeholder = canonical("f")
        for name in [placeholder, uppercase, emptySuffix, tooLong] {
            try plantRaw(Data([0xff]), name: name, in: root)
        }

        let scanner = SettingsPublicationResidualInventory(
            directoryEntryHook: { name in
                name == placeholder ? invalidUTF8 : name
            }
        )
        let snapshot = try inventory(root, scanner: scanner)

        XCTAssertEqual(snapshot.entries.count, 4)
        XCTAssertEqual(
            snapshot.entries.map(\.rawName),
            [emptySuffix, uppercase, tooLong, invalidUTF8].sorted {
                $0.lexicographicallyPrecedes($1)
            }
        )
        XCTAssertTrue(snapshot.entries.allSatisfy {
            $0.nameValidity == .malformedReservedName
        })
        XCTAssertTrue(snapshot.entries.dropLast().allSatisfy {
            if case .retained = $0.observation { return true }
            return false
        })
        guard case .unavailable(.systemCall) =
            snapshot.entries.last?.observation
        else {
            return XCTFail("Invalid UTF-8 raw name must remain typed.")
        }
    }

    func testGenuineAndPlantedByteIdenticalCanonicalArtifactsAreIndistinguishable()
        throws
    {
        let root = try fixture(includeLock: true)
        let source = Counter()
        let writer = SettingsRepositoryWriter(
            mutationLock: makeLock(
                root,
                publicationNameSource: {
                    UInt64(source.increment())
                }
            )
        )
        guard case .committed(let first, _) = writer.commit(
            content(appearance: "dark"),
            expecting: .missing
        ) else {
            return XCTFail("Expected initial publication.")
        }
        guard case .committed(_, .displacedPrior(let genuineName, _)) =
            writer.commit(
                content(appearance: "light"),
                expecting: .version(first.versionToken)
            )
        else {
            return XCTFail("Expected current publication residual.")
        }
        let plantedName = SettingsPublicationResidualNaming.generatedName(0xff)
        try plant(
            first.originalBytes,
            name: Data(plantedName.utf8),
            in: root
        )

        let snapshot = try authorityInventory(root)
        let relevant = snapshot.entries.filter {
            $0.rawName == Data(genuineName.utf8)
                || $0.rawName == Data(plantedName.utf8)
        }

        XCTAssertEqual(relevant.count, 2)
        XCTAssertEqual(relevant[0].nameValidity, .canonical)
        XCTAssertEqual(relevant[1].nameValidity, .canonical)
        XCTAssertEqual(relevant[0].observation, relevant[1].observation)
    }

    func testPrimaryByteEqualityDoesNotStrengthenObservedFacts() throws {
        let equalRoot = try fixture()
        let absentRoot = try fixture()
        let bytes = try SettingsDocumentCodec().encode(document(revision: 11))
        let name = canonical("a")
        try write(
            bytes,
            to: settings(equalRoot).appendingPathComponent(
                SettingsPrimaryFileAccess.primaryName
            )
        )
        try plant(bytes, name: name, in: equalRoot)
        try plant(bytes, name: name, in: absentRoot)

        let equalObservation = try inventory(equalRoot).entries.first?
            .observation
        let absentObservation = try inventory(absentRoot).entries.first?
            .observation

        XCTAssertEqual(equalObservation, absentObservation)
        guard case .retained(_, _, .current) = equalObservation else {
            return XCTFail("Expected content facts without provenance.")
        }
    }

    func testUnsafeTypesLinksModesAndACLsAreTypedAndPreserved()
        throws
    {
        let root = try fixture()
        let safe = settings(root).appendingPathComponent(
            SettingsPublicationResidualNaming.generatedName(1)
        )
        try write(Data("safe".utf8), to: safe)
        let hard = settings(root).appendingPathComponent(
            SettingsPublicationResidualNaming.generatedName(2)
        )
        XCTAssertEqual(link(safe.path, hard.path), 0)
        let permissive = settings(root).appendingPathComponent(
            SettingsPublicationResidualNaming.generatedName(3)
        )
        try write(Data(), to: permissive, mode: 0o644)
        let directory = settings(root).appendingPathComponent(
            SettingsPublicationResidualNaming.generatedName(4),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let symlink = settings(root).appendingPathComponent(
            SettingsPublicationResidualNaming.generatedName(5)
        )
        XCTAssertEqual(Darwin.symlink("ordinary", symlink.path), 0)
        let fifo = settings(root).appendingPathComponent(
            SettingsPublicationResidualNaming.generatedName(6)
        )
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)

        let realACLName = canonical("7")
        let realACL = rawURL(realACLName, in: root)
        try plant(Data(), name: realACLName, in: root)
        try setExtendedACL(on: realACL)
        defer { try? removeExtendedACL(from: realACL) }
        let injectedACLName = canonical("8")
        try plant(Data(), name: injectedACLName, in: root)
        let socketURL = rawURL(canonical("9"), in: root)
        let socketDescriptor = try createUNIXSocket(at: socketURL)
        defer { _ = close(socketDescriptor) }
        let scanner = SettingsPublicationResidualInventory(
            aclHook: { name, _ in
                name == injectedACLName ? .present : .system
            }
        )
        let snapshot = try inventory(root, scanner: scanner)

        XCTAssertEqual(snapshot.entries.count, 9)
        assertUnsafe(snapshot, name: canonical("1"), .multipleHardLinks)
        assertUnsafe(snapshot, name: canonical("2"), .multipleHardLinks)
        assertUnsafe(
            snapshot,
            name: canonical("3"),
            .incorrectMode(actual: 0o644)
        )
        assertUnsafe(snapshot, name: canonical("4"), .unsupportedType)
        assertUnsafe(snapshot, name: canonical("5"), .symbolicLink)
        assertUnsafe(snapshot, name: canonical("6"), .unsupportedType)
        assertUnsafe(snapshot, name: realACLName, .extendedACL)
        assertUnsafe(snapshot, name: injectedACLName, .extendedACL)
        assertUnsafe(snapshot, name: canonical("9"), .unsupportedType)
        XCTAssertTrue(FileManager.default.fileExists(atPath: safe.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hard.path))
        var symlinkStatus = stat()
        XCTAssertEqual(lstat(symlink.path, &symlinkStatus), 0)
    }

    func testMetadataInjectionReportsWrongOwnerAndSpecialMode() throws {
        let root = try fixture()
        try plant(Data(), name: canonical("1"), in: root)
        try plant(Data(), name: canonical("2"), in: root)
        let wrongOwnerName = canonical("1")
        let specialModeName = canonical("2")
        let scanner = SettingsPublicationResidualInventory(
            metadataHook: { call, name, metadata in
                guard call == .inspectEntryPathBefore else {
                    return metadata
                }
                var changed = metadata
                if name == wrongOwnerName {
                    changed.owner &+= 1
                } else if name == specialModeName {
                    changed.mode = 0o4600
                }
                return changed
            }
        )

        let snapshot = try inventory(root, scanner: scanner)

        assertUnsafe(snapshot, name: canonical("1"), .wrongOwner)
        assertUnsafe(
            snapshot,
            name: canonical("2"),
            .incorrectMode(actual: 0o4600)
        )
    }

    func testPerEntryAndAggregateByteLimitsAreExact() throws {
        let oversizedRoot = try fixture()
        let oversized = settings(oversizedRoot).appendingPathComponent(
            SettingsPublicationResidualNaming.generatedName(1)
        )
        try write(Data(), to: oversized)
        let descriptor = open(oversized.path, O_WRONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(
            ftruncate(
                descriptor,
                off_t(
                    SettingsPublicationResidualInventory.maximumEntryBytes + 1
                )
            ),
            0
        )
        XCTAssertEqual(close(descriptor), 0)

        let oversizedSnapshot = try inventory(oversizedRoot)
        guard case .unavailable(
            .inputTooLarge(let actual, let maximum)
        ) = oversizedSnapshot.entries.first?.observation else {
            return XCTFail("Expected per-entry limit.")
        }
        XCTAssertEqual(
            actual,
            UInt64(
                SettingsPublicationResidualInventory.maximumEntryBytes + 1
            )
        )
        XCTAssertEqual(
            maximum,
            SettingsPublicationResidualInventory.maximumEntryBytes
        )

        let aggregateRoot = try fixture()
        let chunk = Data(
            repeating: 0x41,
            count: SettingsPublicationResidualInventory.maximumEntryBytes
        )
        for value in 1 ... 4 {
            try plant(
                chunk,
                name: canonical(String(value)),
                in: aggregateRoot
            )
        }
        try plant(Data([0x41]), name: canonical("5"), in: aggregateRoot)
        let aggregate = try inventory(aggregateRoot)
        XCTAssertEqual(
            aggregate.retainedByteCount,
            SettingsPublicationResidualInventory.maximumAggregateBytes
        )
        guard case .unavailable(.aggregateByteLimit) =
            aggregate.entries.last?.observation
        else {
            return XCTFail("Expected aggregate byte limit.")
        }
    }

    func testDirectoryAndReservedEntryBoundsReportPartialEvidence()
        throws
    {
        let reservedRoot = try fixture()
        for value in 0 ... SettingsPublicationResidualInventory
            .maximumReservedEntries
        {
            try plant(
                Data(),
                name: canonical(String(value, radix: 16)),
                in: reservedRoot
            )
        }
        let reserved = try inventory(reservedRoot)
        XCTAssertEqual(
            reserved.entries.count,
            SettingsPublicationResidualInventory.maximumReservedEntries
        )
        assertPartial(
            reserved,
            contains: .reservedEntryLimit(
                actual:
                    SettingsPublicationResidualInventory
                        .maximumReservedEntries + 1,
                maximum:
                    SettingsPublicationResidualInventory
                        .maximumReservedEntries
            )
        )

        let directoryRoot = try fixture()
        for value in 0 ... SettingsPublicationResidualInventory
            .maximumDirectoryEntries
        {
            let url = settings(directoryRoot)
                .appendingPathComponent("ordinary-\(value)")
            try write(Data(), to: url)
        }
        let directory = try inventory(directoryRoot)
        XCTAssertEqual(
            directory.scannedDirectoryEntryCount,
            SettingsPublicationResidualInventory.maximumDirectoryEntries
        )
        XCTAssertEqual(directory.entries, [])
        assertPartial(
            directory,
            contains: .directoryEntryLimit(
                maximum:
                    SettingsPublicationResidualInventory
                        .maximumDirectoryEntries
            )
        )
    }

    func testShortReadsAndEINTRRetainExactBytes() throws {
        let root = try fixture()
        let bytes = Data(#"{"schemaVersion":2}"#.utf8)
        let name = canonical("1")
        try plant(bytes, name: name, in: root)
        let calls = Counter()
        let scanner = SettingsPublicationResidualInventory(
            readHook: { _, _, _ in
                switch calls.increment() {
                case 1:
                    return .failure(EINTR)
                case 2 ... 5:
                    return .limit(1)
                default:
                    return .system
                }
            }
        )

        let snapshot = try inventory(root, scanner: scanner)

        assertRetained(
            try XCTUnwrap(snapshot.entries.first),
            bytes: bytes,
            content: .future(schemaVersion: 2)
        )
    }

    func testContentAndTrailingReadEINTRBudgetsAreExact() throws {
        let root = try fixture()
        let bytes = Data(#"{"schemaVersion":2}"#.utf8)
        try plant(bytes, name: canonical("1"), in: root)

        let content64 = Counter()
        let contentAtLimit = try inventory(
            root,
            scanner: .init(readHook: { _, _, _ in
                content64.increment() <= 64
                    ? .failure(EINTR)
                    : .system
            })
        )
        guard case .retained = contentAtLimit.entries.first?.observation
        else {
            return XCTFail("Exactly 64 content EINTRs must succeed.")
        }

        let content65 = Counter()
        let contentOverLimit = try inventory(
            root,
            scanner: .init(readHook: { _, _, _ in
                content65.increment() <= 65
                    ? .failure(EINTR)
                    : .system
            })
        )
        XCTAssertEqual(
            contentOverLimit.entries.first?.observation,
            .unavailable(
                .systemCall(
                    .init(operation: "read residual entry", code: EIO)
                )
            )
        )
        XCTAssertEqual(content65.value, 65)

        let trailing64 = Counter()
        let trailingAtLimit = try inventory(
            root,
            scanner: .init(trailingReadHook: { _, _, _ in
                trailing64.increment() <= 64
                    ? .failure(EINTR)
                    : .system
            })
        )
        guard case .retained = trailingAtLimit.entries.first?.observation
        else {
            return XCTFail("Exactly 64 trailing EINTRs must succeed.")
        }

        let trailing65 = Counter()
        let trailingOverLimit = try inventory(
            root,
            scanner: .init(trailingReadHook: { _, _, _ in
                trailing65.increment() <= 65
                    ? .failure(EINTR)
                    : .system
            })
        )
        XCTAssertEqual(
            trailingOverLimit.entries.first?.observation,
            .unavailable(
                .systemCall(
                    .init(
                        operation: "verify residual entry bound",
                        code: EIO
                    )
                )
            )
        )
        XCTAssertEqual(trailing65.value, 65)
    }

    func testPathReplacementAndGrowthAreReportedWithoutNormalization()
        throws
    {
        let replacementRoot = try fixture()
        let replacementName = canonical("1")
        try plant(Data("first".utf8), name: replacementName, in: replacementRoot)
        let replacementURL = rawURL(replacementName, in: replacementRoot)
        let replacement = SettingsPublicationResidualInventory(
            boundaryHook: { boundary in
                guard case .beforeEntryPostflight(replacementName) =
                    boundary
                else { return }
                try? FileManager.default.removeItem(at: replacementURL)
                try? Data("second".utf8).write(to: replacementURL)
                _ = Darwin.chmod(replacementURL.path, 0o600)
            }
        )
        let replaced = try inventory(replacementRoot, scanner: replacement)
        XCTAssertEqual(
            replaced.entries.first?.observation,
            .unavailable(.changedDuringRead)
        )

        let disappearedRoot = try fixture()
        let disappearedName = canonical("2")
        try plant(Data("gone".utf8), name: disappearedName, in: disappearedRoot)
        let disappearedURL = rawURL(disappearedName, in: disappearedRoot)
        let disappearance = SettingsPublicationResidualInventory(
            boundaryHook: { boundary in
                guard case .beforeEntryOpen(disappearedName) = boundary
                else { return }
                try? FileManager.default.removeItem(at: disappearedURL)
            }
        )
        let disappeared = try inventory(
            disappearedRoot,
            scanner: disappearance
        )
        guard case .unavailable(.systemCall(let failure)) =
            disappeared.entries.first?.observation
        else {
            return XCTFail("Expected typed disappearance evidence.")
        }
        XCTAssertEqual(failure.code, ENOENT)

        let growthRoot = try fixture()
        let growthName = canonical("3")
        try plant(Data("a".utf8), name: growthName, in: growthRoot)
        let growthURL = rawURL(growthName, in: growthRoot)
        let growth = SettingsPublicationResidualInventory(
            boundaryHook: { boundary in
                guard case .beforeEntryPostflight(growthName) =
                    boundary
                else { return }
                guard let handle = try? FileHandle(forWritingTo: growthURL)
                else { return }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data("b".utf8))
                try? handle.close()
            }
        )
        let grown = try inventory(growthRoot, scanner: growth)
        XCTAssertEqual(
            grown.entries.first?.observation,
            .unavailable(.changedDuringRead)
        )
    }

    func testSystemEnumerationReadACLAndCloseFailuresRemainTyped()
        throws
    {
        let root = try fixture()
        let name = canonical("1")
        try plant(Data("x".utf8), name: name, in: root)

        let streamOpen = try inventory(
            root,
            scanner: .init(systemCallHook: { call, _ in
                call == .openDirectoryStream ? EIO : nil
            })
        )
        assertPartial(
            streamOpen,
            contains: .directorySystemCall(
                .init(
                    operation: "open residual inventory directory stream",
                    code: EIO
                )
            )
        )

        let enumeration = try inventory(
            root,
            scanner: .init(systemCallHook: { call, _ in
                call == .readDirectory ? EIO : nil
            })
        )
        assertPartial(
            enumeration,
            contains: .directorySystemCall(
                .init(
                    operation: "read residual inventory directory",
                    code: EIO
                )
            )
        )

        let changedURL = settings(root).appendingPathComponent("appeared")
        let directoryRace = try inventory(
            root,
            scanner: .init(boundaryHook: { boundary in
                guard boundary == .afterDirectoryEnumeration else { return }
                _ = FileManager.default.createFile(
                    atPath: changedURL.path,
                    contents: Data()
                )
            })
        )
        assertPartial(directoryRace, contains: .directoryChangedDuringScan)

        let read = try inventory(
            root,
            scanner: .init(readHook: { _, _, _ in .failure(EIO) })
        )
        XCTAssertEqual(
            read.entries.first?.observation,
            .unavailable(
                .systemCall(
                    .init(operation: "read residual entry", code: EIO)
                )
            )
        )

        let acl = try inventory(
            root,
            scanner: .init(aclHook: { _, _ in .failure(code: EIO) })
        )
        XCTAssertEqual(
            acl.entries.first?.observation,
            .unavailable(
                .systemCall(
                    .init(
                        operation: "inspect residual entry ACL",
                        code: EIO
                    )
                )
            )
        )

        let closed = try inventory(
            root,
            scanner: .init(systemCallHook: { call, _ in
                switch call {
                case .closeEntry:
                    return EBADF
                case .closeDirectory:
                    return EIO
                default:
                    return nil
                }
            })
        )
        XCTAssertEqual(closed.closeFailures.count, 2)
        guard case .partial(let reasons) = closed.completion else {
            return XCTFail("Expected close-failure partial inventory.")
        }
        XCTAssertEqual(
            reasons.filter {
                if case .closeFailure = $0 { return true }
                return false
            }.count,
            2
        )
    }

    func testFDOpenDirFailureReallyClosesItsDescriptorExactlyOnce()
        throws
    {
        let root = try fixture()
        let descriptors = DescriptorEvents()
        let closeCalls = Counter()
        let scanner = SettingsPublicationResidualInventory(
            systemCallHook: { call, _ in
                switch call {
                case .createDirectoryStream:
                    return EIO
                case .closeDirectory:
                    _ = closeCalls.increment()
                    return nil
                default:
                    return nil
                }
            },
            boundaryHook: { boundary in
                if case .afterDirectoryStreamOpen(let descriptor) = boundary {
                    descriptors.append(descriptor)
                }
            }
        )
        let pinned = open(
            settings(root).path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard pinned >= 0 else { throw POSIXError(.EIO) }
        defer { _ = close(pinned) }

        let snapshot = scanner.inspect(settingsDescriptor: pinned)

        assertPartial(
            snapshot,
            contains: .directorySystemCall(
                .init(
                    operation: "create residual inventory directory stream",
                    code: EIO
                )
            )
        )
        XCTAssertEqual(closeCalls.value, 1)
        try assertClosedAndReusable(try XCTUnwrap(descriptors.values.first))
    }

    func testCloseEvidenceAttributesNamesAndRealClosesEveryDescriptor()
        throws
    {
        let root = try fixture()
        let first = canonical("1")
        let second = canonical("2")
        try plant(Data("a".utf8), name: first, in: root)
        try plant(Data("b".utf8), name: second, in: root)
        let descriptors = DescriptorEvents()
        let streamCloseCalls = Counter()
        let entryCloseCalls = Counter()
        let scanner = SettingsPublicationResidualInventory(
            systemCallHook: { call, _ in
                switch call {
                case .closeEntry:
                    _ = entryCloseCalls.increment()
                    return EBADF
                case .closeDirectory:
                    _ = streamCloseCalls.increment()
                    return EIO
                default:
                    return nil
                }
            },
            boundaryHook: { boundary in
                switch boundary {
                case .afterDirectoryStreamOpen(let descriptor):
                    descriptors.append(descriptor)
                case .afterEntryOpen(_, let descriptor):
                    descriptors.append(descriptor)
                default:
                    break
                }
            }
        )
        let pinned = open(
            settings(root).path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard pinned >= 0 else { throw POSIXError(.EIO) }
        defer { _ = close(pinned) }

        let snapshot = scanner.inspect(settingsDescriptor: pinned)

        XCTAssertEqual(streamCloseCalls.value, 1)
        XCTAssertEqual(entryCloseCalls.value, 2)
        XCTAssertEqual(
            snapshot.closeFailures.map(\.target),
            [
                .directoryStream,
                .entry(rawName: first),
                .entry(rawName: second),
            ]
        )
        XCTAssertEqual(
            snapshot.closeFailures.map(\.failure.code),
            [EIO, EBADF, EBADF]
        )
        XCTAssertEqual(snapshot.closeFailures.count, 3)
        try assertClosedAndReusable(try XCTUnwrap(descriptors.values.last))
    }

    func testFinalDirectoryAndAuthorityPostflightsPreserveFacts()
        throws
    {
        let root = try fixture(includeLock: true)
        let first = canonical("1")
        let created = canonical("2")
        let bytes = Data(#"{"schemaVersion":2}"#.utf8)
        try plant(bytes, name: first, in: root)
        let createdURL = rawURL(created, in: root)
        let scanner = SettingsPublicationResidualInventory(
            boundaryHook: { boundary in
                guard case .beforeEntryPostflight(first) = boundary
                else { return }
                _ = FileManager.default.createFile(
                    atPath: createdURL.path,
                    contents: Data("later".utf8)
                )
                _ = Darwin.chmod(createdURL.path, 0o600)
            }
        )
        let lock = makeLock(
            root,
            publicationResidualInventory: scanner
        )

        let snapshot = try lock.withMutationLock { authority in
            switch authority.inspectPublicationResiduals() {
            case .success(let snapshot):
                return snapshot
            case .failure(let error):
                throw error
            }
        }

        XCTAssertEqual(snapshot.entries.map(\.rawName), [first])
        assertRetained(
            try XCTUnwrap(snapshot.entries.first),
            bytes: bytes,
            content: .future(schemaVersion: 2)
        )
        assertPartial(snapshot, contains: .directoryChangedDuringScan)
        assertPartial(
            snapshot,
            contains: .authorityPostflight(
                .lockValidation(
                    .changedDuringAcquisition(item: .settingsDirectory)
                )
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: createdURL.path))
    }

    func testAuthorityClosePostflightPreservesCollectedSnapshot()
        throws
    {
        let root = try fixture(includeLock: true)
        let name = canonical("1")
        try plant(Data(), name: name, in: root)
        let closes = Counter()
        let lock = makeLock(
            root,
            systemCallHook: { call in
                guard call == .closeAuthorityContainer else { return nil }
                return closes.increment() == 2 ? EIO : nil
            }
        )

        let snapshot = try lock.withMutationLock { authority in
            switch authority.inspectPublicationResiduals() {
            case .success(let snapshot):
                return snapshot
            case .failure(let error):
                throw error
            }
        }

        XCTAssertEqual(snapshot.entries.map(\.rawName), [name])
        assertPartial(
            snapshot,
            contains: .authorityPostflight(
                .authorityContainerClose(
                    .init(
                        operation:
                            "close transient trusted settings container",
                        code: EIO
                    )
                )
            )
        )
    }

    func testAuthorityExpiresRejectsCrossThreadAndDetectsReentry()
        throws
    {
        let root = try fixture(includeLock: true)
        try plant(Data(), name: canonical("1"), in: root)
        let authorityBox = AuthorityBox()
        let reentryBox = InventoryResultBox()
        let scanner = SettingsPublicationResidualInventory(
            boundaryHook: { boundary in
                guard boundary == .afterDirectoryEnumeration,
                      let authority = authorityBox.value
                else { return }
                reentryBox.value = authority.inspectPublicationResiduals()
            }
        )
        let lock = makeLock(
            root,
            publicationResidualInventory: scanner
        )

        try lock.withMutationLock { authority in
            authorityBox.value = authority
            guard case .success = authority.inspectPublicationResiduals()
            else {
                return XCTFail("Expected live inventory.")
            }
            XCTAssertEqual(
                reentryBox.value,
                .failure(.reentrantAuthorityOperation)
            )
            let crossThread = InventoryResultBox()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async {
                crossThread.value =
                    authority.inspectPublicationResiduals()
                group.leave()
            }
            XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(
                crossThread.value,
                .failure(.expiredAuthority)
            )
        }
        XCTAssertEqual(
            authorityBox.value?.inspectPublicationResiduals(),
            .failure(.expiredAuthority)
        )
    }

    private func inventory(
        _ root: URL,
        scanner: SettingsPublicationResidualInventory = .init()
    ) throws -> SettingsPublicationResidualInventorySnapshot {
        let descriptor = open(
            settings(root).path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { _ = close(descriptor) }
        return scanner.inspect(settingsDescriptor: descriptor)
    }

    private func authorityInventory(
        _ root: URL
    ) throws -> SettingsPublicationResidualInventorySnapshot {
        try makeLock(root).withMutationLock { authority in
            switch authority.inspectPublicationResiduals() {
            case .success(let snapshot):
                return snapshot
            case .failure(let error):
                throw error
            }
        }
    }

    private func makeLock(
        _ root: URL,
        publicationNameSource:
            @escaping SettingsPrimaryPublication.NameSource = {
                UInt64.random(in: UInt64.min ... UInt64.max)
            },
        publicationResidualInventory:
            SettingsPublicationResidualInventory = .init(),
        systemCallHook:
            @escaping SettingsPrimaryMutationLock.SystemCallHook = { _ in nil }
    ) -> SettingsPrimaryMutationLock {
        SettingsPrimaryMutationLock(
            trustedContainerURL: root,
            systemCallHook: systemCallHook,
            publicationNameSource: publicationNameSource,
            publicationResidualInventory: publicationResidualInventory
        )
    }

    private func fixture(includeLock: Bool = false) throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "px-residual-inventory-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try chmod(root, 0o700)
        try FileManager.default.createDirectory(
            at: settings(root),
            withIntermediateDirectories: false
        )
        try chmod(settings(root), 0o700)
        if includeLock {
            let lock = settings(root).appendingPathComponent(
                SettingsPrimaryMutationLock.lockName
            )
            try write(Data(), to: lock)
        }
        roots.append(root)
        return root
    }

    private func plant(
        _ bytes: Data,
        name: Data,
        in root: URL
    ) throws {
        try plantRaw(bytes, name: name, in: root)
    }

    private func plantRaw(
        _ bytes: Data,
        name: Data,
        in root: URL
    ) throws {
        let parent = open(
            settings(root).path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard parent >= 0 else { throw POSIXError(.EIO) }
        defer { _ = close(parent) }
        let descriptor = withRawName(name) {
            openat(
                parent,
                $0,
                O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { _ = close(descriptor) }
        try bytes.withUnsafeBytes { raw in
            guard raw.count == 0
                    || Darwin.write(
                        descriptor,
                        raw.baseAddress,
                        raw.count
                    )
                        == raw.count
            else {
                throw POSIXError(.EIO)
            }
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            throw POSIXError(.EIO)
        }
    }

    private func write(
        _ bytes: Data,
        to url: URL,
        mode: mode_t = 0o600
    ) throws {
        XCTAssertTrue(FileManager.default.createFile(
            atPath: url.path,
            contents: bytes
        ))
        try chmod(url, mode)
    }

    private func chmod(_ url: URL, _ value: mode_t) throws {
        guard Darwin.chmod(url.path, value) == 0 else {
            throw POSIXError(.EIO)
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
            _ = close(descriptor)
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
            _ = close(descriptor)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    private func canonical(_ suffix: String) -> Data {
        Data((SettingsPublicationResidualNaming.prefix + suffix).utf8)
    }

    private func settings(_ root: URL) -> URL {
        root.appendingPathComponent(
            SettingsPrimaryMutationLock.settingsName,
            isDirectory: true
        )
    }

    private func rawURL(_ name: Data, in root: URL) -> URL {
        settings(root).appendingPathComponent(
            String(data: name, encoding: .utf8)!
        )
    }

    private func withRawName<T>(
        _ name: Data,
        _ body: (UnsafePointer<CChar>) -> T
    ) -> T {
        var terminated = [UInt8](name)
        terminated.append(0)
        return terminated.withUnsafeBytes {
            body($0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    private func mode(_ url: URL) -> UInt16 {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { return .max }
        return UInt16(status.st_mode & 0o7777)
    }

    private func assertClosedAndReusable(
        _ descriptor: Int32,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        errno = 0
        XCTAssertEqual(
            fcntl(descriptor, F_GETFD),
            -1,
            file: file,
            line: line
        )
        XCTAssertEqual(errno, EBADF, file: file, line: line)
        let reused = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard reused >= 0 else { throw POSIXError(.EIO) }
        XCTAssertEqual(reused, descriptor, file: file, line: line)
        XCTAssertGreaterThanOrEqual(
            fcntl(reused, F_GETFD),
            0,
            file: file,
            line: line
        )
        XCTAssertEqual(close(reused), 0, file: file, line: line)
    }

    private func directoryFacts(_ url: URL) throws -> [String: UInt16] {
        try Dictionary(
            uniqueKeysWithValues:
                FileManager.default.contentsOfDirectory(atPath: url.path)
                .map { name in
                    let child = url.appendingPathComponent(name)
                    return (name, mode(child))
                }
        )
    }

    private func document(
        revision: UInt64,
        appearance: String = "system"
    ) -> SettingsDocument {
        SettingsDocument(
            revision: .init(rawValue: revision),
            profileTemplates: [],
            defaultBaseStoragePath: "/Managed",
            confirmBeforeLaunch: true,
            automaticallyRecoverCrashedApps: false,
            appearance: appearance,
            profileVisualIdentities: []
        )
    }

    private func content(appearance: String) -> SettingsContent {
        SettingsContent(document: document(revision: 99, appearance: appearance))
    }

    private func assertRetained(
        _ entry: SettingsPublicationResidualEntry,
        bytes: Data,
        content: SettingsPublicationResidualRetainedContent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(entry.nameValidity, .canonical, file: file, line: line)
        XCTAssertEqual(
            entry.observation,
            .retained(
                bytes: bytes,
                sourceSHA256: SettingsSourceSHA256(bytes),
                content: content
            ),
            file: file,
            line: line
        )
    }

    private func assertUnsafe(
        _ snapshot: SettingsPublicationResidualInventorySnapshot,
        name: Data,
        _ reason: SettingsPublicationResidualUnsafeReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let entry = snapshot.entries.first { $0.rawName == name }
        XCTAssertEqual(
            entry?.observation,
            .unavailable(.unsafe(reason)),
            file: file,
            line: line
        )
    }

    private func assertPartial(
        _ snapshot: SettingsPublicationResidualInventorySnapshot,
        contains reason: SettingsPublicationResidualInventoryPartialReason,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .partial(let reasons) = snapshot.completion else {
            return XCTFail(
                "Expected partial inventory.",
                file: file,
                line: line
            )
        }
        XCTAssertTrue(reasons.contains(reason), file: file, line: line)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    func increment() -> Int {
        lock.withLock {
            stored += 1
            return stored
        }
    }

    var value: Int {
        lock.withLock { stored }
    }
}

private final class DescriptorEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int32] = []

    func append(_ descriptor: Int32) {
        lock.withLock {
            stored.append(descriptor)
        }
    }

    var values: [Int32] {
        lock.withLock { stored }
    }
}

private final class AuthorityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SettingsPrimaryMutationAuthority?

    var value: SettingsPrimaryMutationAuthority? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
private final class InventoryResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<
        SettingsPublicationResidualInventorySnapshot,
        SettingsPrimaryLockedInspectionError
    >?

    var value: Result<
        SettingsPublicationResidualInventorySnapshot,
        SettingsPrimaryLockedInspectionError
    >? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
