import Darwin
import Foundation
import XCTest
@testable import Parallax

@MainActor
final class IntegrationLaunchQueueAuditRegressionTests: XCTestCase {
    func testUnknownOpenWaitsAndConfirmedClearReleasesExactSlot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let harness = LifecycleHarness()
        let processState = harness.processState
        processState.processInspections[getpid()] = .live(.init(processIdentifier: getpid(), startTimeSeconds: 100, startTimeMicroseconds: 0))
        let registry = try ProfileActivityRegistry(applicationSupportURL: root, refreshScheduler: SupervisorTestScheduler(), processInspector: processState)
        let resumed = expectation(description: "Queued open resumes")
        let opener = IntegrationObservedWorkspaceOpener { count in
            if count == 2 { resumed.fulfill() }
        }
        let launcher = WorkspaceApplicationLauncher(opener: opener, terminationObserver: harness.terminationObserver,
            processProvenanceInspector: processState, launchRequestTimeProvider: ProvenanceTestTimeProvider(),
            launchAuthority: WorkspaceApplicationLaunchAuthority())
        let identity = harness.identity
        let secondIdentity = ProfileActivityIdentity(applicationID: identity.applicationID, applicationStorageID: identity.applicationStorageID,
            profileID: UUID(), profileStorageID: UUID())
        let first = harness.prepared(requestID: UUID())
        let second = harness.prepared(requestID: UUID(), identity: secondIdentity)
        let profile = LaunchProfile(id: identity.profileID, storageID: identity.profileStorageID, name: "First")
        let app = ManagedApplication(id: identity.applicationID, storageID: identity.applicationStorageID, displayName: "Synthetic",
            bundleIdentifier: first.applicationIdentity.bundleIdentifier, appPath: first.applicationURL.path, baseStoragePath: root.path,
            profiles: [profile, LaunchProfile(id: secondIdentity.profileID, storageID: secondIdentity.profileStorageID, name: "Second")])
        let repository = LibraryRepository(applicationSupportURL: root)
        _ = try repository.save([app], expectedVersion: .missing)
        let store = LibraryStore(repository: repository, profileActivityRegistry: registry, settings: AppSettings())
        let failed = try launcher.launchTracked(prepared: first, activityRegistry: registry, eventHandler: { _ in })
        XCTAssertTrue(store.registerDirectLaunchIfNeeded(application: app, profile: profile,
            source: store.launchConfigurationSource(application: app, profile: profile, requestID: first.requestID)))
        store.retainTrackedLaunch(failed, requestID: first.requestID)
        let queued = try launcher.launchTracked(prepared: second, activityRegistry: registry, eventHandler: { _ in })
        let queuedProfile = try XCTUnwrap(app.profiles.last)
        XCTAssertTrue(store.registerDirectLaunchIfNeeded(application: app, profile: queuedProfile,
            source: store.launchConfigurationSource(application: app, profile: queuedProfile, requestID: second.requestID)))
        store.retainTrackedLaunch(queued, requestID: second.requestID)
        let thirdIdentity = ProfileActivityIdentity(applicationID: identity.applicationID, applicationStorageID: identity.applicationStorageID,
            profileID: UUID(), profileStorageID: UUID())
        let third = try launcher.launchTracked(prepared: harness.prepared(requestID: UUID(), identity: thirdIdentity),
            activityRegistry: registry, eventHandler: { _ in })
        opener.completeNext(.failure(CocoaError(.fileReadUnknown)))
        XCTAssertEqual(opener.openCount, 1)
        let presentation = LaunchStatusPresenter.presentation(applicationName: "Synthetic", profileName: "Second",
            state: .launching, openingDisposition: queued.currentLifecycle.openingDisposition)
        XCTAssertEqual(presentation.listSummary, String(localized: "Waiting to open"))
        XCTAssertTrue(presentation.message.contains("unknown outcome"), presentation.message)
        store.handleLaunchLifecycle(queued.currentLifecycle, profileName: queuedProfile.name)
        XCTAssertTrue(store.launchStatusPresentation(for: app, profile: queuedProfile)?.message.contains(profile.name) == true)
        XCTAssertTrue(LaunchStatusPresenter.unknownOpenOutcomeMessage(applicationName: app.displayName,
            profileName: profile.name, detail: "synthetic").contains("Restart Parallax"))
        XCTAssertTrue(store.canRequestStuckLaunchRecovery(for: app, profile: profile))
        var relinked = app
        relinked.appPath = root.appendingPathComponent("Different.app").path
        store.applications = [relinked]
        XCTAssertFalse(store.canRequestStuckLaunchRecovery(for: relinked, profile: profile))
        for bundleID in [Optional<String>.none, "different.bundle"] {
            var changed = app
            changed.bundleIdentifier = bundleID
            store.applications = [changed]
            XCTAssertFalse(store.canRequestStuckLaunchRecovery(for: changed, profile: profile))
        }
        store.applications = [relinked]
        XCTAssertNil(store.stuckLaunchRecoveryRequest(for: relinked, profile: profile, processSnapshotter: processState))
        store.applications = [app]
        let request = try XCTUnwrap(store.stuckLaunchRecoveryRequest(for: app, profile: profile, processSnapshotter: processState))
        XCTAssertEqual(request.records.map(\.requestID), [first.requestID])
        let process = processState.workspaceIdentity(processIdentifier: 8123, application: first.applicationIdentity)
        processState.preexistingProcesses = [process]
        XCTAssertFalse(store.confirmClearStuckLaunchRecord(request, processSnapshotter: processState))
        XCTAssertEqual(opener.openCount, 1)
        XCTAssertFalse(failed.currentLifecycle.state.isTerminal)
        processState.preexistingProcesses = []
        XCTAssertTrue(store.confirmClearStuckLaunchRecord(request, processSnapshotter: processState))
        XCTAssertTrue(failed.currentLifecycle.state.isTerminal)
        store.handleLaunchLifecycle(failed.currentLifecycle, profileName: profile.name)
        XCTAssertEqual(store.launchStatusPresentation(for: app, profile: profile)?.message, String(localized: "Open cancelled"))
        XCTAssertEqual(store.launchStatusPresentation(for: app, profile: profile)?.tone, .neutral)
        let history = try LaunchHistoryStore(applicationSupportURL: root)
        history.record(failed.currentLifecycle, application: app, profile: profile, fallbackProfileName: profile.name)
        let entry = try XCTUnwrap(history.entries(for: app).first)
        XCTAssertEqual(entry.state, .cancelled)
        XCTAssertNil(entry.process)
        XCTAssertNil(entry.terminationDisposition)
        XCTAssertEqual(LaunchHistoryEntryPresentation(entry: entry).statusLabel, String(localized: "Open cancelled"))
        XCTAssertEqual(try LaunchHistoryStore(applicationSupportURL: root).entries(for: app).first?.state, .cancelled)
        await fulfillment(of: [resumed], timeout: 5)
        XCTAssertEqual(opener.openCount, 2)
        XCTAssertEqual(queued.currentLifecycle.openingDisposition, .pending)
        store.handleLaunchLifecycle(queued.currentLifecycle, profileName: queuedProfile.name)
        XCTAssertEqual(store.launchStatusMessage(for: app, profile: queuedProfile), String(localized: "Opening \(queuedProfile.name)…"))
        XCTAssertFalse(registry.isActive(identity: identity))
        XCTAssertEqual(third.currentLifecycle.openingDisposition, .waitingForEarlierOpen(outcomeUnknown: false))
        opener.completeNext(.success(ExactRunningApplicationHandle(processIdentifier: 8124)))
        XCTAssertEqual(opener.openCount, 3)
        queued.didFail(CocoaError(.userCancelled))
        opener.completeNext(.success(ExactRunningApplicationHandle(processIdentifier: 8125)))
        third.didFail(CocoaError(.userCancelled))
    }
}
