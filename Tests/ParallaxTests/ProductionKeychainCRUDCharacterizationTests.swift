import Foundation
import Security
import XCTest

final class ProductionKeychainCRUDCharacterizationTests: XCTestCase {
    private var cleanupFixtures: [ProductionKeychainFixture] = []

    override func tearDownWithError() throws {
        for fixture in cleanupFixtures {
            verifyCleanup(fixture, context: "tearDown")
        }
        cleanupFixtures.removeAll()
    }

    func testRandomizedCurrentProductionKeychainCRUDAndStatusContract() throws {
        let replay = try KeychainCharacterizationReplay()
        let fixture = ProductionKeychainFixture(replay: replay)
        cleanupFixtures.append(fixture)
        defer { verifyCleanup(fixture, context: "defer") }

        attach(
            replay.description
                + " mode=current-production generic-password "
                + "synchronizable=false data-protection-flag=absent",
            name: "KEY-TEST-001 current-production replay metadata"
        )

        let canaryData = Data("KEY-TEST-001 current production canary".utf8)
        let canary = fixture.runDisposableCanary(data: canaryData)
        assertAudit(fixture)

        if canary.addStatus != errSecSuccess {
            switch ProductionKeychainCapabilityPolicy.disposition(
                for: canary.addStatus,
                required: replay.requiredOnThisHost
            ) {
            case .available:
                throw ProductionKeychainFixtureError.unexpectedStatus(
                    operation: "current-production canary add",
                    expected: [errSecSuccess],
                    actual: canary.addStatus,
                    replay: replay.description
                )
            case .skip:
                throw XCTSkip(
                    "Current production Keychain unavailable on the first "
                        + "mutating canary operation (status \(canary.addStatus)); set "
                        + "\(KeychainCharacterizationReplay.requiredEnvironmentKey)=1 "
                        + "to make this a required failure; \(replay)"
                )
            case .fail:
                throw ProductionKeychainFixtureError
                    .requiredCapabilityUnavailable(
                        status: canary.addStatus,
                        replay: replay.description
                    )
            }
        }

        try expect(
            canary.readStatus,
            equals: errSecSuccess,
            operation: "current-production canary read",
            replay: replay
        )
        guard canary.readData == canary.expectedData else {
            throw ProductionKeychainFixtureError.unexpectedResult(
                operation: "current-production canary read",
                replay: replay.description
            )
        }
        try expect(
            canary.deleteStatus,
            equals: errSecSuccess,
            operation: "current-production canary delete",
            replay: replay
        )
        try expect(
            canary.postDeleteReadStatus,
            equals: errSecItemNotFound,
            operation: "current-production canary post-delete read",
            replay: replay
        )

        var generator = SplitMix64(seed: replay.seed)
        for iteration in 0..<replay.iterations {
            let account = fixture.account(iteration: iteration)
            let initialLength = Int(generator.next() % 257) + 1
            let updatedLength = Int(generator.next() % 513) + 1
            let initial = generator.data(length: initialLength)
            var conflicting = generator.data(length: initialLength)
            if conflicting == initial {
                conflicting.append(0xA5)
            }
            let updated = generator.data(length: updatedLength)

            try expect(
                fixture.read(account: account).0,
                equals: errSecItemNotFound,
                operation: "initial read",
                replay: replay
            )
            try expect(
                fixture.add(initial, account: account),
                equals: errSecSuccess,
                operation: "create",
                replay: replay
            )

            let created = fixture.read(account: account)
            try expect(
                created.0,
                equals: errSecSuccess,
                operation: "read after create",
                replay: replay
            )
            guard created.1 == initial else {
                throw ProductionKeychainFixtureError.unexpectedResult(
                    operation: "read after create",
                    replay: replay.description
                )
            }

            try expect(
                fixture.add(conflicting, account: account),
                equals: errSecDuplicateItem,
                operation: "duplicate create",
                replay: replay
            )
            let afterConflict = fixture.read(account: account)
            try expect(
                afterConflict.0,
                equals: errSecSuccess,
                operation: "duplicate conflict read",
                replay: replay
            )
            guard afterConflict.1 == initial else {
                throw ProductionKeychainFixtureError.unexpectedResult(
                    operation: "duplicate conflict preservation",
                    replay: replay.description
                )
            }

            try expect(
                fixture.update(updated, account: account),
                equals: errSecSuccess,
                operation: "update",
                replay: replay
            )
            let readUpdated = fixture.read(account: account)
            try expect(
                readUpdated.0,
                equals: errSecSuccess,
                operation: "read after update",
                replay: replay
            )
            guard readUpdated.1 == updated else {
                throw ProductionKeychainFixtureError.unexpectedResult(
                    operation: "read after update",
                    replay: replay.description
                )
            }

            try expect(
                fixture.delete(account: account),
                equals: errSecSuccess,
                operation: "delete",
                replay: replay
            )
            try expect(
                fixture.read(account: account).0,
                equals: errSecItemNotFound,
                operation: "read after delete",
                replay: replay
            )
            try expect(
                fixture.delete(account: account),
                equals: errSecItemNotFound,
                operation: "duplicate delete",
                replay: replay
            )
            try expect(
                fixture.update(updated, account: account),
                equals: errSecItemNotFound,
                operation: "update missing item",
                replay: replay
            )
        }

        let cleanupAccount = fixture.account(iteration: replay.iterations)
        try expect(
            fixture.add(generator.data(length: 33), account: cleanupAccount),
            equals: errSecSuccess,
            operation: "cleanup sentinel create",
            replay: replay
        )
        let cleanup = fixture.cleanupAndInspect()
        XCTAssertTrue(
            cleanup.succeeded,
            "Explicit namespace cleanup failed: \(cleanup); \(replay)"
        )
        XCTAssertTrue(
            cleanup.requiredVerification,
            "A successful add must require cleanup verification; \(replay)"
        )
        XCTAssertTrue(
            cleanup.possibleAccountsBeforeCleanup.contains(cleanupAccount),
            "Cleanup must track the disposable sentinel; \(replay)"
        )
        assertAudit(fixture)
    }

    func testOptionalFutureDataProtectionCapabilityProbe() throws {
        let replay = try KeychainCharacterizationReplay()
        let fixture = ProductionKeychainFixture(
            replay: replay,
            mode: .futureDataProtectionProbe
        )
        cleanupFixtures.append(fixture)
        defer { verifyCleanup(fixture, context: "future-DP defer") }

        let result = fixture.runDisposableCanary(
            data: Data("KEY-TEST-001 optional future DP canary".utf8)
        )
        let report = "OPTIONAL future data-protection probe; NOT current-production "
            + "evidence; \(result.statusDescription); \(replay)"
        attach(report, name: "KEY-TEST-001 optional future-DP result")
        print(report)
        assertAudit(fixture)

        if let unavailable = result.firstMutatingUnavailableStatus,
           result.addStatus != errSecSuccess
        {
            XCTAssertTrue(
                ProductionKeychainCapabilityPolicy.unavailableStatuses
                    .contains(unavailable)
            )
            XCTAssertFalse(
                fixture.establishedWriteCapability,
                "An unavailable future-DP add must not create a record"
            )
            return
        }

        try expect(
            result.addStatus,
            equals: errSecSuccess,
            operation: "optional future-DP canary add",
            replay: replay
        )
        try expect(
            result.readStatus,
            equals: errSecSuccess,
            operation: "optional future-DP canary read",
            replay: replay
        )
        guard result.readData == result.expectedData else {
            throw ProductionKeychainFixtureError.unexpectedResult(
                operation: "optional future-DP canary read",
                replay: replay.description
            )
        }
        try expect(
            result.deleteStatus,
            equals: errSecSuccess,
            operation: "optional future-DP canary delete",
            replay: replay
        )
        try expect(
            result.postDeleteReadStatus,
            equals: errSecItemNotFound,
            operation: "optional future-DP post-delete read",
            replay: replay
        )
    }

    func testRequiredCapabilityModeCannotBecomeASkip() throws {
        for status in ProductionKeychainCapabilityPolicy.unavailableStatuses {
            XCTAssertEqual(
                ProductionKeychainCapabilityPolicy.disposition(
                    for: status,
                    required: true
                ),
                .fail
            )
            XCTAssertEqual(
                ProductionKeychainCapabilityPolicy.disposition(
                    for: status,
                    required: false
                ),
                .skip
            )
        }
        XCTAssertTrue(
            try KeychainCharacterizationReplay.requiredMode(
                environment: [
                    KeychainCharacterizationReplay.requiredEnvironmentKey: "1"
                ]
            )
        )
        XCTAssertFalse(
            try KeychainCharacterizationReplay.requiredMode(
                environment: [
                    KeychainCharacterizationReplay.requiredEnvironmentKey: "false"
                ]
            )
        )
        XCTAssertThrowsError(
            try KeychainCharacterizationReplay.requiredMode(
                environment: [
                    KeychainCharacterizationReplay.requiredEnvironmentKey: "tru"
                ]
            )
        )
        let requiredReplay = try KeychainCharacterizationReplay(
            environment: [
                KeychainCharacterizationReplay.requiredEnvironmentKey: "required"
            ],
            runID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        )
        XCTAssertTrue(requiredReplay.requiredOnThisHost)
    }

    func testSeedAndReplayMetadataRegenerateTheRandomizedPayload() throws {
        let runID = UUID(uuidString: "00000000-0000-0000-0000-000000000042")!
        let environment = [
            KeychainCharacterizationReplay.seedEnvironmentKey: "0x1234ABCD"
        ]
        let firstReplay = try KeychainCharacterizationReplay(
            environment: environment,
            runID: runID,
            iterations: 3
        )
        let secondReplay = try KeychainCharacterizationReplay(
            environment: environment,
            runID: runID,
            iterations: 3
        )
        var firstGenerator = SplitMix64(seed: firstReplay.seed)
        var secondGenerator = SplitMix64(seed: secondReplay.seed)

        XCTAssertEqual(
            firstGenerator.data(length: 257),
            secondGenerator.data(length: 257)
        )
        XCTAssertEqual(firstReplay.description, secondReplay.description)
        XCTAssertEqual(
            firstReplay.description,
            "KEY-TEST-001 seed=0x1234ABCD "
                + "run=00000000-0000-0000-0000-000000000042 iterations=3"
        )
    }

    private func assertAudit(
        _ fixture: ProductionKeychainFixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            fixture.audit.violations(
                expectedService: fixture.service,
                accountPrefix: fixture.accountPrefix,
                expectsDataProtection: fixture.mode.usesDataProtectionKeychain
            ),
            [],
            "Every SecItem query must preserve the fixture's exact query shape",
            file: file,
            line: line
        )
    }

    private func verifyCleanup(
        _ fixture: ProductionKeychainFixture,
        context: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let report = fixture.cleanupAndInspect()
        attach(
            "\(context) cleanup \(report); \(fixture.replay)",
            name: "KEY-TEST-001 cleanup evidence"
        )
        if report.requiredVerification {
            XCTAssertTrue(
                report.succeeded,
                "Cleanup or residual inspection failed after a successful add: "
                    + "\(report); \(fixture.replay)",
                file: file,
                line: line
            )
        }
        assertAudit(fixture, file: file, line: line)
    }

    private func attach(_ value: String, name: String) {
        let attachment = XCTAttachment(string: value)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func expect(
        _ actual: OSStatus,
        equals expected: OSStatus,
        operation: String,
        replay: KeychainCharacterizationReplay
    ) throws {
        guard actual == expected else {
            throw ProductionKeychainFixtureError.unexpectedStatus(
                operation: operation,
                expected: [expected],
                actual: actual,
                replay: replay.description
            )
        }
    }
}
