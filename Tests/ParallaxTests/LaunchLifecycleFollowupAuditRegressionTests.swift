import XCTest

@testable import Parallax

final class LaunchLifecycleFollowupAuditRegressionTests: XCTestCase {
    func testExitAfterFinalVerificationRetainsIdentityAndUnexpectedTermination() throws {
        let harness = LifecycleHarness()
        let scheduler = SupervisorTestScheduler()
        let launcher = WorkspaceApplicationLauncher(
            opener: harness.opener, terminationObserver: harness.terminationObserver,
            processProvenanceInspector: harness.processState,
            launchRequestTimeProvider: ProvenanceTestTimeProvider(),
            processSupervisor: WorkspaceProcessSupervisor(inspector: harness.processState, scheduler: scheduler))
        let prepared = harness.prepared(requestID: UUID())
        let process = harness.processState.workspaceIdentity(
            processIdentifier: 7219, application: prepared.applicationIdentity)
        harness.processState.returnedInspections[7219] = [.live(process), .live(process), .live(process), .exited]
        let events = LaunchTestLocked<[TrackedApplicationLaunchEvent]>([])
        let launch = try launcher.launchTracked(prepared: prepared, activityRegistry: harness.registry,
            eventHandler: { event in events.mutate { $0.append(event) } })
        harness.opener.complete(.success(ExactRunningApplicationHandle(processIdentifier: 7219)))
        XCTAssertEqual(launch.currentLifecycle.state, .terminated(processIdentifier: 7219))
        XCTAssertEqual(launch.currentLifecycle.processIdentity, process)
        XCTAssertEqual(launch.currentLifecycle.terminationDisposition, .unexpected)
        XCTAssertFalse(events.value.contains { if case .running = $0 { return true }; return false })
        XCTAssertFalse(harness.registry.isActive(identity: harness.identity))
    }

    func testUnknownOpenOutcomeMessagePointsToConfirmedRecordRecovery() throws {
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Parallax/Resources/en.lproj")
        let bundle = try XCTUnwrap(Bundle(url: resources))
        let message = LaunchStatusPresenter.unknownOpenOutcomeMessage(
            applicationName: "Fixture", profileName: "Work", detail: "synthetic failure",
            bundle: bundle, locale: Locale(identifier: "en"))
        XCTAssertTrue(message.contains("Restart Parallax"), message)
        XCTAssertTrue(message.contains("Clear Stuck Launch Record"), message)
        XCTAssertFalse(message.contains("before retrying"), message)
    }
}
