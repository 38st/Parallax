import AppKit
import Darwin
import Foundation
import XCTest
@testable import Parallax

@MainActor
final class IntegrationLaunchClearAuditRegressionTests: XCTestCase {
    func testClearedQueueResumesOffMainThreadThroughActivityLockContention() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let harness = LifecycleHarness()
        let state = harness.processState
        state.processInspections[getpid()] = .live(.init(processIdentifier: getpid(), startTimeSeconds: 100, startTimeMicroseconds: 0))
        let registry = try ProfileActivityRegistry(applicationSupportURL: root, refreshScheduler: SupervisorTestScheduler(), processInspector: state)
        let opened = expectation(description: "Queued request starts after contention ends")
        let opener = IntegrationObservedWorkspaceOpener { count in
            if count == 2 {
                XCTAssertFalse(Thread.isMainThread)
                opened.fulfill()
            }
        }
        let launcher = WorkspaceApplicationLauncher(opener: opener, terminationObserver: harness.terminationObserver,
            processProvenanceInspector: state, launchRequestTimeProvider: ProvenanceTestTimeProvider(),
            launchAuthority: WorkspaceApplicationLaunchAuthority())
        let first = harness.prepared(requestID: UUID())
        let identity = harness.identity
        let second = harness.prepared(requestID: UUID(), identity: .init(applicationID: identity.applicationID,
            applicationStorageID: identity.applicationStorageID, profileID: UUID(), profileStorageID: UUID()))
        let blocked = try launcher.launchTracked(prepared: first, activityRegistry: registry, eventHandler: { _ in })
        let queued = try launcher.launchTracked(prepared: second, activityRegistry: registry, eventHandler: { _ in })
        opener.completeNext(.failure(CocoaError(.fileReadUnknown)))
        let records = try registry.stuckLaunchRecords(identity: identity, expectedApplication: first.applicationIdentity, processSnapshotter: state)
        try registry.clearStuckLaunchRecords(records, identity: identity, expectedApplication: first.applicationIdentity, processSnapshotter: state)
        let lockURL = root.appendingPathComponent("Parallax/ActiveLaunches/.profile-acquisition.lock")
        let descriptor = Darwin.open(lockURL.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        blocked.didClearUnknownOpenRecord(try XCTUnwrap(records.first))
        if case .failed = queued.currentLifecycle.state { XCTFail("Momentary contention must not fail the queued open") }
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        await fulfillment(of: [opened], timeout: 5)
        queued.didFail(CocoaError(.userCancelled))
    }
}

struct IntegrationObservedWorkspaceOpener: WorkspaceApplicationOpening {
    let base = ScriptedWorkspaceApplicationOpener()
    let onOpen: @Sendable (Int) -> Void

    var openCount: Int { base.openCount }

    func openApplication(at url: URL, configuration: NSWorkspace.OpenConfiguration,
                         completion: @escaping @Sendable (Result<any RunningApplicationInstance, Error>) -> Void) {
        base.openApplication(at: url, configuration: configuration, completion: completion)
        onOpen(base.openCount)
    }

    func completeNext(_ result: Result<any RunningApplicationInstance, Error>) {
        base.completeNext(result)
    }
}
