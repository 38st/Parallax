import XCTest
@testable import Parallax

final class ManagedAppRecoveryPolicyTests: XCTestCase {
    func testConfirmedCrashesBackOffAndOpenCircuitWithinWindow() {
        var policy = ManagedAppRecoveryPolicy(
            maximumAttempts: 2,
            rollingWindow: 600,
            backoff: [2, 8]
        )
        let key = ManagedAppRecoveryKey(
            applicationStorageID: UUID(),
            profileStorageID: UUID()
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            policy.decision(
                for: key,
                confirmedCrashAt: now
            ),
            .retry(after: 2, attempt: 1, maximumAttempts: 2)
        )
        XCTAssertEqual(
            policy.decision(
                for: key,
                confirmedCrashAt: now.addingTimeInterval(30)
            ),
            .retry(after: 8, attempt: 2, maximumAttempts: 2)
        )
        XCTAssertEqual(
            policy.decision(
                for: key,
                confirmedCrashAt: now.addingTimeInterval(60)
            ),
            .circuitOpen(
                retryAfter: now.addingTimeInterval(600)
            )
        )
    }

    func testCrashWindowAndProfileIdentityContainRecoveryState() {
        var policy = ManagedAppRecoveryPolicy(
            maximumAttempts: 1,
            rollingWindow: 60,
            backoff: [1]
        )
        let first = ManagedAppRecoveryKey(
            applicationStorageID: UUID(),
            profileStorageID: UUID()
        )
        let second = ManagedAppRecoveryKey(
            applicationStorageID: first.applicationStorageID,
            profileStorageID: UUID()
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        _ = policy.decision(for: first, confirmedCrashAt: now)
        XCTAssertEqual(
            policy.decision(
                for: second,
                confirmedCrashAt: now.addingTimeInterval(1)
            ),
            .retry(after: 1, attempt: 1, maximumAttempts: 1)
        )
        XCTAssertEqual(
            policy.decision(
                for: first,
                confirmedCrashAt: now.addingTimeInterval(61)
            ),
            .retry(after: 1, attempt: 1, maximumAttempts: 1)
        )
    }

    @MainActor
    func testLedgerPersistsAndSharesCircuitAcrossStoreInstances()
        throws
    {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let firstLedger = try ManagedAppRecoveryLedger(
            applicationSupportURL: support
        )
        let secondLedger = try ManagedAppRecoveryLedger(
            applicationSupportURL: support
        )
        let key = ManagedAppRecoveryKey(
            applicationStorageID: UUID(),
            profileStorageID: UUID()
        )
        let otherProfile = ManagedAppRecoveryKey(
            applicationStorageID: key.applicationStorageID,
            profileStorageID: UUID()
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(
            try firstLedger.decision(
                for: key,
                confirmedCrashAt: now
            ),
            .retry(after: 2, attempt: 1, maximumAttempts: 2)
        )
        XCTAssertEqual(
            try secondLedger.decision(
                for: key,
                confirmedCrashAt: now.addingTimeInterval(1)
            ),
            .retry(after: 8, attempt: 2, maximumAttempts: 2)
        )
        let reloaded = try ManagedAppRecoveryLedger(
            applicationSupportURL: support
        )
        XCTAssertEqual(
            try reloaded.decision(
                for: key,
                confirmedCrashAt: now.addingTimeInterval(2)
            ),
            .circuitOpen(
                retryAfter: now.addingTimeInterval(600)
            )
        )
        XCTAssertEqual(
            try reloaded.decision(
                for: otherProfile,
                confirmedCrashAt: now.addingTimeInterval(2)
            ),
            .retry(after: 2, attempt: 1, maximumAttempts: 2)
        )

        let file = support.appendingPathComponent(
            "Parallax/managed-app-recovery.json"
        )
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(
                atPath: file.path
            )[.posixPermissions] as? NSNumber
        )
        XCTAssertEqual(permissions.intValue & 0o777, 0o600)
    }

    @MainActor
    func testLedgerFailsClosedWithoutReplacingCorruptEvidence()
        throws
    {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let directory = support.appendingPathComponent(
            "Parallax",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let file = directory.appendingPathComponent(
            "managed-app-recovery.json"
        )
        let corrupt = Data("{corrupt".utf8)
        try corrupt.write(to: file)
        let ledger = try ManagedAppRecoveryLedger(
            applicationSupportURL: support
        )

        XCTAssertThrowsError(
            try ledger.decision(
                for: ManagedAppRecoveryKey(
                    applicationStorageID: UUID(),
                    profileStorageID: UUID()
                ),
                confirmedCrashAt: Date()
            )
        )
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertNotNil(ledger.persistenceErrorMessage)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "parallax-recovery-ledger-\(UUID().uuidString)",
                isDirectory: true
            )
    }
}
