import Foundation
import XCTest

@testable import Parallax

final class ReservationReviewAuditRegressionTests: XCTestCase {
    func testReservationIsNotRunningAndBlocksPreparationBeforeDirectoryCreation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = try ValidApplicationBundleFixture.create(in: root)
        let state = TestWorkspaceProcessState()
        let owner = try ProfileActivityRegistry(
            applicationSupportURL: root, refreshScheduler: SupervisorTestScheduler(), processInspector: state)
        let peer = try ProfileActivityRegistry(applicationSupportURL: root, refreshScheduler: SupervisorTestScheduler(), processInspector: state)
        let identity = ProfileActivityIdentity(
            applicationID: UUID(), applicationStorageID: UUID(),
            profileID: UUID(), profileStorageID: UUID())
        let reservation = try owner.acquireDataOperationLease(identities: [identity])
        defer { reservation.release() }
        XCTAssertEqual(reservation.identities, [identity])
        XCTAssertFalse(
            reservation.isStorageActive(
                applicationStorageID: identity.applicationStorageID,
                profileStorageID: identity.profileStorageID))
        XCTAssertTrue(
            reservation.activityProvider.activeProfileStorageIDs(
                applicationStorageID: identity.applicationStorageID,
                profileStorageIDs: [identity.profileStorageID]
            ).isEmpty)
        XCTAssertTrue(
            owner.isStorageActive(
                applicationStorageID: identity.applicationStorageID,
                profileStorageID: identity.profileStorageID))
        _ = try peer.reconcileDurableActivity()
        XCTAssertFalse(owner.isActive(identity: identity))
        XCTAssertFalse(peer.isActive(identity: identity))
        let compiler = LaunchConfigurationCompiler(
            activityProvider: peer,
            identity: ChildEnvironmentIdentity(
                homeDirectory: root.path, userName: "fixture", temporaryDirectory: root.path),
            processEnvironment: [:], secretResolver: AuditSecretStore())
        let source = LaunchConfigurationSource(
            requestID: UUID(), applicationID: identity.applicationID,
            applicationStorageID: identity.applicationStorageID, profileID: identity.profileID,
            profileStorageID: identity.profileStorageID, configurationRevision: 0,
            applicationURL: bundle.url,
            expectedBundleIdentifier: bundle.bundleIdentifier, configuredBaseRoot: root.path,
            argumentsText: "", environmentText: "",
            isolationOwnership: .init(userData: .generated, codexHome: .generated),
            childEnvironmentPolicy: .safeDefault, sensitiveEnvironmentKeys: [])
        let analysis = await compiler.analyze(source)
        XCTAssertFalse(analysis.diagnostics.contains { $0.code == .profileHealth(.profileActive) })
        do {
            _ = try await compiler.prepare(
                source,
                override: .init(
                    requestID: source.requestID,
                    configurationFingerprint: analysis.configurationFingerprint,
                    allowsActiveProfileRisk: true))
            XCTFail("A reservation must not be overridable")
        } catch {}
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".parallax").path))
    }
}

final class ReinspectionReviewAuditRegressionTests: XCTestCase {
    func testPersistentMissingMetadataHasABoundedRetryBudget() throws {
        let harness = LifecycleHarness()
        let scheduler = SupervisorTestScheduler()
        harness.processState.returnedInspections[7452] = Array(repeating: .indeterminate, count: 12)
        let launcher = WorkspaceApplicationLauncher(
            opener: harness.opener,
            terminationObserver: harness.terminationObserver,
            processProvenanceInspector: harness.processState,
            launchRequestTimeProvider: ProvenanceTestTimeProvider(),
            processSupervisor: WorkspaceProcessSupervisor(
                inspector: harness.processState, scheduler: scheduler))
        let launch = try launcher.launchTracked(
            prepared: harness.prepared(requestID: UUID()),
            activityRegistry: harness.registry, eventHandler: { _ in })
        harness.opener.complete(.success(ExactRunningApplicationHandle(processIdentifier: 7452)))
        for _ in 0..<3 { scheduler.runNext() }
        XCTAssertEqual(
            launch.processProvenance,
            .indeterminate(processIdentifier: 7452, reason: .unverifiableIdentity))
        XCTAssertNil(launch.currentLifecycle.processIdentity)
        XCTAssertTrue(harness.registry.isActive(identity: harness.identity))
        harness.processState.returnedInspections[7452] = [.exited]
        scheduler.runNext()
        XCTAssertTrue(launch.currentLifecycle.state.isTerminal)
    }

    func testMissingMetadataIsRetriedBeforeProvenanceIsClassified() throws {
        let harness = LifecycleHarness()
        let scheduler = SupervisorTestScheduler()
        harness.processState.returnedInspections[7451] = [.indeterminate, .indeterminate]
        let launcher = WorkspaceApplicationLauncher(
            opener: harness.opener,
            terminationObserver: harness.terminationObserver,
            processProvenanceInspector: harness.processState,
            launchRequestTimeProvider: ProvenanceTestTimeProvider(),
            processSupervisor: WorkspaceProcessSupervisor(
                inspector: harness.processState, scheduler: scheduler))
        let launch = try launcher.launchTracked(
            prepared: harness.prepared(requestID: UUID()),
            activityRegistry: harness.registry, eventHandler: { _ in })
        let running = ExactRunningApplicationHandle(processIdentifier: 7451)
        harness.opener.complete(.success(running))
        XCTAssertNil(launch.processProvenance)
        scheduler.runNext()
        scheduler.runNext()
        XCTAssertEqual(launch.currentLifecycle.state, .running(processIdentifier: 7451))
        harness.terminationObserver.terminate(running)
    }
}
