import Foundation
import XCTest

@testable import Parallax

@MainActor
final class ActivityPersistenceAuditRegressionTests: XCTestCase {
    private func root() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func record(
        _ store: LaunchHistoryStore, application: ManagedApplication, requestID: UUID,
        state: ProfileLaunchLifecycleState, date: Date
    ) throws {
        let profile = try XCTUnwrap(application.profiles.first)
        store.record(
            ProfileLaunchLifecycleSnapshot(
                requestID: requestID,
                identity: ProfileActivityIdentity(
                    applicationID: application.id, applicationStorageID: application.storageID,
                    profileID: profile.id, profileStorageID: profile.storageID), state: state),
            application: application, profile: profile, fallbackProfileName: profile.name, at: date)
    }

    private func application() -> ManagedApplication {
        ManagedApplication(
            displayName: "Audit", appPath: "/synthetic/Audit.app",
            profiles: [LaunchProfile(name: "Work")])
    }

    func testFutureHistoryAndWorkaroundSchemasAreNotReplaced() throws {
        let support = root()
        _ = try LaunchHistoryStore(applicationSupportURL: support)
        let history = support.appendingPathComponent("Parallax/launch-history.json")
        let historyBytes = Data(#"{"schemaVersion":999,"entries":[]}"#.utf8)
        try historyBytes.write(to: history)
        XCTAssertNotNil(
            try LaunchHistoryStore(applicationSupportURL: support).persistenceErrorMessage)
        XCTAssertEqual(try Data(contentsOf: history), historyBytes)
        let workarounds = support.appendingPathComponent("Parallax/managed-app-workarounds.json")
        let workaroundBytes = Data(#"{"schemaVersion":999,"records":[]}"#.utf8)
        try workaroundBytes.write(to: workarounds)
        XCTAssertNotNil(
            try ManagedAppWorkaroundStore(applicationSupportURL: support).persistenceErrorMessage)
        XCTAssertEqual(try Data(contentsOf: workarounds), workaroundBytes)
    }

    func testHistoryCanSaveAfterVerifiedQuarantine() throws {
        let support = root()
        _ = try LaunchHistoryStore(applicationSupportURL: support)
        let file = support.appendingPathComponent("Parallax/launch-history.json")
        try Data("corrupt".utf8).write(to: file)
        let store = try LaunchHistoryStore(applicationSupportURL: support)
        XCTAssertNotNil(store.persistenceErrorMessage)
        try record(
            store, application: application(), requestID: UUID(), state: .requested, date: Date())
        XCTAssertNil(store.persistenceErrorMessage)
        XCTAssertEqual(try LaunchHistoryStore(applicationSupportURL: support).entries.count, 1)
        XCTAssertEqual(
            try Data(
                contentsOf: support.appendingPathComponent(
                    "Parallax/launch-history.corrupt.retained.json")), Data("corrupt".utf8))
    }

    func testTerminalHistoryWinsAfterClockRollsBack() throws {
        let store = try LaunchHistoryStore(applicationSupportURL: root())
        let app = application()
        let id = UUID()
        try record(
            store, application: app, requestID: id, state: .requested,
            date: Date(timeIntervalSince1970: 100))
        try record(
            store, application: app, requestID: id, state: .terminated(processIdentifier: 123),
            date: Date(timeIntervalSince1970: 90))
        XCTAssertEqual(store.entries.first?.state, .closed)
    }

    func testClearedHistoryCannotBeResurrectedByStalePeer() throws {
        let support = root()
        let first = try LaunchHistoryStore(applicationSupportURL: support)
        let app = application()
        let removed = UUID()
        try record(first, application: app, requestID: removed, state: .requested, date: Date())
        let peer = try LaunchHistoryStore(applicationSupportURL: support)
        first.clearHistory(for: app)
        let fresh = UUID()
        try record(peer, application: app, requestID: fresh, state: .requested, date: Date())
        XCTAssertEqual(
            try LaunchHistoryStore(applicationSupportURL: support).entries.map(\.requestID), [fresh]
        )
    }

    func testTerminatedHistoryUsesLifecycleIdentityInsteadOfReusedPID() throws {
        let state = TestWorkspaceProcessState()
        let store = LaunchHistoryStore(processInspector: state)
        let app = application()
        let profile = try XCTUnwrap(app.profiles.first)
        let original = WorkspaceProcessIdentity(
            process: ProcessStartIdentity(
                processIdentifier: 7004, startTimeSeconds: 1, startTimeMicroseconds: 0),
            application: WorkspaceApplicationBundleIdentity(
                bundleURL: URL(fileURLWithPath: app.appPath), bundleIdentifier: app.bundleIdentifier
            ))
        store.record(
            ProfileLaunchLifecycleSnapshot(
                requestID: UUID(),
                identity: ProfileActivityIdentity(
                    applicationID: app.id, applicationStorageID: app.storageID,
                    profileID: profile.id, profileStorageID: profile.storageID),
                state: .terminated(processIdentifier: 7004), processIdentity: original),
            application: app, profile: profile, fallbackProfileName: profile.name)
        XCTAssertEqual(store.entries.first?.process, original.process)
    }

    func testRecoveryPreservesFutureEvidenceAndUsesBlockingCrashForRetryTime() throws {
        let key = ManagedAppRecoveryKey(applicationStorageID: UUID(), profileStorageID: UUID())
        let ledger = try ManagedAppRecoveryLedger(
            applicationSupportURL: root(), maximumAttempts: 2, rollingWindow: 100)
        for value in [100.0, 110, 120] {
            _ = try ledger.decision(for: key, confirmedCrashAt: Date(timeIntervalSince1970: value))
        }
        XCTAssertEqual(
            try ledger.decision(for: key, confirmedCrashAt: Date(timeIntervalSince1970: 90)),
            .circuitOpen(retryAfter: Date(timeIntervalSince1970: 210)))
        var policy = ManagedAppRecoveryPolicy(maximumAttempts: 2, rollingWindow: 100)
        for value in [100.0, 110, 120] {
            _ = policy.decision(for: key, confirmedCrashAt: Date(timeIntervalSince1970: value))
        }
        XCTAssertEqual(
            policy.decision(for: key, confirmedCrashAt: Date(timeIntervalSince1970: 90)),
            .circuitOpen(retryAfter: Date(timeIntervalSince1970: 210)))
    }

    private func workaround(_ name: String) -> ManagedAppWorkaroundRecord {
        ManagedAppWorkaroundRecord(
            applicationStorageID: UUID(), profileStorageID: UUID(), workaroundID: name,
            displayName: name, definitionVersion: 1, configurationReference: "setting",
            state: .verified, updatedAt: Date(), operatorNote: nil)
    }

    func testWorkaroundMutationsMergeWithPeerAndRollbackOnFailure() throws {
        let support = root()
        let first = try ManagedAppWorkaroundStore(applicationSupportURL: support)
        let peer = try ManagedAppWorkaroundStore(applicationSupportURL: support)
        let one = workaround("one")
        let two = workaround("two")
        XCTAssertTrue(first.upsert(one))
        XCTAssertTrue(peer.upsert(two))
        XCTAssertEqual(
            Set(try ManagedAppWorkaroundStore(applicationSupportURL: support).records.map(\.id)),
            [one.id, two.id])
        let file = support.appendingPathComponent("Parallax/managed-app-workarounds.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let before = peer.records
        XCTAssertFalse(peer.upsert(workaround("three")))
        XCTAssertEqual(peer.records, before)
    }
}
