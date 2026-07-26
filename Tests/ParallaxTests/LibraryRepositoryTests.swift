import XCTest
import Darwin
@testable import Parallax

final class LibraryRepositoryTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParallaxLibraryRepositoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testVersionTwoWithoutRevisionDecodesAsInitialRevision() throws {
        let application = makeApplication(name: "Existing v2")
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 2,
            "applications": try jsonApplications([application]),
        ])

        let document = try LibraryPersistence.decodeCurrentDocument(from: data)

        XCTAssertEqual(document.revision, .initial)
        XCTAssertEqual(document.applications, [application])
    }

    func testRevisionEncodesAsUnsignedScalarWithoutChangingV2Envelope() throws {
        let data = try JSONEncoder().encode(
            LibraryDocument(
                revision: LibraryRevision(rawValue: 42),
                applications: []
            )
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["version"] as? Int, 2)
        XCTAssertEqual(object["revision"] as? UInt64, 42)
        XCTAssertNotNil(object["applications"] as? [Any])
    }

    func testInspectionRetainsCorruptOriginalBytesAndError() throws {
        let corruptBytes = Data(#"{"version":2,"applications":"not-an-array"}"#.utf8)
        let libraryURL = try writePrimary(corruptBytes)
        let persistence = LibraryPersistence(applicationSupportURL: temporaryDirectory)

        guard case let .recoveryRequired(failure) = persistence.inspect() else {
            return XCTFail("Expected recovery-required inspection")
        }

        XCTAssertEqual(failure.originalBytes, corruptBytes)
        XCTAssertFalse(failure.error.localizedDescription.isEmpty)
        let repository = LibraryRepository(applicationSupportURL: temporaryDirectory)
        XCTAssertThrowsError(
            try repository.save([], expectedVersion: .missing)
        ) { error in
            guard case LibraryRepositoryError.libraryUnavailable = error else {
                return XCTFail("Expected libraryUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: libraryURL), corruptBytes)
    }

    func testUnsupportedLibraryIsReadOnlyAndRetainsOriginalBytes() throws {
        let unsupportedBytes = Data(
            #"{"version":999,"applications":[]}"#.utf8
        )
        try writePrimary(unsupportedBytes)
        let repository = LibraryRepository(applicationSupportURL: temporaryDirectory)

        guard case let .readOnly(failure) = repository.load() else {
            return XCTFail("Expected read-only outcome")
        }
        XCTAssertEqual(failure.originalBytes, unsupportedBytes)

        XCTAssertThrowsError(
            try repository.save([], expectedVersion: .missing)
        ) { error in
            guard case LibraryRepositoryError.libraryUnavailable = error else {
                return XCTFail("Expected libraryUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(try primaryBytes(), unsupportedBytes)
    }

    func testMissingAndEmptyLibraryAreDistinct() throws {
        let repository = LibraryRepository(applicationSupportURL: temporaryDirectory)

        guard case .missing = repository.load() else {
            return XCTFail("Expected a missing-library outcome")
        }

        let saved = try repository.save([], expectedVersion: .missing)
        XCTAssertEqual(saved.revision, LibraryRevision(rawValue: 1))

        guard case let .loaded(snapshot) = repository.load() else {
            return XCTFail("Expected a loaded empty library")
        }
        XCTAssertEqual(snapshot.applications, [])
        XCTAssertEqual(snapshot.versionToken, saved.versionToken)
        XCTAssertFalse(snapshot.originalBytes.isEmpty)
    }

    func testCompareAndSwapRejectsStaleWriterWithoutChangingPrimary() throws {
        let firstRepository = LibraryRepository(applicationSupportURL: temporaryDirectory)
        let secondRepository = LibraryRepository(applicationSupportURL: temporaryDirectory)
        let initial = makeApplication(name: "Initial")
        let firstSaved = try firstRepository.save([initial], expectedVersion: .missing)

        guard case let .loaded(firstSnapshot) = firstRepository.load(),
              case let .loaded(secondSnapshot) = secondRepository.load()
        else {
            return XCTFail("Expected both repositories to load")
        }
        XCTAssertEqual(firstSnapshot.versionToken, firstSaved.versionToken)
        XCTAssertEqual(secondSnapshot.versionToken, firstSaved.versionToken)

        let winnerApplication = makeApplication(name: "Winner")
        let winnerSaved = try firstRepository.save(
            [winnerApplication],
            expectedVersion: firstSnapshot.versionToken
        )
        let winnerBytes = try primaryBytes()

        XCTAssertThrowsError(
            try secondRepository.save(
                [makeApplication(name: "Stale")],
                expectedVersion: secondSnapshot.versionToken
            )
        ) { error in
            guard case let LibraryRepositoryError.staleWriter(expected, actual) = error else {
                return XCTFail("Expected staleWriter, got \(error)")
            }
            XCTAssertEqual(expected, firstSaved.versionToken)
            XCTAssertEqual(actual, winnerSaved.versionToken)
        }
        XCTAssertEqual(try primaryBytes(), winnerBytes)
    }

    func testCompareAndSwapDetectsManualReplacementThatReusesRevision() throws {
        let repository = LibraryRepository(applicationSupportURL: temporaryDirectory)
        let original = try repository.save(
            [makeApplication(name: "Original")],
            expectedVersion: .missing
        )
        let replacementBytes = try JSONEncoder().encode(
            LibraryDocument(
                revision: original.revision,
                applications: [makeApplication(name: "Manual replacement")]
            )
        )
        try replacementBytes.write(to: primaryURL(), options: .atomic)

        XCTAssertThrowsError(
            try repository.save(
                [makeApplication(name: "Would overwrite")],
                expectedVersion: original.versionToken
            )
        ) { error in
            guard case let LibraryRepositoryError.staleWriter(expected, actual) = error else {
                return XCTFail("Expected staleWriter, got \(error)")
            }
            XCTAssertEqual(expected.revision, actual.revision)
            XCTAssertNotEqual(expected.primarySHA256, actual.primarySHA256)
        }
        XCTAssertEqual(try primaryBytes(), replacementBytes)
    }

    func testExclusiveMutationRejectsStaleVersionBeforeRunningFilesystemWork() throws {
        let repository = LibraryRepository(applicationSupportURL: temporaryDirectory)
        let stale = try repository.save(
            [makeApplication(name: "Initial")],
            expectedVersion: .missing
        )
        _ = try repository.save(
            [makeApplication(name: "Changed")],
            expectedVersion: stale.versionToken
        )
        var mutationBodyRan = false

        XCTAssertThrowsError(
            try repository.withExclusiveMutation(
                expectedVersion: stale.versionToken
            ) { _ in
                mutationBodyRan = true
            }
        ) { error in
            guard case LibraryRepositoryError.staleWriter = error else {
                return XCTFail("Expected staleWriter, got \(error)")
            }
        }
        XCTAssertFalse(mutationBodyRan)
    }

    func testPreparationProducesExactTargetBytesAndTokenWithoutWriting() throws {
        let repository = LibraryRepository(applicationSupportURL: temporaryDirectory)
        let applications = [makeApplication(name: "Prepared")]

        let prepared = try repository.prepare(
            applications,
            expectedVersion: .missing
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: primaryURL().path))
        XCTAssertEqual(
            prepared.targetVersion.revision,
            LibraryRevision(rawValue: 1)
        )
        XCTAssertEqual(
            prepared.targetVersion.primarySHA256,
            LibraryPersistence.sha256(prepared.targetBytes)
        )
        XCTAssertEqual(
            try LibraryPersistence.decodeCurrentDocument(
                from: prepared.targetBytes
            ).applications,
            applications
        )
    }

    func testPreparedCommitCapabilityRunsAfterFilesystemWorkAndExpiresWithClosure() throws {
        let repository = LibraryRepository(applicationSupportURL: temporaryDirectory)
        let prepared = try repository.prepare(
            [makeApplication(name: "Committed")],
            expectedVersion: .missing
        )
        var order: [String] = []
        var escapedCapability: LibraryMutationCommitCapability?

        let committed = try repository.withExclusiveMutation(
            expectedVersion: .missing
        ) { capability in
            escapedCapability = capability
            order.append("filesystem")
            let result = try capability.commit(prepared)
            order.append("metadata")
            return result.snapshot
        }

        XCTAssertEqual(order, ["filesystem", "metadata"])
        XCTAssertEqual(committed.versionToken, prepared.targetVersion)
        let expired = try XCTUnwrap(escapedCapability)
        XCTAssertThrowsError(try expired.commit(prepared)) { error in
            guard case LibraryRepositoryError.mutationSessionExpired = error else {
                return XCTFail("Expected mutationSessionExpired, got \(error)")
            }
        }
    }

    func testPreparedCommitRechecksPriorAfterStagingAndBeforeReplacement() throws {
        let fileSystem = RecordingPersistenceFileSystem()
        let repository = LibraryRepository(
            fileSystem: fileSystem,
            applicationSupportURL: temporaryDirectory
        )
        let original = try repository.save(
            [makeApplication(name: "Original")],
            expectedVersion: .missing
        )
        let prepared = try repository.prepare(
            [makeApplication(name: "Candidate")],
            expectedVersion: original.versionToken
        )
        let interveningBytes = try JSONEncoder().encode(
            LibraryDocument(
                revision: original.revision,
                applications: [makeApplication(name: "Intervening")]
            )
        )
        fileSystem.afterTemporarySynchronize = { [primaryURL = primaryURL()] in
            try interveningBytes.write(to: primaryURL, options: .atomic)
        }
        let replaceCountBefore = fileSystem.operations.filter {
            $0.hasPrefix("replace:")
        }.count

        XCTAssertThrowsError(
            try repository.withExclusiveMutation(
                expectedVersion: original.versionToken
            ) { capability in
                try capability.commit(prepared)
            }
        ) { error in
            guard case LibraryRepositoryError.staleWriter = error else {
                return XCTFail("Expected staleWriter, got \(error)")
            }
        }
        XCTAssertEqual(try primaryBytes(), interveningBytes)
        XCTAssertEqual(
            fileSystem.operations.filter { $0.hasPrefix("replace:") }.count,
            replaceCountBefore
        )
    }

    func testAmbiguousReplacementClassifiesTargetAsCommitted() throws {
        let fileSystem = RecordingPersistenceFileSystem()
        fileSystem.replaceBehavior = .replaceThenThrow
        let repository = LibraryRepository(
            fileSystem: fileSystem,
            applicationSupportURL: temporaryDirectory
        )
        let prepared = try repository.prepare(
            [makeApplication(name: "Target")],
            expectedVersion: .missing
        )

        XCTAssertThrowsError(
            try repository.withExclusiveMutation(
                expectedVersion: .missing
            ) { capability in
                try capability.commit(prepared)
            }
        ) { error in
            guard case let LibraryRepositoryError.commitFailed(state, _) = error else {
                return XCTFail("Expected commitFailed, got \(error)")
            }
            XCTAssertEqual(state, .target)
        }
        XCTAssertEqual(try primaryBytes(), prepared.targetBytes)
    }

    func testAmbiguousReplacementClassifiesPriorAndNeither() throws {
        for (index, pair) in [
            (RecordingPersistenceFileSystem.ReplaceBehavior.throwBeforeReplace, LibraryCommitPrimaryState.prior),
            (.writeThirdBytesThenThrow, .neither),
        ].enumerated() {
            let (behavior, expectedState) = pair
            let caseSupport = temporaryDirectory.appendingPathComponent(
                "Case-\(index)",
                isDirectory: true
            )
            let fileSystem = RecordingPersistenceFileSystem()
            let repository = LibraryRepository(
                fileSystem: fileSystem,
                applicationSupportURL: caseSupport
            )
            let original = try repository.save(
                [makeApplication(name: "Original")],
                expectedVersion: .missing
            )
            fileSystem.replaceBehavior = behavior
            let prepared = try repository.prepare(
                [makeApplication(name: "Target")],
                expectedVersion: original.versionToken
            )

            XCTAssertThrowsError(
                try repository.withExclusiveMutation(
                    expectedVersion: original.versionToken
                ) { capability in
                    try capability.commit(prepared)
                }
            ) { error in
                guard case let LibraryRepositoryError.commitFailed(state, _) = error else {
                    return XCTFail("Expected commitFailed, got \(error)")
                }
                XCTAssertEqual(state, expectedState)
            }
        }
    }

    func testSaveBackupHookReceivesExactPriorBytesAndFailurePreventsCommit() throws {
        let hook = RecordingBackupHook()
        let repository = LibraryRepository(
            applicationSupportURL: temporaryDirectory,
            backupHook: hook.call
        )
        let original = try repository.save(
            [makeApplication(name: "Original")],
            expectedVersion: .missing
        )
        hook.error = TestFailure.expected

        XCTAssertThrowsError(
            try repository.save(
                [makeApplication(name: "Replacement")],
                expectedVersion: original.versionToken,
                backupReason: .destructiveRewrite
            )
        )
        XCTAssertEqual(hook.calls.count, 1)
        XCTAssertEqual(hook.calls.first?.bytes, original.originalBytes)
        XCTAssertEqual(hook.calls.first?.reason, .destructiveRewrite)
        XCTAssertEqual(try primaryBytes(), original.originalBytes)
    }

    func testBackupReasonWithoutHookCannotSilentlySkipRequiredBackup() throws {
        let repository = LibraryRepository(applicationSupportURL: temporaryDirectory)
        let original = try repository.save(
            [makeApplication(name: "Original")],
            expectedVersion: .missing
        )

        XCTAssertThrowsError(
            try repository.save(
                [makeApplication(name: "Replacement")],
                expectedVersion: original.versionToken,
                backupReason: .destructiveRewrite
            )
        ) { error in
            guard case LibraryRepositoryError.backupUnavailable = error else {
                return XCTFail("Expected backupUnavailable, got \(error)")
            }
        }
        XCTAssertEqual(try primaryBytes(), original.originalBytes)
    }

    func testMutationSessionPublishesAtMostOnce() throws {
        let repository = LibraryRepository(applicationSupportURL: temporaryDirectory)

        try repository.withExclusiveMutation(expectedVersion: .missing) { session in
            _ = try session.publish(
                applications: [makeApplication(name: "First")]
            )
            XCTAssertThrowsError(
                try session.publish(
                    applications: [makeApplication(name: "Second")]
                )
            ) { error in
                guard case LibraryRepositoryError.mutationAlreadyPublished = error else {
                    return XCTFail("Expected mutationAlreadyPublished, got \(error)")
                }
            }
        }
    }

    func testAmbiguousPostReplaceFailureConsumesMutationSession() throws {
        let fileSystem = RecordingPersistenceFileSystem()
        fileSystem.synchronizationFailureURL = primaryURL()
        let repository = LibraryRepository(
            fileSystem: fileSystem,
            applicationSupportURL: temporaryDirectory
        )
        let committedApplication = makeApplication(name: "Committed")

        XCTAssertThrowsError(
            try repository.withExclusiveMutation(
                expectedVersion: .missing
            ) { session in
                do {
                    return try session.publish(
                        applications: [committedApplication]
                    )
                } catch {
                    guard case let LibraryRepositoryError.commitFailed(state, _) = error else {
                        throw error
                    }
                    XCTAssertEqual(state, .target)
                    XCTAssertThrowsError(
                        try session.publish(
                            applications: [makeApplication(name: "Unsafe retry")]
                        )
                    ) { retryError in
                        guard case LibraryRepositoryError.mutationAlreadyPublished = retryError else {
                            return XCTFail(
                                "Expected mutationAlreadyPublished, got \(retryError)"
                            )
                        }
                    }
                    throw error
                }
            }
        ) { error in
            guard case let LibraryRepositoryError.commitFailed(state, _) = error else {
                return XCTFail("Expected commitFailed, got \(error)")
            }
            XCTAssertEqual(state, .target)
        }

        guard case let .loaded(snapshot) = repository.load() else {
            return XCTFail("Atomic replacement should be classified as committed")
        }
        XCTAssertEqual(snapshot.applications, [committedApplication])
        XCTAssertEqual(snapshot.revision, LibraryRevision(rawValue: 1))
    }

    func testConcurrentCompareAndSwapAllowsExactlyOneWriter() throws {
        let seedRepository = LibraryRepository(applicationSupportURL: temporaryDirectory)
        let seed = try seedRepository.save(
            [makeApplication(name: "Seed")],
            expectedVersion: .missing
        )
        let firstRepository = LibraryRepository(applicationSupportURL: temporaryDirectory)
        let secondRepository = LibraryRepository(applicationSupportURL: temporaryDirectory)
        let results = LockedResults()
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

        for (repository, application) in [
            (firstRepository, makeApplication(name: "First")),
            (secondRepository, makeApplication(name: "Second")),
        ] {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                let result = Result {
                    try repository.save(
                        [application],
                        expectedVersion: seed.versionToken
                    )
                }
                results.append(result)
                group.leave()
            }
        }

        start.signal()
        start.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

        let collected = results.values
        XCTAssertEqual(collected.filter(\.isSuccess).count, 1)
        XCTAssertEqual(collected.filter(\.isStaleWriter).count, 1)
        guard case let .loaded(snapshot) = seedRepository.load() else {
            return XCTFail("Expected a readable winning document")
        }
        XCTAssertEqual(snapshot.revision, LibraryRevision(rawValue: 2))
    }

    func testAdvisoryLockIsReleasedWhenBodyThrows() throws {
        let lockURL = temporaryDirectory.appendingPathComponent("library.lock")
        let first = LibraryAdvisoryLock(url: lockURL)
        let second = LibraryAdvisoryLock(url: lockURL)

        XCTAssertThrowsError(
            try first.withExclusiveLock {
                throw TestFailure.expected
            }
        )

        var entered = false
        try second.withExclusiveLock {
            entered = true
        }
        XCTAssertTrue(entered)
    }

    func testAdvisoryLockIsReleasedWhenDescriptorClosesWithoutExplicitUnlock() throws {
        let lockURL = temporaryDirectory.appendingPathComponent("crash-library.lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)

        // A process crash closes its descriptors without running application
        // cleanup. Closing without LOCK_UN exercises that kernel release path.
        XCTAssertEqual(close(descriptor), 0)

        var parentEntered = false
        try LibraryAdvisoryLock(url: lockURL).withExclusiveLock {
            parentEntered = true
        }
        XCTAssertTrue(parentEntered)
    }

    func testAdvisoryLockContentionTimesOutWithinBound() throws {
        let lockURL = temporaryDirectory.appendingPathComponent("contended.lock")
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        defer { close(descriptor) }
        let lock = LibraryAdvisoryLock(
            url: lockURL,
            timeout: 0.05,
            pollInterval: 0.005
        )
        let started = DispatchTime.now().uptimeNanoseconds

        XCTAssertThrowsError(try lock.withExclusiveLock {}) { error in
            guard case LibraryAdvisoryLockError.timedOut = error else {
                return XCTFail("Expected timedOut, got \(error)")
            }
        }
        let elapsed = Double(
            DispatchTime.now().uptimeNanoseconds - started
        ) / 1_000_000_000
        XCTAssertGreaterThanOrEqual(elapsed, 0.04)
        XCTAssertLessThan(elapsed, 0.5)
    }

    func testRevisionOverflowDoesNotChangePrimary() throws {
        let application = makeApplication(name: "Maximum")
        let persistence = LibraryPersistence(applicationSupportURL: temporaryDirectory)
        try persistence.saveDocument(
            LibraryDocument(
                revision: LibraryRevision(rawValue: UInt64.max),
                applications: [application]
            )
        )
        let originalBytes = try primaryBytes()
        let repository = LibraryRepository(applicationSupportURL: temporaryDirectory)

        XCTAssertThrowsError(
            try repository.save(
                [makeApplication(name: "Replacement")],
                expectedVersion: LibraryVersionToken(
                    revision: LibraryRevision(rawValue: UInt64.max),
                    primarySHA256: LibraryPersistence.sha256(originalBytes)
                )
            )
        ) { error in
            guard case LibraryRepositoryError.revisionOverflow = error else {
                return XCTFail("Expected revisionOverflow, got \(error)")
            }
        }
        XCTAssertEqual(try primaryBytes(), originalBytes)
    }

    func testDurableSaveSynchronizesTemporaryFileThenPrimaryAndParent() throws {
        let recordingFileSystem = RecordingPersistenceFileSystem()
        let persistence = LibraryPersistence(
            fileSystem: recordingFileSystem,
            applicationSupportURL: temporaryDirectory
        )

        try persistence.save([makeApplication(name: "Durable")])

        let operations = recordingFileSystem.operations
        let write = try XCTUnwrap(operations.firstIndex(where: { $0.hasPrefix("write:") }))
        let firstSync = try XCTUnwrap(operations.firstIndex(where: { $0.hasPrefix("sync:") }))
        let replace = try XCTUnwrap(operations.firstIndex(where: { $0.hasPrefix("replace:") }))
        let primarySync = try XCTUnwrap(
            operations.lastIndex(of: "sync:\(primaryURL().path)")
        )
        let parentSync = try XCTUnwrap(
            operations.lastIndex(of: "sync:\(primaryURL().deletingLastPathComponent().path)")
        )

        XCTAssertLessThan(write, firstSync)
        XCTAssertLessThan(firstSync, replace)
        XCTAssertLessThan(replace, primarySync)
        XCTAssertLessThan(primarySync, parentSync)
    }

    private func makeApplication(name: String) -> ManagedApplication {
        ManagedApplication(
            displayName: name,
            appPath: "/Applications/\(name).app"
        )
    }

    private func jsonApplications(_ applications: [ManagedApplication]) throws -> Any {
        let data = try JSONEncoder().encode(applications)
        return try JSONSerialization.jsonObject(with: data)
    }

    @discardableResult
    private func writePrimary(_ data: Data) throws -> URL {
        let url = primaryURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url)
        return url
    }

    private func primaryURL() -> URL {
        temporaryDirectory
            .appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
    }

    private func primaryBytes() throws -> Data {
        try Data(contentsOf: primaryURL())
    }
}

private enum TestFailure: Error {
    case expected
}

private final class RecordingBackupHook: @unchecked Sendable {
    struct Call {
        let bytes: Data
        let reason: LibraryBackupReason
    }

    private let lock = NSLock()
    private var recordedCalls: [Call] = []
    private var storedError: Error?

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    var error: Error? {
        get { lock.withLock { storedError } }
        set { lock.withLock { storedError = newValue } }
    }

    var call: LibraryBackupHook {
        { [self] bytes, reason in
            try lock.withLock {
                recordedCalls.append(Call(bytes: bytes, reason: reason))
                if let storedError {
                    throw storedError
                }
            }
        }
    }
}

private final class LockedResults: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Result<LibraryRepositorySnapshot, Error>] = []

    var values: [Result<LibraryRepositorySnapshot, Error>] {
        lock.withLock { storage }
    }

    func append(_ result: Result<LibraryRepositorySnapshot, Error>) {
        lock.withLock {
            storage.append(result)
        }
    }
}

private extension Result where Success == LibraryRepositorySnapshot, Failure == Error {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var isStaleWriter: Bool {
        guard case let .failure(error) = self,
              case LibraryRepositoryError.staleWriter = error
        else {
            return false
        }
        return true
    }
}

private final class RecordingPersistenceFileSystem: FileSystem, @unchecked Sendable {
    enum ReplaceBehavior {
        case normal
        case throwBeforeReplace
        case replaceThenThrow
        case writeThirdBytesThenThrow
    }

    private let underlying = LocalFileSystem()
    private let lock = NSLock()
    private var recordedOperations: [String] = []
    private var synchronizationFailurePath: String?
    private var storedReplaceBehavior: ReplaceBehavior = .normal
    private var temporarySynchronizationHook: (() throws -> Void)?

    var operations: [String] {
        lock.withLock { recordedOperations }
    }

    var synchronizationFailureURL: URL? {
        get {
            lock.withLock {
                synchronizationFailurePath.map {
                    URL(fileURLWithPath: $0)
                }
            }
        }
        set {
            lock.withLock {
                synchronizationFailurePath = newValue?.path
            }
        }
    }

    var replaceBehavior: ReplaceBehavior {
        get { lock.withLock { storedReplaceBehavior } }
        set { lock.withLock { storedReplaceBehavior = newValue } }
    }

    var afterTemporarySynchronize: (() throws -> Void)? {
        get { lock.withLock { temporarySynchronizationHook } }
        set { lock.withLock { temporarySynchronizationHook = newValue } }
    }

    func fileExists(at url: URL) -> Bool {
        record("exists:\(url.path)")
        return underlying.fileExists(at: url)
    }

    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes {
        record("attributes:\(url.path)")
        return try underlying.attributesOfItem(at: url)
    }

    func canonicalURL(for url: URL) throws -> URL {
        record("canonical:\(url.path)")
        return try underlying.canonicalURL(for: url)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        record("mkdir:\(url.path)")
        try underlying.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        record("copy:\(sourceURL.path)->\(destinationURL.path)")
        try underlying.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        record("move:\(sourceURL.path)->\(destinationURL.path)")
        try underlying.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        record("remove:\(url.path)")
        try underlying.removeItem(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        record("contents:\(url.path)")
        return try underlying.contentsOfDirectory(at: url)
    }

    func readData(at url: URL) throws -> Data {
        record("read:\(url.path)")
        return try underlying.readData(at: url)
    }

    func writeData(_ data: Data, to url: URL) throws {
        record("write:\(url.path)")
        try underlying.writeData(data, to: url)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        record("writeAtomic:\(url.path)")
        try underlying.writeDataAtomically(data, to: url)
    }

    func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
        record("replace:\(sourceURL.path)->\(destinationURL.path)")
        switch replaceBehavior {
        case .normal:
            try underlying.replaceItem(at: destinationURL, withItemAt: sourceURL)
        case .throwBeforeReplace:
            throw TestFailure.expected
        case .replaceThenThrow:
            try underlying.replaceItem(at: destinationURL, withItemAt: sourceURL)
            throw TestFailure.expected
        case .writeThirdBytesThenThrow:
            try Data("third-state".utf8).write(
                to: destinationURL,
                options: .atomic
            )
            throw TestFailure.expected
        }
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        record("permissions:\(url.path)")
        try underlying.setPOSIXPermissions(permissions, at: url)
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        record("readlink:\(url.path)")
        return try underlying.destinationOfSymbolicLink(at: url)
    }

    func synchronize(at url: URL) throws {
        record("sync:\(url.path)")
        if url.lastPathComponent.hasPrefix(".library.json."),
           url.pathExtension == "tmp" {
            let hook = lock.withLock {
                let hook = temporarySynchronizationHook
                temporarySynchronizationHook = nil
                return hook
            }
            try hook?()
        }
        if lock.withLock({ synchronizationFailurePath == url.path }) {
            throw TestFailure.expected
        }
        try underlying.synchronize(at: url)
    }

    func applicationSupportURL(create: Bool) throws -> URL {
        try underlying.applicationSupportURL(create: create)
    }

    private func record(_ operation: String) {
        lock.withLock {
            recordedOperations.append(operation)
        }
    }
}
