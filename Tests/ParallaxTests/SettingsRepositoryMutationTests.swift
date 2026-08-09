import Darwin
import Foundation
import XCTest
@testable import Parallax

final class SettingsRepositoryMutationTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDownWithError() throws {
        for directory in temporaryDirectories.reversed() {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories = []
    }

    func testMissingAndCurrentCommitsUseCanonicalRevisionedCAS() throws {
        let container = try fixture()
        let writer = makeWriter(container)

        let firstResult = writer.commit(
            content(appearance: "dark"),
            expecting: .missing
        )
        guard case .committed(let first, let firstResidual) =
            firstResult
        else {
            return XCTFail("Expected missing commit: \(firstResult)")
        }
        XCTAssertNil(firstResidual)
        XCTAssertEqual(first.document.revision.rawValue, 1)
        XCTAssertEqual(first.document.schemaVersion, 1)
        XCTAssertEqual(first.originalBytes, try primaryBytes(container))
        XCTAssertEqual(mode(primary(container)), 0o600)
        XCTAssertEqual(
            first.originalBytes,
            try SettingsDocumentCodec().encode(first.document)
        )
        XCTAssertEqual(try publicationTemporaries(container), [])

        guard case .committed(let second, let secondResidual) =
            writer.commit(
            content(appearance: "light"),
            expecting: .version(first.versionToken)
            )
        else {
            return XCTFail("Expected current commit.")
        }
        XCTAssertEqual(second.document.revision.rawValue, 2)
        XCTAssertEqual(second.document.appearance, "light")
        XCTAssertEqual(second.originalBytes, try primaryBytes(container))
        guard case .displacedPrior(let residualName, let residualToken) =
            secondResidual
        else {
            return XCTFail("Expected displaced-prior residual.")
        }
        XCTAssertEqual(residualToken, first.versionToken)
        XCTAssertEqual(
            try Data(
                contentsOf: settings(container)
                    .appendingPathComponent(residualName)
            ),
            first.originalBytes
        )
    }

    func testStaleAndMissingExpectationsRejectWithoutCreatingTemporary()
        throws
    {
        let container = try fixture()
        let writer = makeWriter(container)
        guard case .committed(let first, _) = writer.commit(
            content(),
            expecting: .missing
        ) else {
            return XCTFail("Expected fixture commit.")
        }
        let original = try primaryBytes(container)

        let wrongSHA = SettingsVersionToken(
            revision: first.versionToken.revision,
            sourceSHA256: SettingsSourceSHA256(Data("other".utf8))
        )
        for expectation in [
            SettingsCommitExpectation.missing,
            .version(wrongSHA),
        ] {
            guard case .rejected(let evidence) = writer.commit(
                content(appearance: "light"),
                expecting: expectation
            ) else {
                return XCTFail("Expected stale rejection.")
            }
            XCTAssertEqual(evidence.classification, .prior)
            XCTAssertEqual(evidence.failure, .expectationMismatch)
            XCTAssertEqual(try primaryBytes(container), original)
            XCTAssertEqual(try publicationTemporaries(container), [])
        }
    }

    func testRevisionZeroAdvancesToOneAndMaximumRejectsBeforeTemporary()
        throws
    {
        let zeroContainer = try fixture()
        let zeroDocument = document(revision: 0)
        let zeroBytes = try SettingsDocumentCodec().encode(zeroDocument)
        try installPrimary(zeroBytes, in: zeroContainer)
        let zeroToken = SettingsVersionToken(
            revision: zeroDocument.revision,
            sourceSHA256: SettingsSourceSHA256(zeroBytes)
        )
        guard case .committed(let committed, _) =
            makeWriter(zeroContainer)
            .commit(content(), expecting: .version(zeroToken))
        else {
            return XCTFail("Expected revision-zero upgrade.")
        }
        XCTAssertEqual(committed.document.revision.rawValue, 1)

        let maximumContainer = try fixture()
        let maximumDocument = document(revision: UInt64.max)
        let maximumBytes = try SettingsDocumentCodec().encode(maximumDocument)
        try installPrimary(maximumBytes, in: maximumContainer)
        let maximumToken = SettingsVersionToken(
            revision: maximumDocument.revision,
            sourceSHA256: SettingsSourceSHA256(maximumBytes)
        )
        guard case .rejected(let evidence) = makeWriter(maximumContainer)
            .commit(content(), expecting: .version(maximumToken))
        else {
            return XCTFail("Expected overflow rejection.")
        }
        XCTAssertEqual(evidence.failure, .revisionOverflow)
        XCTAssertEqual(evidence.classification, .prior)
        XCTAssertEqual(try primaryBytes(maximumContainer), maximumBytes)
        XCTAssertEqual(try publicationTemporaries(maximumContainer), [])
    }

    func testFutureCorruptAndUnavailablePrimaryArePreserved() throws {
        let future = Data(#"{"schemaVersion":2,"future":true}"#.utf8)
        let corrupt = Data(#"{"schemaVersion":1}"#.utf8)

        for (bytes, futureVersion) in [
            (future, UInt64(2)),
            (corrupt, nil),
        ] {
            let container = try fixture()
            try installPrimary(bytes, in: container)
            let result = makeWriter(container).commit(
                content(),
                expecting: .missing
            )
            if let futureVersion {
                guard case .rejected(let evidence) = result else {
                    return XCTFail("Expected future-schema rejection.")
                }
                XCTAssertEqual(
                    evidence.failure,
                    .futureSchema(futureVersion)
                )
            } else {
                guard case .recoveryRequired(let evidence) = result,
                      case .corrupt(let failure) = evidence.failure
                else {
                    return XCTFail("Expected corrupt recovery.")
                }
                XCTAssertEqual(failure.originalBytes, corrupt)
            }
            XCTAssertEqual(try primaryBytes(container), bytes)
            XCTAssertEqual(try publicationTemporaries(container), [])
        }

        let unavailable = try fixture()
        let bytes = try SettingsDocumentCodec().encode(document(revision: 3))
        try installPrimary(bytes, in: unavailable)
        try chmod(primary(unavailable), 0o644)
        guard case .recoveryRequired(let evidence) =
            makeWriter(unavailable).commit(content(), expecting: .missing)
        else {
            return XCTFail("Expected unavailable recovery.")
        }
        guard case .unavailable = evidence.failure else {
            return XCTFail("Expected typed unavailable evidence.")
        }
        XCTAssertEqual(try primaryBytes(unavailable), bytes)
        XCTAssertEqual(try publicationTemporaries(unavailable), [])
    }

    func testPartialWritesAndEINTRCompleteWithoutLeakingTemporary()
        throws
    {
        let container = try fixture()
        let counter = IntegerBox()
        let writer = makeWriter(
            container,
            writeHook: { _, _, _ in
                let value = counter.increment()
                if value <= 3 {
                    return .failure(EINTR)
                }
                return .limit(2)
            }
        )
        guard case .committed(let snapshot, _) = writer.commit(
            content(),
            expecting: .missing
        ) else {
            return XCTFail("Expected bounded partial-write commit.")
        }
        XCTAssertEqual(try primaryBytes(container), snapshot.originalBytes)
        XCTAssertEqual(try publicationTemporaries(container), [])
    }

    func testZeroProgressAndPreEffectFailuresPreservePriorAndClean()
        throws
    {
        for call in [
            SettingsPrimaryPublicationSystemCall.createTemporary,
            .inspectTemporary,
            .setTemporaryMode,
            .reinspectTemporary,
            .inspectTemporaryPath,
            .syncTemporary,
        ] {
            let container = try fixture()
            let result = makeWriter(
                container,
                systemHook: { observed in
                    observed == call ? EIO : nil
                }
            ).commit(content(), expecting: .missing)
            assertRecovery(result, classification: .prior)
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: primary(container).path
            ))
            XCTAssertEqual(
                try publicationTemporaries(container).count,
                call == .createTemporary ? 0 : 1
            )
        }

        let zero = try fixture()
        let result = makeWriter(
            zero,
            writeHook: { _, _, _ in .zero }
        ).commit(content(), expecting: .missing)
        assertRecovery(result, classification: .prior)
        XCTAssertEqual(try publicationTemporaries(zero).count, 1)
    }

    func testWriteFailuresAreTypedBoundedAndCleanExactTemporary() throws {
        for code in [ENOSPC, EDQUOT] {
            let container = try fixture()
            let result = makeWriter(
                container,
                writeHook: { _, _, _ in .failure(code) }
            ).commit(content(), expecting: .missing)
            assertRecovery(result, classification: .prior)
            XCTAssertEqual(try publicationTemporaries(container).count, 1)
        }

        let interrupted = try fixture()
        let attempts = IntegerBox()
        let result = makeWriter(
            interrupted,
            writeHook: { _, _, _ in
                _ = attempts.increment()
                return .failure(EINTR)
            }
        ).commit(content(), expecting: .missing)
        assertRecovery(result, classification: .prior)
        XCTAssertEqual(
            attempts.value,
            SettingsPrimaryPublication.maximumConsecutiveInterrupts + 1
        )
        XCTAssertEqual(try publicationTemporaries(interrupted).count, 1)
    }

    func testAfterRenameFailureClassifiesTargetAndNeverDeletesIt() throws {
        let container = try fixture()
        let result = makeWriter(
            container,
            systemHook: { call in
                call == .syncSettings ? EIO : nil
            }
        ).commit(content(), expecting: .missing)

        assertRecovery(result, classification: .target)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: primary(container).path
        ))
        XCTAssertEqual(try publicationTemporaries(container), [])
    }

    func testRenameFailureIsSingleAttemptAndClassifiesPrior() throws {
        let container = try fixture()
        let calls = IntegerBox()
        let result = makeWriter(
            container,
            systemHook: { call in
                guard call == .renameMissing else { return nil }
                _ = calls.increment()
                return EINTR
            }
        ).commit(content(), expecting: .missing)

        assertRecovery(result, classification: .prior)
        XCTAssertEqual(calls.value, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: primary(container).path
        ))
        XCTAssertEqual(try publicationTemporaries(container).count, 1)
    }

    func testTemporaryNameExhaustionPreservesEveryCollision() throws {
        let container = try fixture()
        let collision = settings(container).appendingPathComponent(
            SettingsPrimaryPublication.temporaryPrefix + "2a"
        )
        let sentinel = Data("owned by another writer".utf8)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: collision.path,
            contents: sentinel
        ))
        try chmod(collision, 0o600)

        let result = makeWriter(
            container,
            nameSource: { 42 }
        ).commit(content(), expecting: .missing)
        assertRecovery(result, classification: .prior)
        XCTAssertEqual(try Data(contentsOf: collision), sentinel)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: primary(container).path
        ))
    }

    func testSymlinkDirectoryFIFOAndHardLinkCollisionsAreNeverTouched()
        throws
    {
        enum Collision {
            case symbolicLink
            case directory
            case fifo
            case hardLink
        }
        for collisionKind in [
            Collision.symbolicLink,
            .directory,
            .fifo,
            .hardLink,
        ] {
            let container = try fixture()
            let collision = settings(container).appendingPathComponent(
                SettingsPrimaryPublication.temporaryPrefix + "7"
            )
            let sentinel = settings(container)
                .appendingPathComponent("collision-sentinel")
            switch collisionKind {
            case .symbolicLink:
                try Data("outside".utf8).write(to: sentinel)
                XCTAssertEqual(
                    symlink(sentinel.path, collision.path),
                    0
                )
            case .directory:
                try FileManager.default.createDirectory(
                    at: collision,
                    withIntermediateDirectories: false
                )
            case .fifo:
                XCTAssertEqual(mkfifo(collision.path, 0o600), 0)
            case .hardLink:
                try Data("linked".utf8).write(to: sentinel)
                try chmod(sentinel, 0o600)
                XCTAssertEqual(link(sentinel.path, collision.path), 0)
            }

            let before = try FileManager.default.attributesOfItem(
                atPath: collision.path
            )
            let result = makeWriter(
                container,
                nameSource: { 7 }
            ).commit(content(), expecting: .missing)
            assertRecovery(result, classification: .prior)
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(
                    atPath: collision.path
                )[.systemFileNumber] as? NSNumber,
                before[.systemFileNumber] as? NSNumber
            )
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: primary(container).path
            ))
        }
    }

    func testTemporaryPathSwapAndInjectedACLFailClosedWithoutDeletion()
        throws
    {
        let swappedContainer = try fixture()
        let swappedName =
            SettingsPrimaryPublication.temporaryPrefix + "9"
        let swappedPath = settings(swappedContainer)
            .appendingPathComponent(swappedName)
        let sentinel = settings(swappedContainer)
            .appendingPathComponent("attacker-owned")
        try Data("sentinel".utf8).write(to: sentinel)
        try chmod(sentinel, 0o600)
        let swapped = makeWriter(
            swappedContainer,
            boundaryHook: { boundary in
                guard boundary == .afterTemporaryOpen else { return }
                try? FileManager.default.removeItem(at: swappedPath)
                _ = symlink(sentinel.path, swappedPath.path)
            },
            nameSource: { 9 }
        ).commit(content(), expecting: .missing)
        assertRecovery(swapped, classification: .prior)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: swappedPath.path
            ),
            sentinel.path
        )

        let aclContainer = try fixture()
        let aclCalls = IntegerBox()
        let acl = makeWriter(
            aclContainer,
            aclHook: { _ in
                aclCalls.increment() == 1 ? .present : .system
            }
        ).commit(content(), expecting: .missing)
        assertRecovery(acl, classification: .prior)
        XCTAssertEqual(try publicationTemporaries(aclContainer).count, 1)
    }

    func testInvalidContentAndSecondWriterNeverCreateOrPublishStaleData()
        throws
    {
        let invalidContainer = try fixture()
        guard case .rejected(let invalid) = makeWriter(invalidContainer)
            .commit(content(appearance: "sepia"), expecting: .missing)
        else {
            return XCTFail("Expected invalid-content rejection.")
        }
        guard case .invalidTarget = invalid.failure else {
            return XCTFail("Expected typed invalid target.")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: primary(invalidContainer).path
        ))
        XCTAssertEqual(try publicationTemporaries(invalidContainer), [])

        let container = try fixture()
        let firstWriter = makeWriter(container)
        guard case .committed(let initial, _) = firstWriter.commit(
            content(),
            expecting: .missing
        ) else {
            return XCTFail("Expected initial commit.")
        }
        let secondWriter = makeWriter(container)
        guard case .committed(let winner, _) = firstWriter.commit(
            content(appearance: "dark"),
            expecting: .version(initial.versionToken)
        ) else {
            return XCTFail("Expected first writer to win.")
        }
        guard case .rejected(let loser) = secondWriter.commit(
            content(appearance: "light"),
            expecting: .version(initial.versionToken)
        ) else {
            return XCTFail("Expected stale second writer rejection.")
        }
        XCTAssertEqual(loser.classification, .prior)
        XCTAssertEqual(try primaryBytes(container), winner.originalBytes)
        XCTAssertEqual(try publicationTemporaries(container).count, 1)
    }

    func testPostEffectClassificationDistinguishesNeitherAndIndeterminate()
        throws
    {
        let neitherContainer = try fixture()
        let unrelated = try SettingsDocumentCodec().encode(
            document(revision: 44, appearance: "light")
        )
        let neitherPrimary = primary(neitherContainer)
        let neither = makeWriter(
            neitherContainer,
            boundaryHook: { boundary in
                guard boundary == .beforePostflight else { return }
                try? FileManager.default.removeItem(at: neitherPrimary)
                _ = FileManager.default.createFile(
                    atPath: neitherPrimary.path,
                    contents: unrelated
                )
                _ = Darwin.chmod(neitherPrimary.path, 0o600)
            }
        ).commit(content(), expecting: .missing)
        assertRecovery(neither, classification: .neither)
        XCTAssertEqual(try primaryBytes(neitherContainer), unrelated)

        let indeterminateContainer = try fixture()
        let indeterminatePrimary = primary(indeterminateContainer)
        let indeterminate = makeWriter(
            indeterminateContainer,
            boundaryHook: { boundary in
                guard boundary == .beforePostflight else { return }
                _ = Darwin.chmod(indeterminatePrimary.path, 0o644)
            }
        ).commit(content(), expecting: .missing)
        assertRecovery(indeterminate, classification: .indeterminate)
        XCTAssertEqual(mode(primary(indeterminateContainer)), 0o644)
    }

    func testCurrentPrimaryRaceAfterCASPreservesUnexpectedDisplacedBytes()
        throws
    {
        let container = try fixture()
        guard case .committed(let initial, _) = makeWriter(container)
            .commit(content(), expecting: .missing)
        else {
            return XCTFail("Expected initial commit.")
        }
        let unexpected = try SettingsDocumentCodec().encode(
            document(revision: 77, appearance: "dark")
        )
        let fixedName =
            SettingsPrimaryPublication.temporaryPrefix + "51"
        let primaryURL = primary(container)
        let result = makeWriter(
            container,
            boundaryHook: { boundary in
                guard boundary == .afterCompareAndSwap else { return }
                try? FileManager.default.removeItem(at: primaryURL)
                _ = FileManager.default.createFile(
                    atPath: primaryURL.path,
                    contents: unexpected
                )
                _ = Darwin.chmod(primaryURL.path, 0o600)
            },
            nameSource: { 0x51 }
        ).commit(
            content(appearance: "light"),
            expecting: .version(initial.versionToken)
        )

        assertRecovery(result, classification: .neither)
        XCTAssertEqual(
            try Data(
                contentsOf: settings(container)
                    .appendingPathComponent(fixedName)
            ),
            unexpected
        )
        XCTAssertEqual(
            try primaryBytes(container),
            try SettingsDocumentCodec().encode(
                document(revision: 2, appearance: "light")
            )
        )
    }

    func testAfterRenameFIFOSwapReturnsPromptTypedRecoveryAndPreservesBoth()
        throws
    {
        let container = try fixture()
        guard case .committed(let initial, _) = makeWriter(container)
            .commit(content(), expecting: .missing)
        else {
            return XCTFail("Expected initial commit.")
        }
        let fixedName =
            SettingsPrimaryPublication.temporaryPrefix + "53"
        let displacedPath = settings(container)
            .appendingPathComponent(fixedName)
        let movedPrior = settings(container)
            .appendingPathComponent("preserved-displaced-prior")
        let boundaryCalls = IntegerBox()
        let writer = makeWriter(
            container,
            boundaryHook: { boundary in
                guard boundary == .afterRename else { return }
                _ = boundaryCalls.increment()
                XCTAssertEqual(
                    Darwin.rename(displacedPath.path, movedPrior.path),
                    0
                )
                XCTAssertEqual(mkfifo(displacedPath.path, 0o600), 0)
            },
            nameSource: { 0x53 }
        )
        let resultBox = CommitResultBox()
        let updatedContent = content(appearance: "light")
        let completed = expectation(
            description: "nonblocking displaced-prior verification"
        )

        DispatchQueue.global().async {
            resultBox.value = writer.commit(
                updatedContent,
                expecting: .version(initial.versionToken)
            )
            completed.fulfill()
        }

        XCTAssertEqual(
            XCTWaiter.wait(for: [completed], timeout: 1),
            .completed
        )
        guard let result = resultBox.value,
              case .recoveryRequired(let evidence) = result,
              case .publication(let publication) = evidence.failure
        else {
            return XCTFail("Expected prompt typed publication recovery.")
        }
        XCTAssertEqual(boundaryCalls.value, 1)
        XCTAssertEqual(evidence.classification, .neither)
        XCTAssertEqual(
            publication.failure,
            .invalidRequest("unsafe temporary")
        )
        XCTAssertFalse(publication.targetProofEligible)
        XCTAssertEqual(
            evidence.residual,
            .possiblePreservedPath(name: fixedName)
        )
        XCTAssertEqual(try Data(contentsOf: movedPrior), initial.originalBytes)
        XCTAssertEqual(
            try primaryBytes(container),
            try SettingsDocumentCodec().encode(
                document(revision: 2, appearance: "light")
            )
        )
        var fifoStatus = stat()
        XCTAssertEqual(lstat(displacedPath.path, &fifoStatus), 0)
        XCTAssertEqual(fifoStatus.st_mode & S_IFMT, S_IFIFO)
    }

    func testExactTargetPathSwapCannotSubstituteForSyncedDescriptor()
        throws
    {
        let container = try fixture()
        guard case .committed(let initial, _) = makeWriter(container)
            .commit(content(), expecting: .missing)
        else {
            return XCTFail("Expected initial commit.")
        }
        let target = try SettingsDocumentCodec().encode(
            document(revision: 2, appearance: "light")
        )
        let fixedName =
            SettingsPrimaryPublication.temporaryPrefix + "52"
        let temporary = settings(container)
            .appendingPathComponent(fixedName)
        let result = makeWriter(
            container,
            boundaryHook: { boundary in
                guard boundary == .afterCompareAndSwap else { return }
                try? FileManager.default.removeItem(at: temporary)
                _ = FileManager.default.createFile(
                    atPath: temporary.path,
                    contents: target
                )
                _ = Darwin.chmod(temporary.path, 0o600)
            },
            nameSource: { 0x52 }
        ).commit(
            content(appearance: "light"),
            expecting: .version(initial.versionToken)
        )

        assertRecovery(result, classification: .neither)
        XCTAssertEqual(try primaryBytes(container), target)
        XCTAssertEqual(
            try Data(contentsOf: temporary),
            initial.originalBytes
        )
    }

    func testClassificationReadFailureIsRetainedWithPublicationCause()
        throws
    {
        let container = try fixture()
        let reads = IntegerBox()
        let result = makeWriter(
            container,
            systemHook: { call in
                call == .createTemporary ? EIO : nil
            },
            inspectionSystemHook: { call in
                guard call == .inspectPrimaryPath else { return nil }
                return reads.increment() == 2 ? EIO : nil
            }
        ).commit(content(), expecting: .missing)

        guard case .recoveryRequired(let evidence) = result,
              case .publication(let publication) = evidence.failure
        else {
            return XCTFail("Expected publication recovery evidence.")
        }
        XCTAssertEqual(evidence.classification, .indeterminate)
        XCTAssertNotNil(publication.classificationReadFailure)
        XCTAssertEqual(
            publication.failure,
            .system(
                .init(
                    operation: "create settings publication temporary",
                    code: EIO
                )
            )
        )
    }

    func testTargetClassificationIsFloorAcrossLockFinalizationFailure()
        throws
    {
        let container = try fixture()
        let result = makeWriter(
            container,
            lockSystemHook: { call in
                call == .closeSettings ? EIO : nil
            },
            systemHook: { call in
                call == .syncSettings ? EIO : nil
            }
        ).commit(content(), expecting: .missing)

        guard case .recoveryRequired(let evidence) = result,
              case .publicationAndLock = evidence.failure
        else {
            return XCTFail("Expected combined publication and lock evidence.")
        }
        XCTAssertEqual(evidence.classification, .target)
    }

    func testCommittedCurrentResidualSurvivesLockCleanupWithoutReacquire()
        throws
    {
        let container = try fixture()
        guard case .committed(let initial, _) = makeWriter(container)
            .commit(content(), expecting: .missing)
        else {
            return XCTFail("Expected initial commit.")
        }
        let flockCalls = IntegerBox()
        let fixedName =
            SettingsPrimaryPublication.temporaryPrefix + "61"
        let result = makeWriter(
            container,
            lockSystemHook: { call in
                switch call {
                case .flock:
                    return flockCalls.increment() > 1 ? EIO : nil
                case .closeSettings:
                    return EIO
                default:
                    return nil
                }
            },
            nameSource: { 0x61 }
        ).commit(
            content(appearance: "light"),
            expecting: .version(initial.versionToken)
        )

        guard case .recoveryRequired(let evidence) = result,
              case .committedPublicationAndLock(
                let publication,
                let lock
              ) = evidence.failure,
              case .displacedPrior(let name, let token) =
                evidence.residual
        else {
            return XCTFail("Expected committed publication plus lock evidence.")
        }
        XCTAssertEqual(evidence.classification, .target)
        XCTAssertEqual(evidence.priorToken, initial.versionToken)
        XCTAssertEqual(evidence.targetToken?.revision.rawValue, 2)
        XCTAssertEqual(name, fixedName)
        XCTAssertEqual(token, initial.versionToken)
        XCTAssertEqual(publication.classification, .target)
        XCTAssertTrue(publication.targetProofEligible)
        XCTAssertEqual(publication.residual, evidence.residual)
        XCTAssertEqual(publication.priorToken, evidence.priorToken)
        XCTAssertEqual(publication.targetToken, evidence.targetToken)
        guard case .cleanup = lock else {
            return XCTFail("Expected typed cleanup failure.")
        }
        XCTAssertEqual(flockCalls.value, 1)
        XCTAssertEqual(
            try Data(
                contentsOf: settings(container)
                    .appendingPathComponent(fixedName)
            ),
            initial.originalBytes
        )
    }

    func testDefinitiveIncompleteSwapClassificationSurvivesLockCleanup()
        throws
    {
        let container = try fixture()
        guard case .committed(let initial, _) = makeWriter(container)
            .commit(content(), expecting: .missing)
        else {
            return XCTFail("Expected initial commit.")
        }
        let unexpected = try SettingsDocumentCodec().encode(
            document(revision: 78, appearance: "dark")
        )
        let primaryURL = primary(container)
        let flockCalls = IntegerBox()
        let result = makeWriter(
            container,
            lockSystemHook: { call in
                switch call {
                case .flock:
                    return flockCalls.increment() > 1 ? EIO : nil
                case .closeSettings:
                    return EIO
                default:
                    return nil
                }
            },
            boundaryHook: { boundary in
                guard boundary == .afterCompareAndSwap else { return }
                try? FileManager.default.removeItem(at: primaryURL)
                _ = FileManager.default.createFile(
                    atPath: primaryURL.path,
                    contents: unexpected
                )
                _ = Darwin.chmod(primaryURL.path, 0o600)
            },
            nameSource: { 0x62 }
        ).commit(
            content(appearance: "light"),
            expecting: .version(initial.versionToken)
        )

        guard case .recoveryRequired(let evidence) = result,
              case .publicationAndLock(let publication, _) =
                evidence.failure
        else {
            return XCTFail("Expected publication plus lock evidence.")
        }
        XCTAssertEqual(publication.classification, .neither)
        XCTAssertFalse(publication.targetProofEligible)
        XCTAssertEqual(evidence.classification, .neither)
        XCTAssertEqual(flockCalls.value, 1)
        XCTAssertEqual(
            try primaryBytes(container),
            try SettingsDocumentCodec().encode(
                document(revision: 2, appearance: "light")
            )
        )
    }

    func testIncompleteIndeterminateProofCannotFreshUpgradeToTarget()
        throws
    {
        let container = try fixture()
        guard case .committed(let initial, _) = makeWriter(container)
            .commit(content(), expecting: .missing)
        else {
            return XCTFail("Expected initial commit.")
        }
        let unexpected = try SettingsDocumentCodec().encode(
            document(revision: 79, appearance: "dark")
        )
        let primaryURL = primary(container)
        let reads = IntegerBox()
        let result = makeWriter(
            container,
            lockSystemHook: { call in
                call == .closeSettings ? EIO : nil
            },
            boundaryHook: { boundary in
                guard boundary == .afterCompareAndSwap else { return }
                try? FileManager.default.removeItem(at: primaryURL)
                _ = FileManager.default.createFile(
                    atPath: primaryURL.path,
                    contents: unexpected
                )
                _ = Darwin.chmod(primaryURL.path, 0o600)
            },
            inspectionSystemHook: { call in
                guard call == .inspectPrimaryPath else { return nil }
                return reads.increment() == 3 ? EIO : nil
            },
            nameSource: { 0x63 }
        ).commit(
            content(appearance: "light"),
            expecting: .version(initial.versionToken)
        )

        guard case .recoveryRequired(let evidence) = result,
              case .publicationAndLock(let publication, _) =
                evidence.failure
        else {
            return XCTFail("Expected publication plus lock evidence.")
        }
        XCTAssertEqual(publication.classification, .indeterminate)
        XCTAssertFalse(publication.targetProofEligible)
        XCTAssertNotNil(publication.classificationReadFailure)
        XCTAssertEqual(evidence.classification, .neither)
        XCTAssertGreaterThanOrEqual(reads.value, 4)
        XCTAssertEqual(
            try primaryBytes(container),
            try SettingsDocumentCodec().encode(
                document(revision: 2, appearance: "light")
            )
        )
    }

    func testInjectedCloseStillRealClosesAndReportsCommittedTarget()
        throws
    {
        let container = try fixture()
        let result = makeWriter(
            container,
            systemHook: { call in
                call == .closeTemporary ? EIO : nil
            }
        ).commit(content(), expecting: .missing)
        assertRecovery(result, classification: .target)
        XCTAssertEqual(try publicationTemporaries(container), [])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: primary(container).path
        ))
    }

    func testLockCleanupFailureReacquiresAndClassifiesCommittedTarget()
        throws
    {
        let container = try fixture()
        let result = makeWriter(
            container,
            lockSystemHook: { call in
                call == .closeSettings ? EIO : nil
            }
        ).commit(content(), expecting: .missing)

        assertRecovery(result, classification: .target)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: primary(container).path
        ))
        XCTAssertEqual(try publicationTemporaries(container), [])
    }

    func testEveryTerminalPreparationCauseSurvivesLockCleanupFailure()
        throws
    {
        var results: [SettingsRepositoryCommitResult] = []
        let closeSettingsFailure:
            SettingsPrimaryMutationLock.SystemCallHook = { call in
                call == .closeSettings ? EIO : nil
            }

        let invalid = try fixture()
        results.append(
            makeWriter(
                invalid,
                lockSystemHook: closeSettingsFailure
            ).commit(content(appearance: "sepia"), expecting: .missing)
        )

        let future = try fixture()
        try installPrimary(
            Data(#"{"schemaVersion":2,"future":true}"#.utf8),
            in: future
        )
        results.append(
            makeWriter(
                future,
                lockSystemHook: closeSettingsFailure
            ).commit(content(), expecting: .missing)
        )

        let corrupt = try fixture()
        try installPrimary(Data(#"{"schemaVersion":1}"#.utf8), in: corrupt)
        results.append(
            makeWriter(
                corrupt,
                lockSystemHook: closeSettingsFailure
            ).commit(content(), expecting: .missing)
        )

        let overflow = try fixture()
        let overflowDocument = document(revision: UInt64.max)
        let overflowBytes = try SettingsDocumentCodec()
            .encode(overflowDocument)
        try installPrimary(overflowBytes, in: overflow)
        results.append(
            makeWriter(
                overflow,
                lockSystemHook: closeSettingsFailure
            ).commit(
                content(),
                expecting: .version(
                    SettingsVersionToken(
                        revision: overflowDocument.revision,
                        sourceSHA256:
                            SettingsSourceSHA256(overflowBytes)
                    )
                )
            )
        )

        let stale = try fixture()
        let staleDocument = document(revision: 4)
        let staleBytes = try SettingsDocumentCodec().encode(staleDocument)
        try installPrimary(staleBytes, in: stale)
        results.append(
            makeWriter(
                stale,
                lockSystemHook: closeSettingsFailure
            ).commit(content(), expecting: .missing)
        )

        let unavailable = try fixture()
        let unavailableBytes = try SettingsDocumentCodec().encode(
            document(revision: 5)
        )
        try installPrimary(unavailableBytes, in: unavailable)
        try chmod(primary(unavailable), 0o644)
        results.append(
            makeWriter(
                unavailable,
                lockSystemHook: closeSettingsFailure
            ).commit(content(), expecting: .missing)
        )

        XCTAssertEqual(results.count, 6)
        for (index, result) in results.enumerated() {
            guard case .recoveryRequired(let evidence) = result,
                  case .terminalAndLock(
                    let terminal,
                    let lock
                  ) = evidence.failure
            else {
                return XCTFail(
                    "Expected terminal plus lock evidence at \(index)."
                )
            }
            if index == 5 {
                XCTAssertEqual(evidence.classification, .indeterminate)
            } else {
                XCTAssertEqual(evidence.classification, .prior)
            }
            guard case .cleanup = lock else {
                return XCTFail("Expected typed cleanup failure.")
            }
            switch index {
            case 0:
                guard case .invalidTarget = terminal else {
                    return XCTFail("Expected invalid target.")
                }
            case 1:
                XCTAssertEqual(terminal, .futureSchema(2))
            case 2:
                guard case .corrupt = terminal else {
                    return XCTFail("Expected corrupt cause.")
                }
            case 3:
                XCTAssertEqual(terminal, .revisionOverflow)
            case 4:
                XCTAssertEqual(terminal, .expectationMismatch)
            default:
                guard case .unavailable = terminal else {
                    return XCTFail("Expected unavailable cause.")
                }
            }
        }
    }

    func testCombinedAcquisitionAndCleanupEvidenceRemainsTyped() throws {
        let container = try fixture()
        let result = makeWriter(
            container,
            lockSystemHook: { call in
                switch call {
                case .flock:
                    return EIO
                case .closeSettings:
                    return EBADF
                default:
                    return nil
                }
            }
        ).commit(content(), expecting: .missing)

        guard case .recoveryRequired(let evidence) = result,
              case .lock(
                .acquisitionAndCleanup(let primary, let cleanup)
              ) = evidence.failure
        else {
            return XCTFail("Expected typed acquisition plus cleanup.")
        }
        XCTAssertEqual(
            primary,
            .systemCall(
                .init(operation: "acquire settings lock", code: EIO)
            )
        )
        XCTAssertTrue(
            cleanup.failures.contains(
                .init(operation: "close Settings directory", code: EBADF)
            )
        )
    }

    func testMutationAuthorityExpiresAndRejectsCrossThreadUse() throws {
        let container = try fixture()
        let authorityBox = MutationAuthorityBox()
        try makeLock(container).withMutationLock { authority in
            authorityBox.value = authority

            let expectation = expectation(
                description: "cross-thread authority returns"
            )
            DispatchQueue.global().async {
                authorityBox.crossThreadResult = authority.readPrimary()
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 2)
            XCTAssertEqual(
                authorityBox.crossThreadResult,
                .failure(.expiredAuthority)
            )
        }
        XCTAssertEqual(
            authorityBox.value?.readPrimary(),
            .failure(.expiredAuthority)
        )
    }

    func testMutationAuthorityRejectsSameThreadReentryDuringPublish()
        throws
    {
        let container = try fixture()
        let authorityBox = MutationAuthorityBox()
        let reentryBox = MutationReadResultBox()
        let lock = makeLock(
            container,
            boundaryHook: { boundary in
                guard boundary == .afterTemporaryOpen,
                      let authority = authorityBox.value
                else {
                    return
                }
                reentryBox.value = authority.readPrimary()
            }
        )
        let target = document(revision: 1)
        let bytes = try SettingsDocumentCodec().encode(target)
        let prepared = SettingsPrimaryPreparedPublication(
            prior: .missing,
            targetDocument: target,
            targetBytes: bytes,
            targetToken: SettingsVersionToken(
                revision: target.revision,
                sourceSHA256: SettingsSourceSHA256(bytes)
            )
        )

        try lock.withMutationLock { authority in
            authorityBox.value = authority
            XCTAssertEqual(
                authority.publishPrepared(prepared),
                .committed(residual: nil)
            )
        }
        XCTAssertEqual(
            reentryBox.value,
            .failure(.reentrantAuthorityOperation)
        )
    }

    private func assertRecovery(
        _ result: SettingsRepositoryCommitResult,
        classification: SettingsPrimaryMutationClassification,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case .recoveryRequired(let evidence) = result else {
            return XCTFail(
                "Expected recovery-required result.",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            evidence.classification,
            classification,
            file: file,
            line: line
        )
    }

    private func makeWriter(
        _ container: URL,
        lockSystemHook:
            @escaping SettingsPrimaryMutationLock.SystemCallHook = {
                _ in nil
            },
        systemHook:
            @escaping SettingsPrimaryPublication.SystemCallHook = {
                _ in nil
            },
        writeHook:
            @escaping SettingsPrimaryPublication.WriteHook = {
                _, _, _ in .system
            },
        aclHook:
            @escaping SettingsPrimaryPublication.ACLHook = {
                _ in .system
            },
        boundaryHook:
            @escaping SettingsPrimaryPublication.BoundaryHook = {
                _ in
            },
        inspectionSystemHook:
            @escaping SettingsPrimaryFileAccess.SystemCallHook = {
                _ in nil
            },
        nameSource:
            @escaping SettingsPrimaryPublication.NameSource = {
                UInt64.random(in: UInt64.min ... UInt64.max)
            }
    ) -> SettingsRepositoryWriter {
        SettingsRepositoryWriter(
            mutationLock: makeLock(
                container,
                lockSystemHook: lockSystemHook,
                systemHook: systemHook,
                writeHook: writeHook,
                aclHook: aclHook,
                boundaryHook: boundaryHook,
                inspectionSystemHook: inspectionSystemHook,
                nameSource: nameSource
            )
        )
    }

    private func makeLock(
        _ container: URL,
        lockSystemHook:
            @escaping SettingsPrimaryMutationLock.SystemCallHook = {
                _ in nil
            },
        systemHook:
            @escaping SettingsPrimaryPublication.SystemCallHook = {
                _ in nil
            },
        writeHook:
            @escaping SettingsPrimaryPublication.WriteHook = {
                _, _, _ in .system
            },
        aclHook:
            @escaping SettingsPrimaryPublication.ACLHook = {
                _ in .system
            },
        boundaryHook:
            @escaping SettingsPrimaryPublication.BoundaryHook = {
                _ in
            },
        inspectionSystemHook:
            @escaping SettingsPrimaryFileAccess.SystemCallHook = {
                _ in nil
            },
        nameSource:
            @escaping SettingsPrimaryPublication.NameSource = {
                UInt64.random(in: UInt64.min ... UInt64.max)
            }
    ) -> SettingsPrimaryMutationLock {
        SettingsPrimaryMutationLock(
            trustedContainerURL: container,
            systemCallHook: lockSystemHook,
            inspectionSystemCallHook: inspectionSystemHook,
            publicationSystemCallHook: systemHook,
            publicationWriteHook: writeHook,
            publicationACLHook: aclHook,
            publicationBoundaryHook: boundaryHook,
            publicationNameSource: nameSource
        )
    }

    private func content(
        appearance: String = "system"
    ) -> SettingsContent {
        SettingsContent(document: document(revision: 99, appearance: appearance))
    }

    private func document(
        revision: UInt64,
        appearance: String = "system"
    ) -> SettingsDocument {
        SettingsDocument(
            revision: SettingsRevision(rawValue: revision),
            profileTemplates: [
                .init(
                    id: "00000000-0000-4000-8000-000000000001",
                    name: "Work",
                    argumentsText: "--safe",
                    environmentText: "A=1",
                    notes: "Fixture"
                ),
            ],
            defaultBaseStoragePath: "/Managed",
            confirmBeforeLaunch: true,
            automaticallyRecoverCrashedApps: false,
            appearance: appearance,
            profileVisualIdentities: []
        )
    }

    private func fixture() throws -> URL {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent(
                "px-repository-mutation-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        try chmod(root, 0o700)
        temporaryDirectories.append(root)

        let settingsURL = settings(root)
        try FileManager.default.createDirectory(
            at: settingsURL,
            withIntermediateDirectories: false
        )
        try chmod(settingsURL, 0o700)
        let lock = settingsURL.appendingPathComponent(
            SettingsPrimaryMutationLock.lockName
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: lock.path,
            contents: Data()
        ))
        try chmod(lock, 0o600)
        return root
    }

    private func installPrimary(
        _ bytes: Data,
        in container: URL
    ) throws {
        XCTAssertTrue(FileManager.default.createFile(
            atPath: primary(container).path,
            contents: bytes
        ))
        try chmod(primary(container), 0o600)
    }

    private func primaryBytes(_ container: URL) throws -> Data {
        try Data(contentsOf: primary(container))
    }

    private func publicationTemporaries(
        _ container: URL
    ) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: settings(container).path
        ).filter {
            $0.hasPrefix(SettingsPrimaryPublication.temporaryPrefix)
        }.sorted()
    }

    private func settings(_ container: URL) -> URL {
        container.appendingPathComponent(
            SettingsPrimaryMutationLock.settingsName,
            isDirectory: true
        )
    }

    private func primary(_ container: URL) -> URL {
        settings(container).appendingPathComponent(
            SettingsPrimaryFileAccess.primaryName
        )
    }

    private func chmod(_ url: URL, _ value: mode_t) throws {
        guard Darwin.chmod(url.path, value) == 0 else {
            throw POSIXError(
                POSIXErrorCode(rawValue: errno) ?? .EIO
            )
        }
    }

    private func mode(_ url: URL) -> UInt16 {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            return UInt16.max
        }
        return UInt16(value.st_mode & 0o7777)
    }
}

private final class IntegerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int {
        lock.withLock { stored }
    }

    func increment() -> Int {
        lock.withLock {
            stored += 1
            return stored
        }
    }
}

private final class MutationAuthorityBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: SettingsPrimaryMutationAuthority?
    private var storedCrossThreadResult: Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    >?

    var value: SettingsPrimaryMutationAuthority? {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }

    var crossThreadResult: Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    >? {
        get { lock.withLock { storedCrossThreadResult } }
        set { lock.withLock { storedCrossThreadResult = newValue } }
    }
}

private final class MutationReadResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    >?

    var value: Result<
        SettingsPrimaryFileReadResult,
        SettingsPrimaryLockedInspectionError
    >? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class CommitResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: SettingsRepositoryCommitResult?

    var value: SettingsRepositoryCommitResult? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
