import Foundation
import XCTest

@testable import Parallax

@MainActor
final class ProcessControlAuditRegressionTests: XCTestCase {
    private func fixture(degraded: Bool = false) throws -> (
        LibraryStore, LibraryStore, TrackedApplicationLaunch, ManagedApplication,
        TestRunningApplicationTerminationObserver, ExactRunningApplicationHandle
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let harness = LifecycleHarness()
        let profile = LaunchProfile(
            id: harness.identity.profileID, storageID: harness.identity.profileStorageID,
            name: "Work")
        let prepared = harness.prepared(requestID: UUID())
        let app = ManagedApplication(
            id: harness.identity.applicationID, storageID: harness.identity.applicationStorageID,
            displayName: "Audit", bundleIdentifier: prepared.applicationIdentity.bundleIdentifier,
            appPath: prepared.applicationURL.path, profiles: [profile])
        let registry = try ProfileActivityRegistry(
            applicationSupportURL: root, processInspector: harness.processState)
        let launch = try harness.launcher.launchTracked(
            prepared: prepared, activityRegistry: registry, eventHandler: { _ in })
        if degraded {
            let marker = root.appendingPathComponent(
                "Parallax/ActiveLaunches/\(prepared.requestID.uuidString.lowercased())/process.json"
            )
            try Data("invalid".utf8).write(to: marker)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: marker.path)
        }
        let running = ExactRunningApplicationHandle(processIdentifier: 7311)
        harness.opener.complete(.success(running))
        let provider = AuditProcessProvider(
            identity: try XCTUnwrap(launch.supervisedProcessIdentity))
        let controller = ApplicationInstanceController(processProvider: provider)
        let settings = AppSettings()
        settings.defaultBaseStoragePath = root.appendingPathComponent("Profiles").path
        let compiler = LaunchConfigurationCompiler(
            activityProvider: registry,
            identity: ChildEnvironmentIdentity(
                homeDirectory: root.path, userName: "fixture", temporaryDirectory: root.path),
            processEnvironment: [:], secretResolver: AuditSecretStore())
        let owner = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: root),
            profileActivityRegistry: registry, launcher: AuditNoopLauncher(),
            applicationInstanceController: controller, launchConfigurationCompiler: compiler,
            secretStore: AuditSecretStore(), settings: settings)
        let peer = LibraryStore(
            persistence: LibraryPersistence(applicationSupportURL: root),
            profileActivityRegistry: registry, launcher: AuditNoopLauncher(),
            applicationInstanceController: controller, launchConfigurationCompiler: compiler,
            secretStore: AuditSecretStore(), settings: settings)
        owner.applications = [app]
        peer.applications = [app]
        owner.activeTrackedLaunches[prepared.requestID] = launch
        return (owner, peer, launch, app, harness.terminationObserver, running)
    }

    func testQuitFromAnotherWindowIsExpectedInOwningSession() throws {
        let (_, peer, launch, app, observer, running) = try fixture()
        let instance = try XCTUnwrap(peer.runningApplicationInstances(for: app).first)
        XCTAssertTrue(peer.requestQuit(instance, from: app))
        let process = try XCTUnwrap(launch.supervisedProcessIdentity)
        observer.terminate(running)
        XCTAssertFalse(ExpectedProcessTerminationIntent.shared.contains(process))
        XCTAssertEqual(launch.currentLifecycle.terminationDisposition, .expected)
    }

    func testDegradedTrackingRetainsVerifiedLocalProcessControls() throws {
        let (owner, peer, launch, app, observer, running) = try fixture(degraded: true)
        defer { observer.terminate(running) }
        guard case .runningDegraded = launch.currentLifecycle.state else {
            return XCTFail("Expected degraded tracking")
        }
        let instance = try XCTUnwrap(owner.runningApplicationInstances(for: app).first)
        XCTAssertTrue(instance.hasTrackedAttribution)
        XCTAssertTrue(instance.isActionable)
        XCTAssertTrue(owner.requestActivate(instance, from: app))
        let peerInstance = try XCTUnwrap(peer.runningApplicationInstances(for: app).first)
        XCTAssertTrue(peerInstance.hasTrackedAttribution)
        XCTAssertTrue(peer.requestActivate(peerInstance, from: app))
    }
}

@MainActor
private final class AuditProcessProvider: WorkspaceApplicationProcessProviding {
    let identity: WorkspaceProcessIdentity
    init(identity: WorkspaceProcessIdentity) { self.identity = identity }
    func runningProcesses() -> [WorkspaceApplicationProcess] {
        [
            WorkspaceApplicationProcess(
                process: identity.process, bundleURL: identity.application.bundleURL,
                bundleIdentifier: identity.application.bundleIdentifier)
        ]
    }
    func requestTermination(of identity: WorkspaceProcessIdentity)
        -> WorkspaceProcessOperationResult
    { .accepted }
    func requestActivation(of identity: WorkspaceProcessIdentity) -> WorkspaceProcessOperationResult
    { .accepted }
}
