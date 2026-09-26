import Darwin
import Foundation
import XCTest

@testable import Parallax

final class DurableActivityAuditRegressionTests: XCTestCase {
    private func fixture() throws -> (URL, DurableLaunchActivityStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (root, try DurableLaunchActivityStore(applicationSupportURL: root))
    }

    private func identity() -> ProfileActivityIdentity {
        ProfileActivityIdentity(
            applicationID: UUID(), applicationStorageID: UUID(), profileID: UUID(),
            profileStorageID: UUID())
    }

    private let owner = ProcessStartIdentity(
        processIdentifier: 7001, startTimeSeconds: 20, startTimeMicroseconds: 0)

    func testInterruptedWriteDoesNotHideValidRequestIdentity() throws {
        let (_, store) = try fixture()
        let id = UUID()
        let activity = identity()
        try store.createRequest(requestID: id, identity: activity, ownerProcess: owner)
        let directory = store.rootURL.appendingPathComponent(id.uuidString.lowercased())
        try Data("partial".utf8).write(
            to: directory.appendingPathComponent(".tmp-\(UUID().uuidString)"))
        let artifact = try XCTUnwrap(store.artifacts().first)
        XCTAssertEqual(artifact.identity, activity)
        guard case .requestOnly = artifact.state else {
            return XCTFail("Expected recoverable request")
        }
    }

    func testEmptyAndTempOnlyDirectoriesAreAbortedCreates() throws {
        let (_, store) = try fixture()
        for temporary in [false, true] {
            let directory = store.rootURL.appendingPathComponent(UUID().uuidString.lowercased())
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            if temporary {
                try Data("partial".utf8).write(
                    to: directory.appendingPathComponent(".tmp-\(UUID().uuidString)"))
            }
        }
        XCTAssertTrue(store.artifacts().isEmpty)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                at: store.rootURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ).isEmpty)
    }

    func testCorruptMarkerBlocksOnlyItsStorage() throws {
        let (_, store) = try fixture()
        let id = UUID()
        let activity = identity()
        try store.createRequest(requestID: id, identity: activity, ownerProcess: owner)
        let marker = store.rootURL.appendingPathComponent(id.uuidString.lowercased())
            .appendingPathComponent("process.json")
        try Data("invalid".utf8).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        XCTAssertThrowsError(
            try store.createRequest(requestID: UUID(), identity: activity, ownerProcess: owner))
        XCTAssertThrowsError(
            try store.createRequest(
                requestID: UUID(), identity: activity, ownerProcess: owner,
                allowsConcurrentProfile: true
            ))
        XCTAssertNoThrow(
            try store.createRequest(requestID: UUID(), identity: identity(), ownerProcess: owner))
    }

    func testMissingCompletionIsIdempotentAndClearsRecoveredActivity() throws {
        let (root, store) = try fixture()
        let state = TestWorkspaceProcessState()
        let registry = try ProfileActivityRegistry(
            applicationSupportURL: root, processInspector: state)
        let id = UUID()
        let activity = identity()
        let lease = try registry.acquireLaunchLease(identity: activity, requestID: id)
        try store.complete(requestID: id, completion: .terminated)
        XCTAssertNoThrow(try registry.completeDurableLaunch(requestID: id, completion: .terminated))
        lease.release()
        XCTAssertFalse(registry.isActive(identity: activity))
    }

    func testStaleRequestOwnerCannotRemoveNowRunningReceipt() throws {
        let (root, store) = try fixture()
        let state = TestWorkspaceProcessState()
        state.processInspections[owner.processIdentifier] = .live(owner)
        let activity = identity()
        let id = UUID()
        try store.createRequest(requestID: id, identity: activity, ownerProcess: owner)
        let registry = try ProfileActivityRegistry(
            applicationSupportURL: root, processInspector: state)
        _ = try registry.reconcileDurableActivity()
        let running = state.processIdentity(processIdentifier: 7002)
        try store.markOpening(requestID: id)
        try store.recordProcess(requestID: id, process: running)
        state.processInspections[owner.processIdentifier] = .dead
        XCTAssertTrue(registry.isActive(identity: activity))
        XCTAssertEqual(store.artifacts().count, 1)
    }

    func testInterruptedCompletionCleanupCannotReviveReceipt() throws {
        let (root, _) = try fixture()
        let enabled = LaunchTestLocked(false)
        let store = try DurableLaunchActivityStore(applicationSupportURL: root) { boundary in
            if boundary == .afterRename, enabled.value,
                let names = try? FileManager.default.contentsOfDirectory(
                    atPath: root.appendingPathComponent("Parallax/ActiveLaunches").path),
                names.contains(where: { $0.hasPrefix(".removed-") })
            {
                throw AuditJournalInterruption.interrupted
            }
        }
        let id = UUID()
        try store.createRequest(requestID: id, identity: identity(), ownerProcess: owner)
        try store.markOpening(requestID: id)
        enabled.mutate { $0 = true }
        XCTAssertThrowsError(try store.complete(requestID: id, completion: .terminated))
        enabled.mutate { $0 = false }
        XCTAssertTrue(
            try DurableLaunchActivityStore(applicationSupportURL: root).artifacts().isEmpty)
        XCTAssertNoThrow(try store.complete(requestID: id, completion: .terminated))
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: store.rootURL.path)
                .contains { $0.hasPrefix(".removed-") })
    }

    func testUnreadableRequestStillBlocksGlobally() throws {
        let (_, store) = try fixture()
        let id = UUID()
        try store.createRequest(requestID: id, identity: identity(), ownerProcess: owner)
        try Data("invalid".utf8).write(
            to: store.rootURL.appendingPathComponent(id.uuidString.lowercased())
                .appendingPathComponent("request.json"))
        XCTAssertNil(store.artifacts().first?.identity)
        XCTAssertThrowsError(
            try store.createRequest(requestID: UUID(), identity: identity(), ownerProcess: owner))
    }
}

private enum AuditJournalInterruption: Error { case interrupted }
