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
        harness.opener.complete(.success(process))

        XCTAssertEqual(
            lifecycle.values.map(\.state),
            [
                .requested,
                .launching,
                .terminated(processIdentifier: 8_101),
            ]
        )
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
        XCTAssertEqual(
            events.values,
            [
                .requested(requestID: requestID),
                .terminated(
                    requestID: requestID,
                    processIdentifier: 8_101
                ),
            ]
        )
        XCTAssertEqual(
            launch.currentLifecycle.state,
            .terminated(processIdentifier: 8_101)
        )
        XCTAssertFalse(harness.registry.isActive(identity: harness.identity))
    }

    func testOpenFailureTransitionsToFailedAndReleasesActivity() throws {
        let harness = LifecycleHarness()
        let lifecycle = LockedLifecycleSnapshots()
        _ = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: UUID()),
            activityRegistry: harness.registry,
            lifecycleHandler: { lifecycle.append($0) },
            eventHandler: { _ in }
        )

        harness.opener.complete(.failure(LifecycleTestError.openFailed))

        XCTAssertEqual(
            lifecycle.values.map(\.state),
            [
                .requested,
                .launching,
                .failed(message: "open failed"),
            ]
        )
        XCTAssertFalse(harness.registry.isActive(identity: harness.identity))
    }

    func testProcessIdentityRegistrationFailureIsTerminalAndReleasesActivity()
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
        let observer = LifecycleTerminationObserver()
        let launcher = WorkspaceApplicationLauncher(
            opener: opener,
            terminationObserver: observer
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

        guard case .failed(let message) = launch.currentLifecycle.state else {
            return XCTFail("Expected terminal registration failure.")
        }
        XCTAssertTrue(message.contains("verifiable start identity"))
        XCTAssertEqual(lifecycle.values.last?.state, .failed(message: message))
        XCTAssertEqual(
            events.values.last,
            .failed(requestID: requestID, message: message)
        )
        XCTAssertFalse(registry.isActive(identity: harness.identity))
        XCTAssertFalse(
            registry.isStorageActive(
                applicationStorageID:
                    harness.identity.applicationStorageID,
                profileStorageID: harness.identity.profileStorageID
            )
        )
        XCTAssertEqual(observer.observationCount, 0)
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
        XCTAssertFalse(
            harness.registry.isStorageActive(
                applicationStorageID: harness.identity.applicationStorageID,
                profileStorageID: harness.identity.profileStorageID
            )
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

private final class LifecycleHarness {
    let identity = ProfileActivityIdentity(
        applicationID: UUID(),
        applicationStorageID: UUID(),
        profileID: UUID(),
        profileStorageID: UUID()
    )
    let registry = ProfileActivityRegistry()
    let opener = LifecycleApplicationOpener()
    let terminationObserver = LifecycleTerminationObserver()
    lazy var launcher = WorkspaceApplicationLauncher(
        opener: opener,
        terminationObserver: terminationObserver
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
            applicationURL: URL(
                fileURLWithPath: "/Applications/Lifecycle Test.app"
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

    var errorDescription: String? {
        "open failed"
    }
}

private final class LifecycleApplicationOpener:
    WorkspaceApplicationOpening,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var completions: [
        @Sendable (Result<any RunningApplicationInstance, Error>) -> Void
    ] = []

    func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completion:
            @escaping @Sendable (
                Result<any RunningApplicationInstance, Error>
            ) -> Void
    ) {
        lock.withLock {
            completions.append(completion)
        }
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

private final class LifecycleRunningApplication:
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

private final class LifecycleTerminationObserver:
    RunningApplicationTerminationObserving,
    @unchecked Sendable
{
    private struct Handler {
        let observation: LifecycleTerminationObservation
        let callback: @Sendable () -> Void
    }

    private let lock = NSLock()
    private var handlers: [ObjectIdentifier: Handler] = [:]

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
