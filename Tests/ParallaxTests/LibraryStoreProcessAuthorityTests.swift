import AppKit
import Foundation
import Observation
import XCTest
@testable import Parallax

final class LibraryStoreProcessAuthorityTests: XCTestCase {
    @MainActor
    func testStoreUpgradesOnlyExactActiveLaunchToActionable() throws {
        let harness = try StoreProcessAuthorityHarness(pid: 8_800)

        let instance = try XCTUnwrap(
            harness.store.runningApplicationInstances(
                for: harness.application
            ).first
        )

        XCTAssertEqual(
            instance.controlPresentation,
            .verifiedParallaxInstance
        )
        XCTAssertTrue(instance.isActionable)
    }

    @MainActor
    func testAttributionWithoutActiveOrDurableProofIsVerificationUnavailable()
        throws
    {
        let harness = try StoreProcessAuthorityHarness(pid: 8_808)
        harness.store.activeTrackedLaunches[harness.requestID] = nil

        let instance = try XCTUnwrap(
            harness.store.runningApplicationInstances(
                for: harness.application
            ).first
        )

        XCTAssertEqual(
            instance.controlPresentation,
            .verificationUnavailable
        )
        XCTAssertFalse(instance.isActionable)
        XCTAssertFalse(instance.actionPresentation.canShow)
        XCTAssertFalse(instance.actionPresentation.canQuit)
        XCTAssertFalse(
            harness.store.requestActivate(
                instance,
                from: harness.application
            )
        )
        XCTAssertTrue(harness.controller.activationRequests.isEmpty)
    }

    @MainActor
    func testUnattributedInstanceReportsUnavailableDurableTracking()
        throws
    {
        let registry = ProfileActivityRegistry()
        XCTAssertFalse(registry.isDurableTrackingAvailable)
        let application = ManagedApplication(
            displayName: "Test",
            bundleIdentifier: "example.test",
            appPath: "/Applications/Test.app"
        )
        let controller = StoreAuthorityController()
        controller.discoveredInstances = [
            ManagedApplicationInstance(
                processIdentity: WorkspaceProcessIdentity(
                    process: ProcessStartIdentity(
                        processIdentifier: 8_812,
                        startTimeSeconds: 1,
                        startTimeMicroseconds: 2
                    ),
                    application: WorkspaceApplicationBundleIdentity(
                        bundleURL: URL(
                            fileURLWithPath: application.appPath
                        ),
                        bundleIdentifier: application.bundleIdentifier
                    )
                ),
                requestID: nil,
                profileID: nil,
                profileStorageID: nil,
                profileName: nil
            )
        ]
        let store = LibraryStore(
            persistence: StartupAuthorityPersistence(),
            profileActivityRegistry: registry,
            applicationInstanceController: controller
        )

        let instance = try XCTUnwrap(
            store.runningApplicationInstances(for: application).first
        )

        XCTAssertEqual(
            instance.controlPresentation,
            .trackingUnavailable
        )
        XCTAssertFalse(instance.isActionable)
        XCTAssertFalse(instance.actionPresentation.canShow)
        XCTAssertFalse(instance.actionPresentation.canQuit)
    }

    @MainActor
    func testUnattributedInstanceRemainsOutsideParallaxWhenTrackingIsAvailable()
        throws
    {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Durable-Authority-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: false
        )
        let registry = try ProfileActivityRegistry(
            applicationSupportURL: support
        )
        XCTAssertTrue(registry.isDurableTrackingAvailable)
        let application = ManagedApplication(
            displayName: "Test",
            bundleIdentifier: "example.test",
            appPath: "/Applications/Test.app"
        )
        let controller = StoreAuthorityController()
        controller.discoveredInstances = [
            ManagedApplicationInstance(
                processIdentity: WorkspaceProcessIdentity(
                    process: ProcessStartIdentity(
                        processIdentifier: 8_813,
                        startTimeSeconds: 1,
                        startTimeMicroseconds: 2
                    ),
                    application: WorkspaceApplicationBundleIdentity(
                        bundleURL: URL(
                            fileURLWithPath: application.appPath
                        ),
                        bundleIdentifier: application.bundleIdentifier
                    )
                ),
                requestID: nil,
                profileID: nil,
                profileStorageID: nil,
                profileName: nil
            )
        ]
        let store = LibraryStore(
            persistence: StartupAuthorityPersistence(),
            profileActivityRegistry: registry,
            applicationInstanceController: controller
        )

        let instance = try XCTUnwrap(
            store.runningApplicationInstances(for: application).first
        )

        XCTAssertEqual(instance.controlPresentation, .outsideParallax)
        XCTAssertFalse(instance.isActionable)
    }

    @MainActor
    func testRecoveredDurableLaunchRemainsActionableAfterParallaxRestart()
        throws
    {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Recovered-Authority-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: support) }
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: false
        )

        let requestID = UUID()
        let profile = LaunchProfile(name: "Recovered")
        let application = ManagedApplication(
            displayName: "Test",
            bundleIdentifier: "example.test",
            appPath: "/Applications/Test.app",
            profiles: [profile]
        )
        let activityIdentity = ProfileActivityIdentity(
            applicationID: application.id,
            applicationStorageID: application.storageID,
            profileID: profile.id,
            profileStorageID: profile.storageID
        )
        let processState = TestWorkspaceProcessState()
        let process = processState.processIdentity(
            processIdentifier: 8_811
        )
        let firstRegistry = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: processState
        )
        let lease = try firstRegistry.acquireLaunchLease(
            identity: activityIdentity,
            requestID: requestID
        )
        try firstRegistry.markLaunchOpening(requestID: requestID)
        try firstRegistry.recordRunningProcess(
            requestID: requestID,
            processIdentity: process
        )

        let recoveredRegistry = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: processState
        )
        let report = try recoveredRegistry.reconcileDurableActivity()
        XCTAssertEqual(report.recoveredLiveCount, 1)

        // The previous Parallax process recorded the launch as running.
        let previousHistory = try LaunchHistoryStore(
            applicationSupportURL: support,
            processInspector: processState
        )
        previousHistory.record(
            ProfileLaunchLifecycleSnapshot(
                requestID: requestID,
                identity: activityIdentity,
                state: .running(
                    processIdentifier: process.processIdentifier
                )
            ),
            application: application,
            profile: profile,
            fallbackProfileName: profile.name
        )
        let recoveredHistory = try LaunchHistoryStore(
            applicationSupportURL: support,
            processInspector: processState
        )
        XCTAssertEqual(recoveredHistory.entries.first?.state, .running)

        let controller = StoreAuthorityController()
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            profileActivityRegistry: recoveredRegistry,
            launchHistoryStore: recoveredHistory,
            applicationInstanceController: controller
        )
        store.applications = [application]
        let processIdentity = WorkspaceProcessIdentity(
            process: process,
            application: WorkspaceApplicationBundleIdentity(
                bundleURL: URL(fileURLWithPath: application.appPath),
                bundleIdentifier: application.bundleIdentifier
            )
        )
        controller.discoveredInstances = [
            ManagedApplicationInstance(
                processIdentity: processIdentity,
                requestID: requestID,
                profileID: profile.id,
                profileStorageID: profile.storageID,
                profileName: profile.name
            )
        ]

        let instance = try XCTUnwrap(
            store.runningApplicationInstances(for: application).first
        )
        XCTAssertEqual(
            instance.controlPresentation,
            .verifiedParallaxInstance
        )
        XCTAssertTrue(instance.actionPresentation.canShow)
        XCTAssertTrue(instance.actionPresentation.canQuit)
        XCTAssertTrue(store.requestActivate(instance, from: application))
        XCTAssertTrue(store.requestQuit(instance, from: application))
        XCTAssertEqual(
            controller.activationRequests,
            [processIdentity]
        )
        XCTAssertEqual(controller.quitRequests, [processIdentity])

        // The user-requested quit is remembered even though no in-memory
        // session exists, so reconciling after the exit is not unexpected.
        let requested = try XCTUnwrap(recoveredHistory.entries.first)
        XCTAssertEqual(requested.requestID, requestID)
        XCTAssertEqual(requested.state, .running)
        XCTAssertEqual(requested.terminationDisposition, .expected)

        processState.markExited(
            processIdentifier: process.processIdentifier
        )
        let reconciled = try LaunchHistoryStore(
            applicationSupportURL: support,
            processInspector: processState
        )
        let closed = try XCTUnwrap(reconciled.entries.first)
        XCTAssertEqual(closed.requestID, requestID)
        XCTAssertEqual(closed.state, .closed)
        XCTAssertNotEqual(closed.terminationDisposition, .unexpected)
        XCTAssertEqual(closed.terminationDisposition, .expected)

        withExtendedLifetime(lease) {}
    }

    @MainActor
    func testTerminatingLaunchIsVerificationUnavailable() throws {
        let harness = try StoreProcessAuthorityHarness(pid: 8_809)
        XCTAssertTrue(harness.launch.noteTerminationRequested())

        let instance = try XCTUnwrap(
            harness.store.runningApplicationInstances(
                for: harness.application
            ).first
        )

        XCTAssertEqual(
            instance.controlPresentation,
            .verificationUnavailable
        )
        XCTAssertFalse(instance.isActionable)
        XCTAssertFalse(instance.actionPresentation.canShow)
        XCTAssertFalse(instance.actionPresentation.canQuit)
        XCTAssertFalse(
            harness.store.requestQuit(
                instance,
                from: harness.application
            )
        )
        XCTAssertTrue(harness.controller.quitRequests.isEmpty)
    }

    @MainActor
    func testTerminatingLifecycleInvalidatesObservedRunningRows()
        throws
    {
        let harness = try StoreProcessAuthorityHarness(pid: 8_810)
        let invalidation = StoreAuthorityObservationFlag()
        let initial = withObservationTracking {
            harness.store.runningApplicationInstances(
                for: harness.application
            )
        } onChange: {
            invalidation.markInvalidated()
        }
        XCTAssertTrue(initial.first?.isActionable == true)

        XCTAssertTrue(harness.launch.noteTerminationRequested())
        harness.store.handleLaunchLifecycle(
            harness.launch.currentLifecycle,
            profileName: harness.profile.name
        )

        XCTAssertTrue(invalidation.isInvalidated)
        let recomputed = try XCTUnwrap(
            harness.store.runningApplicationInstances(
                for: harness.application
            ).first
        )
        XCTAssertEqual(
            recomputed.controlPresentation,
            .verificationUnavailable
        )
        XCTAssertFalse(recomputed.actionPresentation.canShow)
        XCTAssertFalse(recomputed.actionPresentation.canQuit)
    }

    @MainActor
    func testExactRequestAndFullIdentityMarksSynchronousQuitExpected()
        throws
    {
        let harness = try StoreProcessAuthorityHarness(pid: 8_801)
        harness.controller.onQuit = { _ in
            harness.observer.terminate(harness.runningApplication)
        }

        XCTAssertTrue(
            harness.store.requestQuit(
                harness.instance,
                from: harness.application
            )
        )
        XCTAssertEqual(
            harness.launch.currentLifecycle.terminationDisposition,
            .expected
        )
        XCTAssertEqual(
            harness.controller.quitRequests,
            [harness.instance.processIdentity]
        )
    }

    @MainActor
    func testCommandQStyleExternalQuitClosesWithoutCrashAlert() throws {
        let harness = try StoreProcessAuthorityHarness(pid: 8_814)

        harness.observer.terminate(harness.runningApplication)
        XCTAssertEqual(
            harness.launch.currentLifecycle.terminationDisposition,
            .unexpected
        )

        harness.store.handleLaunchLifecycle(
            harness.launch.currentLifecycle,
            profileName: harness.profile.name
        )

        XCTAssertNil(harness.store.errorMessage)
        XCTAssertNil(
            harness.store.activeTrackedLaunches[harness.requestID]
        )
        let entry = try XCTUnwrap(
            harness.store.launchHistoryStore.entries.first(where: {
                $0.requestID == harness.requestID
            })
        )
        XCTAssertEqual(entry.state, .closed)
        XCTAssertEqual(entry.terminationDisposition, .unexpected)
        XCTAssertEqual(
            LaunchHistoryEntryPresentation(entry: entry).statusLabel,
            "Closed"
        )
    }

    @MainActor
    func testMicrosecondReuseCannotBorrowExpectedQuitDisposition()
        throws
    {
        let harness = try StoreProcessAuthorityHarness(pid: 8_802)
        let wrongProcess = ProcessStartIdentity(
            processIdentifier: harness.instance.processIdentifier,
            startTimeSeconds:
                harness.instance.process.startTimeSeconds,
            startTimeMicroseconds:
                harness.instance.process.startTimeMicroseconds + 1
        )
        let reused = ManagedApplicationInstance(
            processIdentity: WorkspaceProcessIdentity(
                process: wrongProcess,
                application: harness.instance.processIdentity.application
            ),
            requestID: harness.instance.requestID,
            profileID: harness.instance.profileID,
            profileStorageID: harness.instance.profileStorageID,
            profileName: harness.instance.profileName
        )

        XCTAssertFalse(
            harness.store.requestQuit(
                reused,
                from: harness.application
            )
        )
        harness.observer.terminate(harness.runningApplication)

        XCTAssertEqual(
            harness.launch.currentLifecycle.terminationDisposition,
            .unexpected
        )
    }

    @MainActor
    func testWrongRequestCannotMarkSiblingLaunchExpected() throws {
        let harness = try StoreProcessAuthorityHarness(pid: 8_803)
        let wrongRequest = ManagedApplicationInstance(
            processIdentity: harness.instance.processIdentity,
            requestID: UUID(),
            profileID: harness.instance.profileID,
            profileStorageID: harness.instance.profileStorageID,
            profileName: harness.instance.profileName
        )

        XCTAssertFalse(
            harness.store.requestQuit(
                wrongRequest,
                from: harness.application
            )
        )
        harness.observer.terminate(harness.runningApplication)

        XCTAssertEqual(
            harness.launch.currentLifecycle.terminationDisposition,
            .unexpected
        )
    }

    @MainActor
    func testStaleApplicationStorageCannotControlExactPID() throws {
        let harness = try StoreProcessAuthorityHarness(pid: 8_806)
        let replacement = ManagedApplication(
            id: harness.application.id,
            storageID: UUID(),
            displayName: harness.application.displayName,
            bundleIdentifier: harness.application.bundleIdentifier,
            appPath: harness.application.appPath,
            profiles: [harness.profile]
        )

        XCTAssertFalse(
            harness.store.requestActivate(
                harness.instance,
                from: replacement
            )
        )
        XCTAssertTrue(harness.controller.activationRequests.isEmpty)
    }

    @MainActor
    func testForgedLifecycleIdentityCannotRemoveTrackedRequest()
        throws
    {
        let harness = try StoreProcessAuthorityHarness(pid: 8_804)
        let forged = ProfileLaunchLifecycleSnapshot(
            requestID: harness.requestID,
            identity: ProfileActivityIdentity(
                applicationID: harness.application.id,
                applicationStorageID: UUID(),
                profileID: harness.profile.id,
                profileStorageID: harness.profile.storageID
            ),
            state: .terminated(
                processIdentifier: harness.instance.processIdentifier
            ),
            processIdentity: harness.instance.processIdentity,
            terminationDisposition: .expected
        )

        harness.store.handleLaunchLifecycle(
            forged,
            profileName: harness.profile.name
        )

        XCTAssertNotNil(
            harness.store.activeTrackedLaunches[harness.requestID]
        )
    }

    @MainActor
    func testForgedLifecycleStateCannotRemoveExactTrackedRequest()
        throws
    {
        let harness = try StoreProcessAuthorityHarness(pid: 8_807)
        let forged = ProfileLaunchLifecycleSnapshot(
            requestID: harness.requestID,
            identity: harness.launch.currentLifecycle.identity,
            state: .terminated(
                processIdentifier: harness.instance.processIdentifier
            ),
            processIdentity: harness.instance.processIdentity,
            terminationDisposition: .expected
        )

        harness.store.handleLaunchLifecycle(
            forged,
            profileName: harness.profile.name
        )

        XCTAssertNotNil(
            harness.store.activeTrackedLaunches[harness.requestID]
        )
        XCTAssertEqual(
            harness.launch.currentLifecycle.state,
            .running(
                processIdentifier: harness.instance.processIdentifier
            )
        )
    }

    @MainActor
    func testExternalInstanceCannotReachStoreControllerActions()
        throws
    {
        let harness = try StoreProcessAuthorityHarness(pid: 8_805)
        let external = ManagedApplicationInstance(
            processIdentity: harness.instance.processIdentity,
            requestID: nil,
            profileID: nil,
            profileStorageID: nil,
            profileName: nil
        )
        XCTAssertFalse(
            harness.store.requestQuit(
                external,
                from: harness.application
            )
        )
        XCTAssertTrue(harness.controller.quitRequests.isEmpty)
        XCTAssertTrue(
            harness.store.errorMessage?.contains(
                "not an exact instance"
            ) == true
        )
    }
}

private struct StartupAuthorityPersistence: LibraryPersisting {
    func load() throws -> [ManagedApplication] { [] }

    func save(_ applications: [ManagedApplication]) throws {}
}

private final class StoreAuthorityObservationFlag:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var invalidated = false

    var isInvalidated: Bool {
        lock.withLock { invalidated }
    }

    func markInvalidated() {
        lock.withLock { invalidated = true }
    }
}

@MainActor
private final class StoreProcessAuthorityHarness {
    let requestID = UUID()
    let profile: LaunchProfile
    let application: ManagedApplication
    let state = TestWorkspaceProcessState()
    let registry: ProfileActivityRegistry
    let opener = StoreAuthorityOpener()
    let observer: StoreAuthorityTerminationObserver
    let launcher: WorkspaceApplicationLauncher
    let controller = StoreAuthorityController()
    let store: LibraryStore
    let launch: TrackedApplicationLaunch
    let runningApplication: StoreAuthorityRunningApplication
    let instance: ManagedApplicationInstance

    init(pid: pid_t) throws {
        profile = LaunchProfile(name: "Work")
        application = ManagedApplication(
            displayName: "Test",
            bundleIdentifier: "example.test",
            appPath: "/Applications/Test.app",
            profiles: [profile]
        )
        registry = ProfileActivityRegistry(processInspector: state)
        observer = StoreAuthorityTerminationObserver(state: state)
        launcher = WorkspaceApplicationLauncher(
            opener: opener,
            terminationObserver: observer,
            processProvenanceInspector: state,
            launchRequestTimeProvider: ProvenanceTestTimeProvider()
        )
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Store-Authority-\(UUID().uuidString)",
                isDirectory: true
            )
        store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL: support
            ),
            profileActivityRegistry: registry,
            launcher: launcher,
            applicationInstanceController: controller
        )
        store.applications = [application]

        let expectedApplication = WorkspaceApplicationBundleIdentity(
            bundleURL: URL(fileURLWithPath: application.appPath),
            bundleIdentifier: application.bundleIdentifier
        )
        let prepared = PreparedLaunch(
            requestID: requestID,
            applicationID: application.id,
            applicationStorageID: application.storageID,
            profileID: profile.id,
            profileStorageID: profile.storageID,
            applicationIdentity: expectedApplication,
            arguments: [],
            environment: [:],
            isolation: PreparedLaunchIsolation(
                userDataURL: nil,
                codexHomeURL: nil,
                managesUserData: false,
                managesCodexHome: false
            ),
            configurationFingerprint:
                LaunchConfigurationFingerprint(digest: "authority")
        )
        launch = try launcher.launchTracked(
            prepared: prepared,
            activityRegistry: registry,
            lifecycleHandler: { _ in },
            eventHandler: { _ in }
        )
        runningApplication = StoreAuthorityRunningApplication(
            processIdentifier: pid
        )
        opener.complete(.success(runningApplication))
        store.activeTrackedLaunches[requestID] = launch
        let processIdentity = try XCTUnwrap(
            launch.supervisedProcessIdentity
        )
        instance = ManagedApplicationInstance(
            processIdentity: processIdentity,
            requestID: requestID,
            profileID: profile.id,
            profileStorageID: profile.storageID,
            profileName: profile.name,
            controlPresentation: .verifiedParallaxInstance
        )
        controller.discoveredInstances = [
            instance.presenting(.verificationUnavailable)
        ]
    }
}

@MainActor
private final class StoreAuthorityController:
    ApplicationInstanceControlling
{
    var onQuit: ((ManagedApplicationInstance) -> Void)?
    var discoveredInstances: [ManagedApplicationInstance] = []
    private(set) var quitRequests: [WorkspaceProcessIdentity] = []
    private(set) var activationRequests: [WorkspaceProcessIdentity] = []

    func instances(
        for application: ManagedApplication,
        trackedProcesses: [ProfileRunningProcess]
    ) -> [ManagedApplicationInstance] {
        discoveredInstances
    }

    func requestQuit(
        _ instance: ManagedApplicationInstance,
        from application: ManagedApplication
    ) throws {
        quitRequests.append(instance.processIdentity)
        onQuit?(instance)
    }

    func requestActivate(
        _ instance: ManagedApplicationInstance,
        from application: ManagedApplication
    ) throws {
        activationRequests.append(instance.processIdentity)
    }
}

private final class StoreAuthorityOpener:
    WorkspaceApplicationOpening,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var completion:
        (@Sendable (Result<any RunningApplicationInstance, Error>) -> Void)?

    func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completion:
            @escaping @Sendable (
                Result<any RunningApplicationInstance, Error>
            ) -> Void
    ) {
        lock.withLock { self.completion = completion }
    }

    func complete(
        _ result: Result<any RunningApplicationInstance, Error>
    ) {
        lock.withLock { completion }?(result)
    }
}

private final class StoreAuthorityRunningApplication:
    RunningApplicationInstance,
    @unchecked Sendable
{
    let processIdentifier: pid_t
    private let lock = NSLock()
    private var terminated = false

    init(processIdentifier: pid_t) {
        self.processIdentifier = processIdentifier
    }

    var isTerminated: Bool { lock.withLock { terminated } }

    func markTerminated() { lock.withLock { terminated = true } }
}

private final class StoreAuthorityTerminationObserver:
    RunningApplicationTerminationObserving,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let state: TestWorkspaceProcessState
    private var callbacks: [ObjectIdentifier: @Sendable () -> Void] = [:]

    init(state: TestWorkspaceProcessState) { self.state = state }

    func observeTermination(
        of application: any RunningApplicationInstance,
        handler: @escaping @Sendable () -> Void
    ) -> any RunningApplicationTerminationObservation {
        lock.withLock { callbacks[ObjectIdentifier(application)] = handler }
        return StoreAuthorityTerminationObservation()
    }

    func terminate(_ application: StoreAuthorityRunningApplication) {
        application.markTerminated()
        state.markExited(processIdentifier: application.processIdentifier)
        lock.withLock { callbacks[ObjectIdentifier(application)] }?()
    }
}

private final class StoreAuthorityTerminationObservation:
    RunningApplicationTerminationObservation,
    @unchecked Sendable
{
    func cancel() {}
}
