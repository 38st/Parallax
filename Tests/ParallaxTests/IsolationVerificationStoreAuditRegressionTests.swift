import Foundation
import XCTest
@testable import Parallax

final class IsolationVerificationStoreAuditRegressionTests: XCTestCase {
    private func verifier(clock: StoreVerificationClock) -> IsolationActivityVerifier {
        let instant = ContinuousClock.now
        return IsolationActivityVerifier(clock: clock, scanner: IsolationActivityScanner(monotonicNow: { instant }))
    }

    @MainActor
    func testStoreNoticeClearsWhenBoundedProbingEnds() async throws {
        let clock = StoreVerificationClock()
        let verification = LaunchIsolationVerification(verifier: verifier(clock: clock))
        let fixture = try PresetIntegrationFixture(preset: .chromium, verification: verification)
        defer { fixture.remove() }
        let requestID = UUID()
        fixture.store.isolationVerification.register(requestID: requestID, paths: [.managed(fixture.root)],
            began: Date.distantFuture)
        let task = try XCTUnwrap(fixture.store.isolationVerification.running(requestID: requestID))
        await clock.waitForCount(1)
        XCTAssertTrue(fixture.store.isolationVerification.notices.isEmpty)
        await clock.advance(1)
        await clock.waitForCount(2)
        XCTAssertEqual(fixture.store.isolationVerification.notices, [requestID])
        await clock.advance(2)
        await task.value
        XCTAssertTrue(fixture.store.isolationVerification.notices.isEmpty)
    }

    @MainActor
    func testReusedRequestTokenIgnoresCancelledProbeCompletion() async throws {
        let clock = StoreVerificationClock()
        let verification = LaunchIsolationVerification(verifier: verifier(clock: clock))
        let fixture = try PresetIntegrationFixture(preset: .chromium, verification: verification)
        defer { fixture.remove() }
        let id = UUID()
        verification.register(requestID: id, paths: [.managed(fixture.root)], began: .distantFuture)
        let old = try XCTUnwrap(verification.running(requestID: id))
        await clock.waitForCount(1)
        verification.register(requestID: id, paths: [.managed(fixture.root)], began: .distantFuture)
        let current = try XCTUnwrap(verification.running(requestID: id))
        await clock.waitForCount(2)
        await clock.advance(1)
        await old.value
        XCTAssertTrue(fixture.store.isolationVerification.notices.isEmpty)
        await clock.advance(2)
        await clock.waitForCount(3)
        XCTAssertEqual(fixture.store.isolationVerification.notices, [id])
        await clock.advance(3)
        await current.value
        XCTAssertTrue(fixture.store.isolationVerification.notices.isEmpty)
    }

    @MainActor
    func testStoreRemovesNoticeOnAuthoritativeTerminationAndFailure() async throws {
        for fails in [false, true] {
            let clock = StoreVerificationClock()
            let verification = LaunchIsolationVerification(verifier: verifier(clock: clock))
            let fixture = try PresetIntegrationFixture(preset: .chromium, verification: verification)
            defer { fixture.remove() }
            let harness = LifecycleHarness()
            let identity = ProfileActivityIdentity(applicationID: fixture.app.id, applicationStorageID: fixture.app.storageID,
                profileID: fixture.profile.id, profileStorageID: fixture.profile.storageID)
            fixture.store.settings.confirmBeforeLaunch = true
            fixture.store.launch(fixture.profile)
            let request = try XCTUnwrap(fixture.store.launchRequests.pendingConfirmation(in: fixture.store.sceneID))
            let id = request.requestID
            let tracked: TrackedApplicationLaunch?
            if fails {
                tracked = nil
            } else {
                tracked = try harness.launcher.launchTracked(prepared: harness.prepared(requestID: id, identity: identity),
                    activityRegistry: harness.registry, lifecycleHandler: { _ in }, eventHandler: { _ in })
                fixture.store.activeTrackedLaunches[id] = tracked
            }
            verification.register(requestID: id, paths: [.managed(fixture.root)], began: .distantFuture)
            let task = try XCTUnwrap(verification.running(requestID: id))
            await clock.waitForCount(1)
            await clock.advance(1)
            await clock.waitForCount(2)
            XCTAssertTrue(verification.notices.contains(id))
            let terminal: ProfileLaunchLifecycleSnapshot
            if let tracked {
                let process = ExactRunningApplicationHandle(processIdentifier: 9812)
                harness.opener.complete(.success(process))
                tracked.noteTerminationRequested()
                harness.terminationObserver.terminate(process)
                terminal = tracked.currentLifecycle
            } else {
                terminal = ProfileLaunchLifecycleSnapshot(requestID: id, identity: identity,
                    state: .failed(message: "Synthetic preparation failure"))
            }
            XCTAssertTrue(terminal.state.isTerminal)
            fixture.store.handleLaunchLifecycle(terminal, profileName: fixture.profile.name)
            XCTAssertTrue(verification.notices.isEmpty)
            XCTAssertNil(fixture.store.activeTrackedLaunches[id])
            await clock.advance(2)
            await task.value
            XCTAssertTrue(verification.notices.isEmpty)
        }
    }
}

private actor StoreVerificationClock: IsolationVerificationClock {
    private var count = 0
    private var sleeps: [Int: CheckedContinuation<Void, Never>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(seconds: TimeInterval) async throws {
        XCTAssertEqual(seconds, 30)
        count += 1
        let index = count
        await withCheckedContinuation { continuation in
            sleeps[index] = continuation
            let ready = observers.filter { $0.0 <= count }
            observers.removeAll { $0.0 <= count }
            ready.forEach { $0.1.resume() }
        }
        try Task.checkCancellation()
    }

    func waitForCount(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { observers.append((expected, $0)) }
    }

    func advance(_ index: Int) { sleeps.removeValue(forKey: index)?.resume() }
}
