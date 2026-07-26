import Foundation
import XCTest
@testable import Parallax

final class ProfileDataTransactionCoordinatorTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Secure-Profile-Transactions-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testDuplicateUsesSecureStagingAndPreparedRepositoryCommit() throws {
        let fixture = try makeFixture(operation: .duplicate)
        try writeSentinel("source", at: fixture.source.profileRoot.url)

        let outcome = try fixture.coordinator.execute(
            fixture.request,
            preparedCommit: fixture.preparedCommit,
            repository: fixture.repository
        )

        XCTAssertEqual(outcome.dataMutation, .copiedManagedData)
        XCTAssertEqual(
            try String(contentsOf: sentinel(at: fixture.destination.profileRoot.url)),
            "source"
        )
        XCTAssertEqual(try loadedToken(fixture.repository), fixture.preparedCommit.targetVersion)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.receiptURL.path))
        XCTAssertTrue(try fixture.coordinator.pendingTransactions().isEmpty)
    }

    func testStaleWriterBeforeFirstEffectLeavesNoPendingTransaction() throws {
        let fixture = try makeFixture(operation: .duplicate)
        try writeSentinel("source", at: fixture.source.profileRoot.url)
        var competingApplication = fixture.initialApplication
        competingApplication.displayName = "Competing writer"
        let competing = try fixture.repository.save(
            [competingApplication],
            expectedVersion: fixture.preparedCommit.priorVersion
        )

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        ) { error in
            guard case LibraryRepositoryError.staleWriter = error else {
                return XCTFail("Expected stale writer, got \(error)")
            }
        }

        let restarted = try makeCoordinator(
            applicationSupportURL: fixture.applicationSupportURL
        )
        XCTAssertTrue(try restarted.pendingTransactions().isEmpty)
        XCTAssertEqual(try loadedToken(fixture.repository), competing.versionToken)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.applicationSupportURL
                    .appendingPathComponent(
                        "Parallax/ProfileTransactions/"
                            + fixture.transactionID.uuidString.lowercased()
                            + ".plan.json"
                    )
                    .path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.destination.profileRoot.url.path
            )
        )
    }

    func testDuplicateNeverOverwritesUnexpectedDestination() throws {
        let fixture = try makeFixture(operation: .duplicate)
        try writeSentinel("source", at: fixture.source.profileRoot.url)
        try writeSentinel("independent", at: fixture.destination.profileRoot.url)

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? ProfileDataTransactionError)?.code,
                .unexpectedDestination
            )
        }

        XCTAssertEqual(
            try String(contentsOf: sentinel(at: fixture.destination.profileRoot.url)),
            "independent"
        )
        XCTAssertEqual(try loadedToken(fixture.repository), fixture.preparedCommit.priorVersion)
        XCTAssertTrue(try fixture.coordinator.pendingTransactions().isEmpty)
    }

    func testClearMissingDataIsNoOpAndDoesNotCreateManagedRoot() throws {
        let fixture = try makeFixture(operation: .clear)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.source.profileRoot.url.path)
        )

        let outcome = try fixture.coordinator.execute(
            fixture.request,
            preparedCommit: fixture.preparedCommit,
            repository: fixture.repository
        )

        XCTAssertEqual(outcome.dataMutation, .noManagedData)
        XCTAssertFalse(outcome.didArchiveData)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.source.profileRoot.url.path)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.source.profileRoot.validationContext
                    .canonicalBaseRootURL
                    .appendingPathComponent(".parallax/Transactions")
                    .path
            )
        )
        XCTAssertEqual(try loadedToken(fixture.repository), fixture.preparedCommit.targetVersion)
    }

    func testRestartWithPriorLibraryRollsBackPublishedDuplicate() throws {
        let crash = TransactionCrash(
            boundary: .afterEffectBeforeRecord(.publishDestination)
        )
        let fixture = try makeFixture(operation: .duplicate, crash: crash)
        try writeSentinel("source", at: fixture.source.profileRoot.url)

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.destination.profileRoot.url.path)
        )
        XCTAssertEqual(try loadedToken(fixture.repository), fixture.preparedCommit.priorVersion)

        let restarted = try makeCoordinator(applicationSupportURL: fixture.applicationSupportURL)
        let recovered = try restarted.recover(
            transactionID: fixture.transactionID,
            repository: LibraryRepository(
                applicationSupportURL: fixture.applicationSupportURL
            )
        )

        XCTAssertEqual(recovered.dataMutation, .rolledBack)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.destination.profileRoot.url.path)
        )
    }

    func testRestartWithTargetLibraryFinalizesAfterCommitBoundaryCrash() throws {
        let crash = TransactionCrash(
            boundary: .afterEffectBeforeRecord(.commitMetadata)
        )
        let fixture = try makeFixture(operation: .duplicate, crash: crash)
        try writeSentinel("source", at: fixture.source.profileRoot.url)

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )
        XCTAssertEqual(try loadedToken(fixture.repository), fixture.preparedCommit.targetVersion)

        let restarted = try makeCoordinator(applicationSupportURL: fixture.applicationSupportURL)
        let recovered = try restarted.recover(
            transactionID: fixture.transactionID,
            repository: LibraryRepository(
                applicationSupportURL: fixture.applicationSupportURL
            )
        )

        XCTAssertEqual(recovered.dataMutation, .copiedManagedData)
        XCTAssertEqual(
            try String(contentsOf: sentinel(at: fixture.destination.profileRoot.url)),
            "source"
        )
    }

    func testPendingDiscoveryNeedsNoCurrentModelOrManagedRoot() throws {
        let crash = TransactionCrash(
            boundary: .afterEffectBeforeRecord(.copyToStaging)
        )
        let fixture = try makeFixture(operation: .duplicate, crash: crash)
        try writeSentinel("source", at: fixture.source.profileRoot.url)
        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )

        let restarted = try makeCoordinator(applicationSupportURL: fixture.applicationSupportURL)
        let pending = try restarted.pendingTransactions()

        XCTAssertEqual(pending.map(\.transactionID), [fixture.transactionID])
        XCTAssertEqual(pending.first?.identity, fixture.request.identity)
        XCTAssertEqual(pending.first?.operation, .duplicate)
    }

    func testHostileRecordTamperStopsRecoveryWithoutDeletingData() throws {
        let crash = TransactionCrash(
            boundary: .afterEffectBeforeRecord(.publishDestination)
        )
        let fixture = try makeFixture(operation: .duplicate, crash: crash)
        try writeSentinel("source", at: fixture.source.profileRoot.url)
        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )
        let record = try XCTUnwrap(
            try transactionFiles(fixture).first {
                $0.lastPathComponent.hasSuffix(".record.json")
            }
        )
        var bytes = try Data(contentsOf: record)
        bytes.append(0x20)
        try bytes.write(to: record)

        let restarted = try makeCoordinator(applicationSupportURL: fixture.applicationSupportURL)
        XCTAssertThrowsError(
            try restarted.recover(
                transactionID: fixture.transactionID,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? ProfileDataTransactionError)?.code,
                .invalidJournal
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.destination.profileRoot.url.path)
        )
    }

    func testNeitherLibraryStatePreservesAllDataAndRequiresRecovery() throws {
        let crash = TransactionCrash(
            boundary: .afterEffectBeforeRecord(.publishDestination)
        )
        let fixture = try makeFixture(operation: .duplicate, crash: crash)
        try writeSentinel("source", at: fixture.source.profileRoot.url)
        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )

        let thirdApplication = fixture.initialApplication
        let thirdSnapshot = try fixture.repository.save(
            [thirdApplication],
            expectedVersion: fixture.preparedCommit.priorVersion
        )
        XCTAssertNotEqual(thirdSnapshot.versionToken, fixture.preparedCommit.targetVersion)

        let restarted = try makeCoordinator(applicationSupportURL: fixture.applicationSupportURL)
        XCTAssertThrowsError(
            try restarted.recover(
                transactionID: fixture.transactionID,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? ProfileDataTransactionError)?.code,
                .ambiguousLibraryState
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.source.profileRoot.url.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.destination.profileRoot.url.path)
        )
    }

    func testIndependentExactContentDestinationIsNeverRemoved() throws {
        let crash = TransactionCrash(
            boundary: .afterEffectBeforeRecord(.copyToStaging)
        )
        let fixture = try makeFixture(operation: .duplicate, crash: crash)
        try writeSentinel("same", at: fixture.source.profileRoot.url)
        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )
        try FileManager.default.copyItem(
            at: fixture.source.profileRoot.url,
            to: fixture.destination.profileRoot.url
        )

        let restarted = try makeCoordinator(applicationSupportURL: fixture.applicationSupportURL)
        _ = try restarted.recover(
            transactionID: fixture.transactionID,
            repository: fixture.repository
        )

        XCTAssertEqual(
            try String(contentsOf: sentinel(at: fixture.destination.profileRoot.url)),
            "same"
        )
    }

    func testSecureRenameRejectsAncestorSwapWithoutTouchingOutside() throws {
        let fixture = try makeFixture(operation: .duplicate)
        try writeSentinel("source", at: fixture.source.profileRoot.url)
        let outside = temporaryDirectory.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let swap = SecureSwap(
            parent: fixture.destination.profileRoot.url.deletingLastPathComponent(),
            outside: outside
        )
        let coordinator = try makeCoordinator(
            applicationSupportURL: fixture.applicationSupportURL,
            secureBoundary: { root, boundary in
                try swap.perform(root: root, boundary: boundary)
            }
        )

        XCTAssertThrowsError(
            try coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty
        )
        XCTAssertEqual(try loadedToken(fixture.repository), fixture.preparedCommit.priorVersion)
    }

    func testReceiptTamperIsDetectedFromExactBytesAndRecordedHash() throws {
        let fixture = try makeFixture(operation: .duplicate)
        try writeSentinel("source", at: fixture.source.profileRoot.url)
        let outcome = try fixture.coordinator.execute(
            fixture.request,
            preparedCommit: fixture.preparedCommit,
            repository: fixture.repository
        )
        try Data("tampered".utf8).write(to: outcome.receiptURL)

        XCTAssertThrowsError(
            try fixture.coordinator.recover(
                transactionID: fixture.transactionID,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? ProfileDataTransactionError)?.code,
                .invalidReceipt
            )
        }
    }

    func testArchiveDeleteAndClearExistingDataUseSecureOwnedMutations() throws {
        for operation in [
            ProfileDataTransactionOperation.archive,
            .delete,
            .clear,
        ] {
            let workspace = temporaryDirectory.appendingPathComponent(
                operation.rawValue,
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: workspace,
                withIntermediateDirectories: true
            )
            let fixture = try makeFixture(
                operation: operation,
                workspace: workspace
            )
            try writeSentinel("source", at: fixture.source.profileRoot.url)

            let outcome = try fixture.coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )

            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: fixture.source.profileRoot.url.path
                ),
                operation.rawValue
            )
            if operation == .delete {
                XCTAssertEqual(outcome.dataMutation, .deletedManagedData)
                XCTAssertFalse(outcome.didArchiveData)
            } else {
                XCTAssertEqual(outcome.dataMutation, .archivedManagedData)
                XCTAssertTrue(outcome.didArchiveData)
                let archive = try XCTUnwrap(outcome.archiveURL)
                XCTAssertEqual(
                    try String(contentsOf: sentinel(at: archive)),
                    "source"
                )
            }
        }
    }

    func testRelocateUsesSecureCrossRootCopyAndOwnedSourceRemoval() throws {
        let fixture = try makeFixture(operation: .relocate)
        try writeSentinel("source", at: fixture.source.profileRoot.url)

        let outcome = try fixture.coordinator.execute(
            fixture.request,
            preparedCommit: fixture.preparedCommit,
            repository: fixture.repository
        )

        XCTAssertEqual(outcome.dataMutation, .relocatedManagedData)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.source.profileRoot.url.path)
        )
        XCTAssertEqual(
            try String(contentsOf: sentinel(at: fixture.destination.profileRoot.url)),
            "source"
        )
    }

    func testDestructiveTransactionsBackUpExactPriorLibraryBeforeCommit() throws {
        for operation in [
            ProfileDataTransactionOperation.archive,
            .delete,
            .relocate,
        ] {
            let workspace = temporaryDirectory.appendingPathComponent(
                "backup-" + operation.rawValue,
                isDirectory: true
            )
            let recorder = BackupRecorder()
            let fixture = try makeFixture(
                operation: operation,
                workspace: workspace,
                backupHook: recorder.record
            )
            let priorBytes = try loadedSnapshot(fixture.repository).originalBytes
            try writeSentinel("source", at: fixture.source.profileRoot.url)

            _ = try fixture.coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )

            let call = try XCTUnwrap(recorder.calls.first)
            XCTAssertEqual(recorder.calls.count, 1, operation.rawValue)
            XCTAssertEqual(call.bytes, priorBytes, operation.rawValue)
            XCTAssertEqual(
                call.reason.rawValue,
                LibraryBackupReason.destructiveRewrite.rawValue,
                operation.rawValue
            )
        }
    }

    func testDestructiveBackupFailureLeavesPriorMetadataAndRollsBackData() throws {
        let recorder = BackupRecorder(error: TestFailure.injected)
        let fixture = try makeFixture(
            operation: .archive,
            backupHook: recorder.record
        )
        try writeSentinel("source", at: fixture.source.profileRoot.url)

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )
        XCTAssertEqual(
            try loadedToken(fixture.repository),
            fixture.preparedCommit.priorVersion
        )

        let recovered = try makeCoordinator(
            applicationSupportURL: fixture.applicationSupportURL
        ).recover(
            transactionID: fixture.transactionID,
            repository: fixture.repository
        )

        XCTAssertEqual(recovered.dataMutation, .rolledBack)
        XCTAssertEqual(
            try String(contentsOf: sentinel(at: fixture.source.profileRoot.url)),
            "source"
        )
        XCTAssertEqual(recorder.calls.count, 1)
    }

    func testEveryDuplicateEffectBoundaryRecoversFromDurableState() throws {
        let effects: [ProfileDataTransactionEffect] = [
            .createTransactionsDirectory,
            .writeOwnerMarker,
            .createStaging,
            .copyToStaging,
            .writePayloadMarker,
            .publishDestination,
            .commitMetadata,
            .removePayloadMarker,
            .removeStaging,
            .removeOwnerMarker,
            .writeReceipt,
        ]
        enum Timing: String, CaseIterable {
            case before
            case afterEffect
            case afterRecord
        }

        for effect in effects {
            for timing in Timing.allCases {
                let workspace = temporaryDirectory.appendingPathComponent(
                    effect.rawValue + "-" + timing.rawValue,
                    isDirectory: true
                )
                try FileManager.default.createDirectory(
                    at: workspace,
                    withIntermediateDirectories: true
                )
                let boundary: ProfileDataTransactionBoundary = switch timing {
                case .before:
                    .beforeEffect(effect)
                case .afterEffect:
                    .afterEffectBeforeRecord(effect)
                case .afterRecord:
                    .afterRecord(effect)
                }
                let crash = TransactionCrash(boundary: boundary)
                let fixture = try makeFixture(
                    operation: .duplicate,
                    crash: crash,
                    workspace: workspace
                )
                try writeSentinel("source", at: fixture.source.profileRoot.url)
                XCTAssertThrowsError(
                    try fixture.coordinator.execute(
                        fixture.request,
                        preparedCommit: fixture.preparedCommit,
                        repository: fixture.repository
                    ),
                    "\(effect.rawValue) \(timing.rawValue)"
                )

                let token = try loadedToken(fixture.repository)
                let restarted = try makeCoordinator(
                    applicationSupportURL: fixture.applicationSupportURL
                )
                let recovered = try restarted.recover(
                    transactionID: fixture.transactionID,
                    repository: LibraryRepository(
                        applicationSupportURL: fixture.applicationSupportURL
                    )
                )

                if token == fixture.preparedCommit.targetVersion {
                    XCTAssertEqual(
                        recovered.dataMutation,
                        .copiedManagedData,
                        "\(effect.rawValue) \(timing.rawValue)"
                    )
                    XCTAssertEqual(
                        try String(
                            contentsOf: sentinel(
                                at: fixture.destination.profileRoot.url
                            )
                        ),
                        "source"
                    )
                } else {
                    XCTAssertEqual(
                        token,
                        fixture.preparedCommit.priorVersion,
                        "\(effect.rawValue) \(timing.rawValue)"
                    )
                    XCTAssertEqual(recovered.dataMutation, .rolledBack)
                }
            }
        }
    }

    func testOperationSpecificEffectBoundariesRecoverFromDurableState() throws {
        let cases: [
            (
                operation: ProfileDataTransactionOperation,
                effects: [ProfileDataTransactionEffect]
            )
        ] = [
            (.archive, [.moveToStaging, .publishArchive]),
            (.delete, [.moveToStaging, .removeDeletedPayload]),
            (
                .relocate,
                [.copyToStaging, .publishDestination, .removeRelocatedSource]
            ),
        ]
        enum Timing: String, CaseIterable {
            case before
            case afterEffect
            case afterRecord
        }

        for testCase in cases {
            for effect in testCase.effects {
                for timing in Timing.allCases {
                    let workspace = temporaryDirectory.appendingPathComponent(
                        [
                            testCase.operation.rawValue,
                            effect.rawValue,
                            timing.rawValue,
                        ].joined(separator: "-"),
                        isDirectory: true
                    )
                    try FileManager.default.createDirectory(
                        at: workspace,
                        withIntermediateDirectories: true
                    )
                    let boundary: ProfileDataTransactionBoundary = switch timing {
                    case .before:
                        .beforeEffect(effect)
                    case .afterEffect:
                        .afterEffectBeforeRecord(effect)
                    case .afterRecord:
                        .afterRecord(effect)
                    }
                    let fixture = try makeFixture(
                        operation: testCase.operation,
                        crash: TransactionCrash(boundary: boundary),
                        workspace: workspace
                    )
                    try writeSentinel("source", at: fixture.source.profileRoot.url)
                    XCTAssertThrowsError(
                        try fixture.coordinator.execute(
                            fixture.request,
                            preparedCommit: fixture.preparedCommit,
                            repository: fixture.repository
                        ),
                        "\(testCase.operation.rawValue) \(effect.rawValue) \(timing.rawValue)"
                    )

                    let token = try loadedToken(fixture.repository)
                    let recovered = try makeCoordinator(
                        applicationSupportURL: fixture.applicationSupportURL
                    ).recover(
                        transactionID: fixture.transactionID,
                        repository: LibraryRepository(
                            applicationSupportURL: fixture.applicationSupportURL
                        )
                    )

                    if token == fixture.preparedCommit.priorVersion {
                        XCTAssertEqual(recovered.dataMutation, .rolledBack)
                        XCTAssertEqual(
                            try String(
                                contentsOf: sentinel(
                                    at: fixture.source.profileRoot.url
                                )
                            ),
                            "source"
                        )
                        if testCase.operation == .relocate {
                            XCTAssertFalse(
                                FileManager.default.fileExists(
                                    atPath: fixture.destination.profileRoot.url.path
                                )
                            )
                        }
                    } else {
                        XCTAssertEqual(
                            token,
                            fixture.preparedCommit.targetVersion
                        )
                        XCTAssertFalse(
                            FileManager.default.fileExists(
                                atPath: fixture.source.profileRoot.url.path
                            )
                        )
                        switch testCase.operation {
                        case .archive:
                            XCTAssertEqual(
                                try String(
                                    contentsOf: sentinel(
                                        at: try XCTUnwrap(recovered.archiveURL)
                                    )
                                ),
                                "source"
                            )
                        case .delete:
                            XCTAssertEqual(
                                recovered.dataMutation,
                                .deletedManagedData
                            )
                        case .relocate:
                            XCTAssertEqual(
                                recovered.dataMutation,
                                .relocatedManagedData
                            )
                            XCTAssertEqual(
                                try String(
                                    contentsOf: sentinel(
                                        at: fixture.destination.profileRoot.url
                                    )
                                ),
                                "source"
                            )
                        case .clear, .duplicate:
                            XCTFail("Unexpected operation")
                        }
                    }
                }
            }
        }
    }

    func testPreparedCommitMustDescribeTheRequestedMetadataTransition() throws {
        let fixture = try makeFixture(operation: .duplicate)
        try writeSentinel("source", at: fixture.source.profileRoot.url)
        let mismatched = ProfileDataTransactionRequest(
            transactionID: fixture.transactionID,
            identity: ProfileDataTransactionIdentity(
                applicationID: fixture.request.identity.applicationID,
                applicationStorageID:
                    fixture.request.identity.applicationStorageID,
                sourceProfileID: fixture.request.identity.sourceProfileID,
                sourceProfileStorageID:
                    fixture.request.identity.sourceProfileStorageID
            ),
            operation: .delete,
            source: fixture.source,
            destination: nil,
            externalDataHandling: .notConfigured
        )

        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                mismatched,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? ProfileDataTransactionError)?.code,
                .preparedCommitMismatch
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.source.profileRoot.url.path)
        )
        XCTAssertTrue(try fixture.coordinator.pendingTransactions().isEmpty)
    }

    func testTamperedPublicationOwnerIsPreservedAndRecoveryNeedIsDurable() throws {
        let crash = TransactionCrash(
            boundary: .afterEffectBeforeRecord(.publishDestination)
        )
        let fixture = try makeFixture(operation: .duplicate, crash: crash)
        try writeSentinel("source", at: fixture.source.profileRoot.url)
        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )
        let marker = fixture.destination.profileRoot.url.appendingPathComponent(
            ".parallax-owner-"
                + fixture.transactionID.uuidString.lowercased()
        )
        try Data("not-owner".utf8).write(to: marker)

        let restarted = try makeCoordinator(
            applicationSupportURL: fixture.applicationSupportURL
        )
        XCTAssertThrowsError(
            try restarted.recover(
                transactionID: fixture.transactionID,
                repository: fixture.repository
            )
        ) { error in
            XCTAssertEqual(
                (error as? ProfileDataTransactionError)?.code,
                .unownedData
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.destination.profileRoot.url.path)
        )
        XCTAssertEqual(
            try restarted.pendingTransactions().first?.state,
            ProfileDataTransactionEffect.requireRecovery.rawValue
        )
    }

    func testHostilePlanByteTamperStopsDiscovery() throws {
        let crash = TransactionCrash(
            boundary: .beforeEffect(.createTransactionsDirectory)
        )
        let fixture = try makeFixture(operation: .duplicate, crash: crash)
        try writeSentinel("source", at: fixture.source.profileRoot.url)
        XCTAssertThrowsError(
            try fixture.coordinator.execute(
                fixture.request,
                preparedCommit: fixture.preparedCommit,
                repository: fixture.repository
            )
        )
        let plan = fixture.applicationSupportURL
            .appendingPathComponent(
                "Parallax/ProfileTransactions/"
                    + fixture.transactionID.uuidString.lowercased()
                    + ".plan.json"
            )
        var bytes = try Data(contentsOf: plan)
        bytes.append(0x20)
        try bytes.write(to: plan)

        let restarted = try makeCoordinator(
            applicationSupportURL: fixture.applicationSupportURL
        )
        XCTAssertThrowsError(try restarted.pendingTransactions()) { error in
            XCTAssertEqual(
                (error as? ProfileDataTransactionError)?.code,
                .invalidJournal
            )
        }
    }

    private func makeFixture(
        operation: ProfileDataTransactionOperation,
        crash: TransactionCrash? = nil,
        workspace: URL? = nil,
        backupHook: LibraryBackupHook? = { _, _ in }
    ) throws -> Fixture {
        let workspace = workspace ?? temporaryDirectory
        let managedRoot = workspace.appendingPathComponent("Managed", isDirectory: true)
        let relocatedRoot = workspace.appendingPathComponent(
            "Relocated",
            isDirectory: true
        )
        let applicationSupport = workspace.appendingPathComponent(
            "ApplicationSupport",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: managedRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupport,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: relocatedRoot,
            withIntermediateDirectories: true
        )
        let applicationID = UUID()
        let applicationStorageID = UUID()
        let sourceProfile = LaunchProfile(name: "Source")
        let destinationProfile = LaunchProfile(name: "Destination")
        let initialApplication = ManagedApplication(
            id: applicationID,
            storageID: applicationStorageID,
            displayName: "Test",
            appPath: "/Applications/Test.app",
            baseStoragePath: managedRoot.path,
            profiles: [sourceProfile]
        )
        let repository = LibraryRepository(
            applicationSupportURL: applicationSupport,
            backupHook: backupHook
        )
        let initialPrepared = try repository.prepare(
            [initialApplication],
            expectedVersion: .missing
        )
        let initialSnapshot = try repository.withExclusiveMutation(
            expectedVersion: .missing
        ) {
            try $0.commit(initialPrepared).snapshot
        }

        var target = initialApplication
        let destinationID: UUID?
        switch operation {
        case .duplicate:
            target.profiles.append(destinationProfile)
            destinationID = destinationProfile.id
        case .archive, .delete:
            target.profiles = []
            destinationID = nil
        case .clear:
            destinationID = nil
        case .relocate:
            target.baseStoragePath = relocatedRoot.path
            destinationID = sourceProfile.id
        }
        let preparedCommit = try repository.prepare(
            [target],
            expectedVersion: initialSnapshot.versionToken
        )
        let resolver = ManagedPathResolver(fileSystem: LocalFileSystem())
        let source = try resolver.resolve(
            baseRootURL: managedRoot,
            applicationStorageID: applicationStorageID,
            profileStorageID: sourceProfile.storageID
        )
        let destination = try resolver.resolve(
            baseRootURL: operation == .relocate ? relocatedRoot : managedRoot,
            applicationStorageID: applicationStorageID,
            profileStorageID: operation == .relocate
                ? sourceProfile.storageID
                : destinationProfile.storageID
        )
        let transactionID = UUID()
        let identity = ProfileDataTransactionIdentity(
            applicationID: applicationID,
            applicationStorageID: applicationStorageID,
            sourceProfileID: sourceProfile.id,
            sourceProfileStorageID: sourceProfile.storageID,
            destinationProfileID: destinationID,
            destinationProfileStorageID: operation == .duplicate
                ? destinationProfile.storageID
                : operation == .relocate
                    ? sourceProfile.storageID
                    : nil
        )
        let request = ProfileDataTransactionRequest(
            transactionID: transactionID,
            identity: identity,
            operation: operation,
            source: source,
            destination: operation == .duplicate || operation == .relocate
                ? destination
                : nil,
            externalDataHandling: .notConfigured
        )
        return Fixture(
            transactionID: transactionID,
            coordinator: try makeCoordinator(
                applicationSupportURL: applicationSupport,
                transactionBoundary: { boundary in
                    try crash?.perform(boundary)
                }
            ),
            repository: repository,
            applicationSupportURL: applicationSupport,
            source: source,
            destination: destination,
            request: request,
            preparedCommit: preparedCommit,
            initialApplication: initialApplication
        )
    }

    private func makeCoordinator(
        applicationSupportURL: URL,
        transactionBoundary:
            (@Sendable (ProfileDataTransactionBoundary) throws -> Void)? = nil,
        secureBoundary:
            (@Sendable (URL, SecureManagedFileSystemBoundary) throws -> Void)? = nil
    ) throws -> ProfileDataTransactionCoordinator {
        try ProfileDataTransactionCoordinator(
            applicationSupportURL: applicationSupportURL,
            transactionBoundary: transactionBoundary,
            secureBoundary: secureBoundary
        )
    }

    private func loadedToken(
        _ repository: LibraryRepository
    ) throws -> LibraryVersionToken {
        try loadedSnapshot(repository).versionToken
    }

    private func loadedSnapshot(
        _ repository: LibraryRepository
    ) throws -> LibraryRepositorySnapshot {
        guard case let .loaded(snapshot) = repository.load() else {
            throw TestFailure.unexpectedRepositoryState
        }
        return snapshot
    }

    private func writeSentinel(_ value: String, at directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(value.utf8).write(to: sentinel(at: directory))
    }

    private func sentinel(at directory: URL) -> URL {
        directory.appendingPathComponent("sentinel.txt")
    }

    private func transactionFiles(_ fixture: Fixture) throws -> [URL] {
        let prefix = fixture.transactionID.uuidString.lowercased() + "."
        return try FileManager.default.contentsOfDirectory(
            at: fixture.applicationSupportURL
                .appendingPathComponent("Parallax/ProfileTransactions", isDirectory: true),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(prefix) }
    }
}

private struct Fixture {
    let transactionID: UUID
    let coordinator: ProfileDataTransactionCoordinator
    let repository: LibraryRepository
    let applicationSupportURL: URL
    let source: ResolvedProfilePaths
    let destination: ResolvedProfilePaths
    let request: ProfileDataTransactionRequest
    let preparedCommit: PreparedLibraryCommit
    let initialApplication: ManagedApplication
}

private enum TestFailure: Error {
    case injected
    case unexpectedRepositoryState
}

private final class BackupRecorder: @unchecked Sendable {
    struct Call {
        let bytes: Data
        let reason: LibraryBackupReason
    }

    private let lock = NSLock()
    private let error: Error?
    private var recordedCalls: [Call] = []

    init(error: Error? = nil) {
        self.error = error
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recordedCalls
    }

    func record(_ bytes: Data, reason: LibraryBackupReason) throws {
        lock.lock()
        recordedCalls.append(Call(bytes: bytes, reason: reason))
        lock.unlock()
        if let error {
            throw error
        }
    }
}

private final class TransactionCrash: @unchecked Sendable {
    let boundary: ProfileDataTransactionBoundary
    private var fired = false

    init(boundary: ProfileDataTransactionBoundary) {
        self.boundary = boundary
    }

    func perform(_ observed: ProfileDataTransactionBoundary) throws {
        guard !fired, observed == boundary else { return }
        fired = true
        throw TestFailure.injected
    }
}

private final class SecureSwap: @unchecked Sendable {
    private let parent: URL
    private let outside: URL
    private var fired = false

    init(parent: URL, outside: URL) {
        self.parent = parent
        self.outside = outside
    }

    func perform(
        root: URL,
        boundary: SecureManagedFileSystemBoundary
    ) throws {
        guard
            !fired,
            root.path.hasSuffix("/Managed"),
            boundary == .beforeRename
        else { return }
        fired = true
        if FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.removeItem(at: parent)
        }
        try FileManager.default.createSymbolicLink(
            at: parent,
            withDestinationURL: outside
        )
    }
}
