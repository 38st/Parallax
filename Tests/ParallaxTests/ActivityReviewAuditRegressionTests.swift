import Foundation
import XCTest

@testable import Parallax

struct AuditNoopLauncher: ApplicationLaunching {
    func launch(
        application: ManagedApplication, profile: LaunchProfile,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) throws {
        XCTFail("Unexpected real launch path")
    }
}

actor AuditSecretStore: SecretStoring {
    func store(_ value: SecretValue, for reference: EnvironmentSecretReference) async throws {
        XCTFail("Unexpected secret write")
    }
    func resolve(_ reference: EnvironmentSecretReference) async throws -> SecretValue {
        XCTFail("Unexpected secret read")
        throw SecretStoreError.missing(reference)
    }
    func remove(_ reference: EnvironmentSecretReference) async throws {
        XCTFail("Unexpected secret removal")
    }
}

@MainActor
final class ActivityReviewAuditRegressionTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testCircuitDeadlineActuallyPermitsTheNextCrash() throws {
        let key = ManagedAppRecoveryKey(applicationStorageID: UUID(), profileStorageID: UUID())
        for next in [659.0, 661.0] {
            var policy = ManagedAppRecoveryPolicy(maximumAttempts: 2, rollingWindow: 600)
            let memory = ManagedAppRecoveryLedger(maximumAttempts: 2, rollingWindow: 600)
            let disk = try ManagedAppRecoveryLedger(
                applicationSupportURL: root(), maximumAttempts: 2, rollingWindow: 600)
            for time in [0.0, 60, 120] {
                let date = Date(timeIntervalSince1970: time)
                let result = policy.decision(for: key, confirmedCrashAt: date)
                XCTAssertEqual(try memory.decision(for: key, confirmedCrashAt: date), result)
                XCTAssertEqual(try disk.decision(for: key, confirmedCrashAt: date), result)
                if time == 120 {
                    XCTAssertEqual(
                        result, .circuitOpen(retryAfter: Date(timeIntervalSince1970: 660)))
                }
            }
            let date = Date(timeIntervalSince1970: next)
            let result = policy.decision(for: key, confirmedCrashAt: date)
            XCTAssertEqual(try memory.decision(for: key, confirmedCrashAt: date), result)
            XCTAssertEqual(try disk.decision(for: key, confirmedCrashAt: date), result)
            if next < 660 {
                guard case .circuitOpen = result else { return XCTFail("Must still refuse") }
            } else {
                XCTAssertEqual(result, .retry(after: 8, attempt: 2, maximumAttempts: 2))
            }
        }
    }

    func testZeroRecoveryAttemptsNeverPromisesAnAutomaticRetry() throws {
        let key = ManagedAppRecoveryKey(applicationStorageID: UUID(), profileStorageID: UUID())
        var policy = ManagedAppRecoveryPolicy(maximumAttempts: 0)
        XCTAssertEqual(
            policy.decision(for: key, confirmedCrashAt: Date(timeIntervalSince1970: 1)),
            .circuitOpen(retryAfter: .distantFuture))
        let ledger = ManagedAppRecoveryLedger(maximumAttempts: 0)
        XCTAssertEqual(
            try ledger.decision(for: key, confirmedCrashAt: Date(timeIntervalSince1970: 1)),
            .circuitOpen(retryAfter: .distantFuture))
    }

    func testFutureSchemaWithIncompatibleBodyIsNeverReplaced() throws {
        let root = try root()
        _ = try LaunchHistoryStore(applicationSupportURL: root)
        for name in ["launch-history.json", "managed-app-workarounds.json"] {
            let file = root.appendingPathComponent("Parallax/" + name)
            let bytes = Data(
                #"{"schemaVersion":999,"entries":{"new":true},"records":"new format"}"#.utf8)
            try bytes.write(to: file)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: file.path)
            if name == "launch-history.json" {
                XCTAssertNotNil(
                    try LaunchHistoryStore(applicationSupportURL: root).persistenceErrorMessage)
            } else {
                XCTAssertNotNil(
                    try ManagedAppWorkaroundStore(applicationSupportURL: root)
                        .persistenceErrorMessage)
            }
            XCTAssertEqual(try Data(contentsOf: file), bytes)
        }
    }

    func testDifferentCorruptionsCanEachBeQuarantined() throws {
        let root = try root()
        _ = try LaunchHistoryStore(applicationSupportURL: root)
        for name in ["launch-history.json", "managed-app-workarounds.json"] {
            let file = root.appendingPathComponent("Parallax/" + name)
            for value in ["first corruption", "second corruption"] {
                try Data(value.utf8).write(to: file)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: file.path)
                if name == "launch-history.json" {
                    _ = try LaunchHistoryStore(applicationSupportURL: root)
                } else {
                    _ = try ManagedAppWorkaroundStore(applicationSupportURL: root)
                }
                XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: file)))
            }
        }
    }

    func testHistoryDoesNotAccumulatePermanentTombstones() throws {
        let root = try root()
        let store = try LaunchHistoryStore(applicationSupportURL: root)
        let profile = LaunchProfile(name: "Test")
        let app = ManagedApplication(
            displayName: "Test", appPath: root.appendingPathComponent("Test.app").path,
            profiles: [profile])
        let identity = ProfileActivityIdentity(
            applicationID: app.id, applicationStorageID: app.storageID,
            profileID: profile.id, profileStorageID: profile.storageID)
        for index in 0..<30 {
            store.record(
                .init(requestID: UUID(), identity: identity, state: .requested), application: app,
                profile: profile, fallbackProfileName: profile.name,
                at: Date(timeIntervalSince1970: Double(index)))
            store.clearHistory(for: app)
        }
        let bytes = try Data(
            contentsOf: root.appendingPathComponent("Parallax/launch-history.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertNil(document["removedRequestIDs"])
        XCTAssertLessThan(bytes.count, 1024)
    }

    func testLaterExitRecreatesClearedRunningHistory() throws {
        let root = try root()
        let store = try LaunchHistoryStore(applicationSupportURL: root)
        let profile = LaunchProfile(name: "Test")
        let app = ManagedApplication(
            displayName: "Test", appPath: root.appendingPathComponent("Test.app").path,
            profiles: [profile])
        let identity = ProfileActivityIdentity(
            applicationID: app.id, applicationStorageID: app.storageID,
            profileID: profile.id, profileStorageID: profile.storageID)
        let id = UUID()
        store.record(
            .init(requestID: id, identity: identity, state: .requested), application: app,
            profile: profile, fallbackProfileName: profile.name, at: Date(timeIntervalSince1970: 10)
        )
        let peer = try LaunchHistoryStore(applicationSupportURL: root)
        store.clearHistory(for: app)
        peer.record(
            .init(requestID: id, identity: identity, state: .terminated(processIdentifier: 123)),
            application: app, profile: profile, fallbackProfileName: profile.name,
            at: Date(timeIntervalSince1970: 9))
        XCTAssertEqual(peer.entries.first?.state, .closed)
        XCTAssertEqual(
            try LaunchHistoryStore(applicationSupportURL: root).entries.first?.requestID, id)
    }
}
