import AppKit
import Darwin
import Foundation
import XCTest
@testable import Parallax

final class LaunchLifecycleTests: XCTestCase {
    func testImmediateExitNeverReportsRunningAndCarriesImmutableIdentity()
        throws
    {
        let harness = LifecycleHarness()
        let requestID = UUID()
        let lifecycle = LockedLifecycleSnapshots()
        let events = LockedLifecycleEvents()
        let launch = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: requestID),
            activityRegistry: harness.registry,
            lifecycleHandler: { lifecycle.append($0) },
            eventHandler: { events.append($0) }
        )

        let process = LifecycleRunningApplication(
            processIdentifier: 8_101,
            isTerminated: true
        )
        harness.processState.markExited(processIdentifier: 8_101)
        harness.opener.complete(.success(process))

        XCTAssertEqual(lifecycle.values.count, 3)
        XCTAssertEqual(lifecycle.values[0].state, .requested)
        XCTAssertEqual(lifecycle.values[1].state, .launching)
        guard case .failed = lifecycle.values[2].state else {
            return XCTFail("Immediate exit must be a failed, unverified open.")
        }
        XCTAssertEqual(
            lifecycle.values[2].openingDisposition,
            .provenanceIndeterminate(
                processIdentifier: 8_101,
                reason: .exitedBeforeVerification
            )
        )
        XCTAssertNil(lifecycle.values[2].processIdentity)
        XCTAssertFalse(
            lifecycle.values.contains {
                if case .running = $0.state { return true }
                return false
            }
        )
        XCTAssertTrue(
            lifecycle.values.allSatisfy {
                $0.requestID == requestID
                    && $0.identity == harness.identity
            }
        )
        XCTAssertEqual(events.values.count, 2)
        XCTAssertEqual(events.values[0], .requested(requestID: requestID))
        guard case .failed = events.values[1] else {
            return XCTFail("Immediate exit must emit failure, not termination.")
        }
        guard case .failed = launch.currentLifecycle.state else {
            return XCTFail("Immediate exit must remain failed and unverified.")
        }
        XCTAssertFalse(harness.registry.isActive(identity: harness.identity))
    }

    func testOpenFailureRetainsUnknownOutcomeReceiptAndNeverRuns() throws {
        let harness = LifecycleHarness()
        let lifecycle = LockedLifecycleSnapshots()
        let events = LockedLifecycleEvents()
        let requestID = UUID()
        let launch = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: requestID),
            activityRegistry: harness.registry,
            lifecycleHandler: { lifecycle.append($0) },
            eventHandler: { events.append($0) }
        )

        harness.opener.complete(.failure(LifecycleTestError.openFailed))

        XCTAssertEqual(
            lifecycle.values.map(\.state),
            [
                .requested,
                .launching,
                .launching,
            ]
        )
        XCTAssertEqual(
            lifecycle.values.last?.openingDisposition,
            .outcomeUnknownAfterError(message: "open failed")
        )
        XCTAssertEqual(
            events.values,
            [
                .requested(requestID: requestID),
                .failed(requestID: requestID, message: "open failed"),
            ]
        )
        XCTAssertEqual(launch.currentLifecycle.state, .launching)
        XCTAssertTrue(harness.registry.isActive(identity: harness.identity))
    }

    func testProcessIdentityRegistrationFailureRetainsGateUntilTermination()
        throws
    {
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-Lifecycle-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: support) }
        let inspector = LifecycleProcessIdentityInspector()
        inspector.setLive(identity: inspector.ownerIdentity)
        let registry = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let opener = LifecycleApplicationOpener()
        let provenanceState = TestWorkspaceProcessState()
        let observer = LifecycleTerminationObserver(
            processState: provenanceState
        )
        let launcher = WorkspaceApplicationLauncher(
            opener: opener,
            terminationObserver: observer,
            processProvenanceInspector: provenanceState,
            launchRequestTimeProvider: ProvenanceTestTimeProvider()
        )
        let harness = LifecycleHarness()
        let requestID = UUID()
        let lifecycle = LockedLifecycleSnapshots()
        let events = LockedLifecycleEvents()
        let launch = try launcher.launchTracked(
            prepared: harness.prepared(requestID: requestID),
            activityRegistry: registry,
            lifecycleHandler: { lifecycle.append($0) },
            eventHandler: { events.append($0) }
        )
        let process = LifecycleRunningApplication(
            processIdentifier: 8_111
        )

        opener.complete(.success(process))

        XCTAssertEqual(launch.currentLifecycle.state, .launching)
        XCTAssertEqual(lifecycle.values.last?.state, .launching)
        XCTAssertFalse(events.values.contains { event in
            switch event {
            case .running, .trackingDegraded:
                true
            case .requested, .terminated, .failed:
                false
            }
        })
        XCTAssertTrue(registry.isActive(identity: harness.identity))
        XCTAssertTrue(
            registry.isStorageActive(
                applicationStorageID:
                    harness.identity.applicationStorageID,
                profileStorageID: harness.identity.profileStorageID
            )
        )
        XCTAssertEqual(observer.observationCount, 1)

        observer.terminate(process)

        guard case .failed = launch.currentLifecycle.state else {
            return XCTFail(
                "A process that exits before admission must fail unverified."
            )
        }
        XCTAssertEqual(
            launch.currentLifecycle.openingDisposition,
            .provenanceIndeterminate(
                processIdentifier: process.processIdentifier,
                reason: .exitedBeforeVerification
            )
        )
        XCTAssertNil(launch.currentLifecycle.processIdentity)
        XCTAssertFalse(registry.isActive(identity: harness.identity))
        XCTAssertFalse(
            registry.isStorageActive(
                applicationStorageID:
                    harness.identity.applicationStorageID,
                profileStorageID: harness.identity.profileStorageID
            )
        )
    }

    func testSameStorageLaunchIsBlockedAcrossDifferentLogicalIdentities()
        throws
    {
        let registry = ProfileActivityRegistry()
        let first = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID()
        )
        let second = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: first.applicationStorageID,
            profileID: UUID(),
            profileStorageID: first.profileStorageID
        )
        let lease = try registry.acquireLaunchLease(
            identity: first,
            requestID: UUID()
        )
        defer { lease.release() }

        XCTAssertThrowsError(
            try registry.acquireLaunchLease(
                identity: second,
                requestID: UUID()
            )
        ) { error in
            guard case ProfileActivityRegistryError.profileAlreadyActive =
                error
            else {
                return XCTFail("Expected canonical-storage launch rejection.")
            }
        }
    }

    func testLifecycleSnapshotRejectsRemovedOrReplacedIntegrationTargets() {
        let identity = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID()
        )
        let profile = LaunchProfile(
            id: identity.profileID,
            storageID: identity.profileStorageID,
            name: "Current"
        )
        let application = ManagedApplication(
            id: identity.applicationID,
            storageID: identity.applicationStorageID,
            displayName: "Current",
            appPath: "/Applications/Current.app",
            profiles: [profile]
        )
        let snapshot = ProfileLaunchLifecycleSnapshot(
            requestID: UUID(),
            identity: identity,
            state: .running(processIdentifier: 8_150)
        )

        XCTAssertTrue(
            snapshot.matches(application: application, profile: profile)
        )

        var removed = application
        removed.profiles = []
        XCTAssertFalse(
            snapshot.matches(application: removed, profile: profile)
        )

        let replaced = ManagedApplication(
            id: identity.applicationID,
            storageID: UUID(),
            displayName: application.displayName,
            appPath: application.appPath,
            profiles: [profile]
        )
        XCTAssertFalse(
            snapshot.matches(application: replaced, profile: profile)
        )
    }

    func testExpertOverrideRequiresExplicitCorruptionRiskAcknowledgement()
        throws
    {
        let registry = ProfileActivityRegistry()
        let first = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID()
        )
        let second = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: first.applicationStorageID,
            profileID: UUID(),
            profileStorageID: first.profileStorageID
        )
        let firstLease = try registry.acquireLaunchLease(
            identity: first,
            requestID: UUID()
        )
        defer { firstLease.release() }

        XCTAssertThrowsError(
            try registry.acquireLaunchLease(
                identity: second,
                requestID: UUID(),
                concurrentLaunchPolicy: .expertOverride(
                    ConcurrentProfileLaunchRiskAcknowledgement(
                        acknowledgesProfileDataCorruptionRisk: false
                    )
                )
            )
        ) { error in
            guard
                case ProfileActivityRegistryError
                    .expertOverrideRiskNotAcknowledged = error
            else {
                return XCTFail("Expected explicit risk acknowledgement.")
            }
        }

        let overrideLease = try registry.acquireLaunchLease(
            identity: second,
            requestID: UUID(),
            concurrentLaunchPolicy: .expertOverride(
                ConcurrentProfileLaunchRiskAcknowledgement(
                    acknowledgesProfileDataCorruptionRisk: true
                )
            )
        )
        defer { overrideLease.release() }

        XCTAssertTrue(registry.isActive(identity: first))
        XCTAssertTrue(registry.isActive(identity: second))
    }

    func testReverseTerminationKeepsSharedStorageActiveUntilBothExit()
        throws
    {
        let harness = LifecycleHarness()
        let firstRequestID = UUID()
        let secondRequestID = UUID()
        let firstLifecycle = LockedLifecycleSnapshots()
        let secondLifecycle = LockedLifecycleSnapshots()
        let firstLaunch = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: firstRequestID),
            activityRegistry: harness.registry,
            lifecycleHandler: { firstLifecycle.append($0) },
            eventHandler: { _ in }
        )
        let secondIdentity = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: harness.identity.applicationStorageID,
            profileID: UUID(),
            profileStorageID: harness.identity.profileStorageID
        )
        let secondLaunch = try harness.launcher.launchTracked(
            prepared: harness.prepared(
                requestID: secondRequestID,
                identity: secondIdentity
            ),
            activityRegistry: harness.registry,
            concurrentLaunchPolicy: .expertOverride(
                ConcurrentProfileLaunchRiskAcknowledgement(
                    acknowledgesProfileDataCorruptionRisk: true
                )
            ),
            lifecycleHandler: { secondLifecycle.append($0) },
            eventHandler: { _ in }
        )
        let firstProcess = LifecycleRunningApplication(
            processIdentifier: 8_201
        )
        let secondProcess = LifecycleRunningApplication(
            processIdentifier: 8_202
        )
        harness.opener.completeNext(.success(firstProcess))
        harness.opener.completeNext(.success(secondProcess))

        XCTAssertEqual(firstLaunch.currentLifecycle.state, .running(processIdentifier: 8_201))
        XCTAssertEqual(secondLaunch.currentLifecycle.state, .running(processIdentifier: 8_202))
        XCTAssertTrue(
            harness.registry.isStorageActive(
                applicationStorageID: harness.identity.applicationStorageID,
                profileStorageID: harness.identity.profileStorageID
            )
        )

        secondLaunch.noteTerminationRequested()
        XCTAssertEqual(
            secondLifecycle.values.last?.state,
            .terminating(processIdentifier: 8_202)
        )
        harness.terminationObserver.terminate(secondProcess)

        XCTAssertEqual(
            secondLifecycle.values.last?.state,
            .terminated(processIdentifier: 8_202)
        )
        XCTAssertEqual(
            secondLifecycle.values.last?.terminationDisposition,
            .expected
        )
        XCTAssertTrue(harness.registry.isActive(identity: harness.identity))
        XCTAssertTrue(
            harness.registry.isStorageActive(
                applicationStorageID: harness.identity.applicationStorageID,
                profileStorageID: harness.identity.profileStorageID
            )
        )

        harness.terminationObserver.terminate(firstProcess)

        XCTAssertEqual(
            firstLifecycle.values.last?.state,
            .terminated(processIdentifier: 8_201)
        )
        XCTAssertEqual(
            firstLifecycle.values.last?.terminationDisposition,
            .unexpected
        )
        XCTAssertFalse(
            harness.registry.isStorageActive(
                applicationStorageID: harness.identity.applicationStorageID,
                profileStorageID: harness.identity.profileStorageID
            )
        )
    }

    func testSynchronousTerminationDuringUserQuitIsExpected() throws {
        let harness = LifecycleHarness()
        let lifecycle = LockedLifecycleSnapshots()
        let launch = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: UUID()),
            activityRegistry: harness.registry,
            lifecycleHandler: { lifecycle.append($0) },
            eventHandler: { _ in }
        )
        let process = LifecycleRunningApplication(
            processIdentifier: 8_211
        )
        harness.opener.completeNext(.success(process))

        try launch.performTerminationRequest {
            harness.terminationObserver.terminate(process)
        }

        XCTAssertEqual(
            lifecycle.values.last?.state,
            .terminated(processIdentifier: 8_211)
        )
        XCTAssertEqual(
            lifecycle.values.last?.terminationDisposition,
            .expected
        )
    }

    func testRejectedQuitRestoresRunningAndKeepsLaterExitUnexpected()
        throws
    {
        let harness = LifecycleHarness()
        let lifecycle = LockedLifecycleSnapshots()
        let launch = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: UUID()),
            activityRegistry: harness.registry,
            lifecycleHandler: { lifecycle.append($0) },
            eventHandler: { _ in }
        )
        let process = LifecycleRunningApplication(
            processIdentifier: 8_212
        )
        harness.opener.completeNext(.success(process))

        XCTAssertThrowsError(
            try launch.performTerminationRequest {
                throw LifecycleTestError.quitRejected
            }
        )
        XCTAssertEqual(
            lifecycle.values.last?.state,
            .running(processIdentifier: 8_212)
        )

        harness.terminationObserver.terminate(process)

        XCTAssertEqual(
            lifecycle.values.last?.terminationDisposition,
            .unexpected
        )
    }

    func testDuplicateLateTerminationCannotClearAnotherOverriddenRequest()
        throws
    {
        let harness = LifecycleHarness()
        let firstRequestID = UUID()
        let secondRequestID = UUID()
        _ = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: firstRequestID),
            activityRegistry: harness.registry,
            eventHandler: { _ in }
        )
        let secondIdentity = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: harness.identity.applicationStorageID,
            profileID: UUID(),
            profileStorageID: harness.identity.profileStorageID
        )
        _ = try harness.launcher.launchTracked(
            prepared: harness.prepared(
                requestID: secondRequestID,
                identity: secondIdentity
            ),
            activityRegistry: harness.registry,
            concurrentLaunchPolicy: .expertOverride(
                ConcurrentProfileLaunchRiskAcknowledgement(
                    acknowledgesProfileDataCorruptionRisk: true
                )
            ),
            eventHandler: { _ in }
        )
        let firstProcess = LifecycleRunningApplication(
            processIdentifier: 8_301
        )
        let secondProcess = LifecycleRunningApplication(
            processIdentifier: 8_302
        )
        harness.opener.completeNext(.success(firstProcess))
        harness.opener.completeNext(.success(secondProcess))

        harness.terminationObserver.terminate(firstProcess)
        harness.terminationObserver.terminate(firstProcess)

        XCTAssertFalse(harness.registry.isActive(identity: harness.identity))
        XCTAssertTrue(harness.registry.isActive(identity: secondIdentity))
        XCTAssertEqual(
            harness.registry.activeRequestIDs(identity: secondIdentity),
            [secondRequestID]
        )
    }
}

final class LifecycleHarness {
    let identity = ProfileActivityIdentity(
        applicationID: UUID(),
        applicationStorageID: UUID(),
        profileID: UUID(),
        profileStorageID: UUID()
    )
    let processState = TestWorkspaceProcessState()
    lazy var registry = ProfileActivityRegistry(
        processInspector: processState
    )
    let opener = LifecycleApplicationOpener()
    lazy var terminationObserver = LifecycleTerminationObserver(
        processState: processState
    )
    lazy var launcher = WorkspaceApplicationLauncher(
        opener: opener,
        terminationObserver: terminationObserver,
        processProvenanceInspector: processState,
        launchRequestTimeProvider: ProvenanceTestTimeProvider()
    )

    func prepared(
        requestID: UUID,
        identity: ProfileActivityIdentity? = nil
    ) -> PreparedLaunch {
        let identity = identity ?? self.identity
        return PreparedLaunch(
            requestID: requestID,
            applicationID: identity.applicationID,
            applicationStorageID: identity.applicationStorageID,
            profileID: identity.profileID,
            profileStorageID: identity.profileStorageID,
            applicationIdentity: WorkspaceApplicationBundleIdentity(
                bundleURL: URL(
                    fileURLWithPath: "/Applications/Lifecycle Test.app"
                ),
                bundleIdentifier: "com.parallax.lifecycle-test"
            ),
            arguments: [],
            environment: [:],
            isolation: PreparedLaunchIsolation(
                userDataURL: nil,
                codexHomeURL: nil,
                managesUserData: false,
                managesCodexHome: false
            ),
            configurationFingerprint:
                LaunchConfigurationFingerprint(digest: "lifecycle-test")
        )
    }
}

private enum LifecycleTestError: LocalizedError {
    case openFailed
    case quitRejected

    var errorDescription: String? {
        switch self {
        case .openFailed: "open failed"
        case .quitRejected: "quit rejected"
        }
    }
}

final class LifecycleApplicationOpener:
    WorkspaceApplicationOpening,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var completions: [
        @Sendable (Result<any RunningApplicationInstance, Error>) -> Void
    ] = []
    var synchronousResult:
        Result<any RunningApplicationInstance, Error>?

    func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completion:
            @escaping @Sendable (
                Result<any RunningApplicationInstance, Error>
            ) -> Void
    ) {
        let immediate = lock.withLock {
            if synchronousResult == nil {
                completions.append(completion)
            }
            return synchronousResult
        }
        if let immediate { completion(immediate) }
    }

    func complete(
        _ result: Result<any RunningApplicationInstance, Error>
    ) {
        completeNext(result)
    }

    func completeNext(
        _ result: Result<any RunningApplicationInstance, Error>
    ) {
        let completion = lock.withLock {
            completions.isEmpty ? nil : completions.removeFirst()
        }
        completion?(result)
    }
}

final class LifecycleRunningApplication:
    RunningApplicationInstance,
    @unchecked Sendable
{
    let processIdentifier: pid_t
    private let lock = NSLock()
    private var terminated: Bool

    init(processIdentifier: pid_t, isTerminated: Bool = false) {
        self.processIdentifier = processIdentifier
        terminated = isTerminated
    }

    var isTerminated: Bool {
        lock.withLock { terminated }
    }

    func markTerminated() {
        lock.withLock {
            terminated = true
        }
    }
}

final class LifecycleTerminationObserver:
    RunningApplicationTerminationObserving,
    @unchecked Sendable
{
    private struct Handler {
        let observation: LifecycleTerminationObservation
        let callback: @Sendable () -> Void
    }

    private let lock = NSLock()
    private let processState: TestWorkspaceProcessState
    private var handlers: [ObjectIdentifier: Handler] = [:]

    init(processState: TestWorkspaceProcessState) {
        self.processState = processState
    }

    var observationCount: Int {
        lock.withLock {
            handlers.values.filter { !$0.observation.isCancelled }.count
        }
    }

    func observeTermination(
        of application: any RunningApplicationInstance,
        handler: @escaping @Sendable () -> Void
    ) -> any RunningApplicationTerminationObservation {
        let observation = LifecycleTerminationObservation()
        lock.withLock {
            handlers[ObjectIdentifier(application)] = Handler(
                observation: observation,
                callback: handler
            )
        }
        return observation
    }

    func terminate(_ application: LifecycleRunningApplication) {
        application.markTerminated()
        processState.markExited(
            processIdentifier: application.processIdentifier
        )
        let handler = lock.withLock {
            handlers[ObjectIdentifier(application)]
        }
        guard handler?.observation.isCancelled == false else { return }
        handler?.callback()
    }
}

private final class LifecycleProcessIdentityInspector:
    ProcessIdentityInspecting,
    @unchecked Sendable
{
    let ownerIdentity = ProcessStartIdentity(
        processIdentifier: Darwin.getpid(),
        startTimeSeconds: 1_000,
        startTimeMicroseconds: 17
    )
    private let lock = NSLock()
    private var inspections: [pid_t: ProcessIdentityInspection] = [:]

    func inspect(
        processIdentifier: pid_t
    ) -> ProcessIdentityInspection {
        lock.withLock {
            inspections[processIdentifier] ?? .ambiguous
        }
    }

    func setLive(identity: ProcessStartIdentity) {
        lock.withLock {
            inspections[identity.processIdentifier] = .live(identity)
        }
    }
}

private final class LifecycleTerminationObservation:
    RunningApplicationTerminationObservation,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
        }
    }
}

private final class LockedLifecycleSnapshots: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProfileLaunchLifecycleSnapshot] = []

    var values: [ProfileLaunchLifecycleSnapshot] {
        lock.withLock { storage }
    }

    func append(_ snapshot: ProfileLaunchLifecycleSnapshot) {
        lock.withLock {
            storage.append(snapshot)
        }
    }
}

private final class LockedLifecycleEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TrackedApplicationLaunchEvent] = []

    var values: [TrackedApplicationLaunchEvent] {
        lock.withLock { storage }
    }

    func append(_ event: TrackedApplicationLaunchEvent) {
        lock.withLock {
            storage.append(event)
        }
    }
}
