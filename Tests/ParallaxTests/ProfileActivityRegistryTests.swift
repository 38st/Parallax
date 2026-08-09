import AppKit
import Darwin
import Foundation
import XCTest
@testable import Parallax

final class ProfileActivityRegistryTests: XCTestCase {
    func testLeasesAreReferenceCountedAndReleaseIsIdempotent() throws {
        let registry = ProfileActivityRegistry()
        let identity = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID()
        )
        let requestID = UUID()
        let first = try registry.acquire(identity: identity, requestID: requestID)
        let second = try registry.acquire(identity: identity, requestID: requestID)

        XCTAssertTrue(registry.isActive(identity: identity))
        XCTAssertEqual(registry.activeLeaseCount(identity: identity), 2)
        XCTAssertEqual(registry.activeRequestIDs(identity: identity), [requestID])

        first.release()
        first.release()
        XCTAssertTrue(registry.isActive(identity: identity))
        XCTAssertEqual(registry.activeLeaseCount(identity: identity), 1)

        second.release()
        XCTAssertFalse(registry.isActive(identity: identity))
        XCTAssertEqual(registry.activeLeaseCount(identity: identity), 0)
        XCTAssertTrue(registry.activeRequestIDs(identity: identity).isEmpty)
    }

    func testRequestIdentityConflictIsRejected() throws {
        let registry = ProfileActivityRegistry()
        let requestID = UUID()
        let firstIdentity = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID()
        )
        let secondIdentity = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID()
        )
        let lease = try registry.acquire(identity: firstIdentity, requestID: requestID)
        defer { lease.release() }

        XCTAssertThrowsError(
            try registry.acquire(identity: secondIdentity, requestID: requestID)
        ) { error in
            XCTAssertTrue(error is ProfileActivityRegistryError)
        }
        XCTAssertTrue(registry.isActive(identity: firstIdentity))
        XCTAssertFalse(registry.isActive(identity: secondIdentity))
    }

    func testConcurrentRequestForSameStorageIdentityIsRejected()
        throws
    {
        let registry = ProfileActivityRegistry()
        let identity = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID()
        )
        let first = try registry.acquire(
            identity: identity,
            requestID: UUID()
        )
        defer { first.release() }

        XCTAssertThrowsError(
            try registry.acquire(
                identity: identity,
                requestID: UUID()
            )
        ) { error in
            guard
                let registryError =
                    error as? ProfileActivityRegistryError,
                case .profileAlreadyActive = registryError
            else {
                return XCTFail("Expected profileAlreadyActive")
            }
        }
    }

    func testLeaseDeinitializationReleasesActivity() throws {
        let registry = ProfileActivityRegistry()
        let identity = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID()
        )
        var lease: ProfileActivityLease? = try registry.acquire(
            identity: identity,
            requestID: UUID()
        )
        XCTAssertNotNil(lease)
        XCTAssertTrue(registry.isActive(identity: identity))

        lease = nil

        XCTAssertFalse(registry.isActive(identity: identity))
    }

    func testActivityCanBeQueriedByImmutableStorageIdentity() throws {
        let registry = ProfileActivityRegistry()
        let identity = ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID()
        )
        let lease = try registry.acquire(identity: identity, requestID: UUID())
        defer { lease.release() }

        XCTAssertTrue(
            registry.isStorageActive(
                applicationStorageID: identity.applicationStorageID,
                profileStorageID: identity.profileStorageID
            )
        )
        XCTAssertFalse(
            registry.isStorageActive(
                applicationStorageID: identity.applicationStorageID,
                profileStorageID: UUID()
            )
        )
    }

    func testExactRunningPublicationCannotRebindReusedPID() throws {
        let state = TestWorkspaceProcessState()
        let registry = ProfileActivityRegistry(processInspector: state)
        let expected = ProcessStartIdentity(
            processIdentifier: 4_242,
            startTimeSeconds: 500,
            startTimeMicroseconds: 10
        )
        state.processInspections[expected.processIdentifier] = .live(
            ProcessStartIdentity(
                processIdentifier: expected.processIdentifier,
                startTimeSeconds: expected.startTimeSeconds,
                startTimeMicroseconds: expected.startTimeMicroseconds + 1
            )
        )

        XCTAssertThrowsError(
            try registry.recordRunningProcess(
                requestID: UUID(),
                processIdentity: expected
            )
        ) { error in
            guard
                case ProfileActivityRegistryError.processIdentityChanged(
                    let processIdentifier
                ) = error,
                processIdentifier == expected.processIdentifier
            else {
                return XCTFail("Expected exact PID/start rebind rejection.")
            }
        }
    }

    func testAcceptedOpenRetainsActivityUntilActualProcessTerminates() throws {
        let harness = try LaunchHarness()
        let requestID = UUID()
        let events = LockedEvents()

        _ = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: requestID),
            activityRegistry: harness.registry
        ) { events.append($0) }

        XCTAssertTrue(harness.registry.isActive(identity: harness.identity))
        XCTAssertEqual(events.values, [.requested(requestID: requestID)])

        let running = FakeRunningApplication(processIdentifier: 42)
        harness.opener.complete(.success(running))

        XCTAssertTrue(harness.registry.isActive(identity: harness.identity))
        XCTAssertEqual(
            events.values,
            [
                .requested(requestID: requestID),
                .running(requestID: requestID, processIdentifier: 42)
            ]
        )

        harness.terminationObserver.terminate(running)

        XCTAssertFalse(harness.registry.isActive(identity: harness.identity))
        XCTAssertEqual(
            events.values,
            [
                .requested(requestID: requestID),
                .running(requestID: requestID, processIdentifier: 42),
                .terminated(requestID: requestID, processIdentifier: 42)
            ]
        )

        harness.terminationObserver.terminate(running)
        XCTAssertEqual(events.values.count, 3)
    }

    func testAlreadyTerminatedAtOpenCompletionReleasesActivity() throws {
        let harness = try LaunchHarness()
        let requestID = UUID()
        let events = LockedEvents()
        _ = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: requestID),
            activityRegistry: harness.registry
        ) { events.append($0) }
        let running = FakeRunningApplication(processIdentifier: 7, isTerminated: true)
        harness.processState.markExited(processIdentifier: 7)

        harness.opener.complete(.success(running))

        XCTAssertFalse(harness.registry.isActive(identity: harness.identity))
        XCTAssertEqual(events.values.count, 2)
        XCTAssertEqual(events.values[0], .requested(requestID: requestID))
        guard case .failed = events.values[1] else {
            return XCTFail("Already-exited open must fail unverified.")
        }
    }

    func testTerminationDuringObserverInstallationIsRaceSafe() throws {
        let harness = try LaunchHarness()
        let requestID = UUID()
        let events = LockedEvents()
        harness.terminationObserver.terminateDuringObservation = true
        _ = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: requestID),
            activityRegistry: harness.registry
        ) { events.append($0) }
        let running = FakeRunningApplication(processIdentifier: 99)

        harness.opener.complete(.success(running))

        XCTAssertFalse(harness.registry.isActive(identity: harness.identity))
        XCTAssertEqual(
            harness.terminationObserver.lastObservation?.isCancelled,
            true
        )
        XCTAssertEqual(events.values.count, 2)
        XCTAssertEqual(events.values[0], .requested(requestID: requestID))
        guard case .failed = events.values[1] else {
            return XCTFail(
                "Termination before running publication must fail unverified."
            )
        }
    }

    func testOpenFailureReportsErrorButRetainsAmbiguousActivity() throws {
        let harness = try LaunchHarness()
        let requestID = UUID()
        let events = LockedEvents()
        _ = try harness.launcher.launchTracked(
            prepared: harness.prepared(requestID: requestID),
            activityRegistry: harness.registry
        ) { events.append($0) }

        harness.opener.complete(.failure(TestLaunchError.openFailed))

        XCTAssertTrue(harness.registry.isActive(identity: harness.identity))
        XCTAssertEqual(
            events.values,
            [
                .requested(requestID: requestID),
                .failed(requestID: requestID, message: "open failed")
            ]
        )
    }

    func testRunningProcessSurvivesRegistryRecreation() throws {
        let support = try makeTemporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let inspector = FakeProcessIdentityInspector()
        inspector.setLive(identity: inspector.ownerIdentity)
        let child = ProcessStartIdentity(
            processIdentifier: 7_001,
            startTimeSeconds: 300,
            startTimeMicroseconds: 17
        )
        inspector.setLive(identity: child)
        let identity = makeIdentity()
        let requestID = UUID()
        let first = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let lease = try first.acquireLaunchLease(
            identity: identity,
            requestID: requestID
        )
        try first.markLaunchOpening(requestID: requestID)
        try first.recordRunningProcess(
            requestID: requestID,
            processIdentifier: child.processIdentifier
        )

        let restarted = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let report = try restarted.reconcileDurableActivity()

        XCTAssertEqual(report.recoveredLiveCount, 1)
        XCTAssertEqual(report.ambiguousCount, 0)
        XCTAssertTrue(restarted.isActive(identity: identity))
        XCTAssertEqual(
            restarted.runningProcesses(
                applicationStorageID:
                    identity.applicationStorageID
            ),
            [
                ProfileRunningProcess(
                    requestID: requestID,
                    identity: identity,
                    process: child
                )
            ]
        )

        inspector.setDead(processIdentifier: child.processIdentifier)
        XCTAssertFalse(restarted.isActive(identity: identity))
        XCTAssertTrue(
            restarted.runningProcesses(
                applicationStorageID:
                    identity.applicationStorageID
            ).isEmpty
        )
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: durableRoot(in: support).path
            ).filter { !$0.hasPrefix(".") }.isEmpty
        )
        lease.release()
    }

    func testPIDReuseWithDifferentStartIdentityExpiresRecordedLaunch() throws {
        let support = try makeTemporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let inspector = FakeProcessIdentityInspector()
        inspector.setLive(identity: inspector.ownerIdentity)
        let recorded = ProcessStartIdentity(
            processIdentifier: 7_002,
            startTimeSeconds: 400,
            startTimeMicroseconds: 1
        )
        inspector.setLive(identity: recorded)
        let identity = makeIdentity()
        let requestID = UUID()
        let first = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let lease = try first.acquireLaunchLease(
            identity: identity,
            requestID: requestID
        )
        try first.markLaunchOpening(requestID: requestID)
        try first.recordRunningProcess(
            requestID: requestID,
            processIdentifier: recorded.processIdentifier
        )
        let restarted = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let initialReport = try restarted.reconcileDurableActivity()
        XCTAssertEqual(initialReport.recoveredLiveCount, 1)
        XCTAssertTrue(restarted.isActive(identity: identity))
        inspector.setLive(
            identity: ProcessStartIdentity(
                processIdentifier: recorded.processIdentifier,
                startTimeSeconds: recorded.startTimeSeconds + 1,
                startTimeMicroseconds: recorded.startTimeMicroseconds
            )
        )

        XCTAssertFalse(restarted.isActive(identity: identity))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: durableRoot(in: support).path
            ).filter { !$0.hasPrefix(".") }.isEmpty
        )
        lease.release()
    }

    func testDeadRecordedProcessIsRemovedDuringReconciliation() throws {
        let support = try makeTemporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let inspector = FakeProcessIdentityInspector()
        inspector.setLive(identity: inspector.ownerIdentity)
        let child = ProcessStartIdentity(
            processIdentifier: 7_003,
            startTimeSeconds: 500,
            startTimeMicroseconds: 2
        )
        inspector.setLive(identity: child)
        let identity = makeIdentity()
        let requestID = UUID()
        let first = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let lease = try first.acquireLaunchLease(
            identity: identity,
            requestID: requestID
        )
        try first.markLaunchOpening(requestID: requestID)
        try first.recordRunningProcess(
            requestID: requestID,
            processIdentifier: child.processIdentifier
        )
        let restarted = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let initialReport = try restarted.reconcileDurableActivity()
        XCTAssertEqual(initialReport.recoveredLiveCount, 1)
        XCTAssertTrue(restarted.isActive(identity: identity))
        inspector.setDead(processIdentifier: child.processIdentifier)

        XCTAssertFalse(restarted.isActive(identity: identity))
        lease.release()
    }

    func testPinnedRootSwapCannotRedirectDeadActivityCleanup() throws {
        let support = try makeTemporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let inspector = FakeProcessIdentityInspector()
        inspector.setLive(identity: inspector.ownerIdentity)
        let child = ProcessStartIdentity(
            processIdentifier: 7_005,
            startTimeSeconds: 700,
            startTimeMicroseconds: 4
        )
        inspector.setLive(identity: child)
        let identity = makeIdentity()
        let requestID = UUID()
        let first = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let lease = try first.acquireLaunchLease(
            identity: identity,
            requestID: requestID
        )
        try first.markLaunchOpening(requestID: requestID)
        try first.recordRunningProcess(
            requestID: requestID,
            processIdentifier: child.processIdentifier
        )
        let restarted = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        _ = try restarted.reconcileDurableActivity()
        let journalRoot = durableRoot(in: support)
        let originalRoot = support.appendingPathComponent(
            "OriginalActiveLaunches",
            isDirectory: true
        )
        try FileManager.default.moveItem(at: journalRoot, to: originalRoot)
        let outsideRoot = support.appendingPathComponent(
            "OutsideActiveLaunches",
            isDirectory: true
        )
        let outsideRequest = outsideRoot.appendingPathComponent(
            requestID.uuidString.lowercased(),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outsideRequest,
            withIntermediateDirectories: true
        )
        let outsideSentinel = outsideRequest.appendingPathComponent(
            "must-survive.txt"
        )
        try Data("outside".utf8).write(to: outsideSentinel)
        try FileManager.default.createSymbolicLink(
            at: journalRoot,
            withDestinationURL: outsideRoot
        )
        inspector.setDead(processIdentifier: child.processIdentifier)

        XCTAssertTrue(restarted.isActive(identity: identity))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsideSentinel.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: originalRoot.appendingPathComponent(
                    requestID.uuidString.lowercased()
                ).path
            )
        )
        lease.release()
    }

    func testPinnedAncestorSwapCannotRedirectDeadActivityCleanup() throws {
        let support = try makeTemporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let inspector = FakeProcessIdentityInspector()
        inspector.setLive(identity: inspector.ownerIdentity)
        let child = ProcessStartIdentity(
            processIdentifier: 7_006,
            startTimeSeconds: 800,
            startTimeMicroseconds: 5
        )
        inspector.setLive(identity: child)
        let identity = makeIdentity()
        let requestID = UUID()
        let first = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let lease = try first.acquireLaunchLease(
            identity: identity,
            requestID: requestID
        )
        try first.markLaunchOpening(requestID: requestID)
        try first.recordRunningProcess(
            requestID: requestID,
            processIdentifier: child.processIdentifier
        )
        let restarted = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        _ = try restarted.reconcileDurableActivity()

        let parallaxRoot = support.appendingPathComponent(
            "Parallax",
            isDirectory: true
        )
        let originalParallax = support.appendingPathComponent(
            "OriginalParallax",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: parallaxRoot,
            to: originalParallax
        )
        let outsideParallax = support.appendingPathComponent(
            "OutsideParallax",
            isDirectory: true
        )
        let outsideRequest = outsideParallax
            .appendingPathComponent("ActiveLaunches", isDirectory: true)
            .appendingPathComponent(
                requestID.uuidString.lowercased(),
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: outsideRequest,
            withIntermediateDirectories: true
        )
        let outsideSentinel = outsideRequest.appendingPathComponent(
            "must-survive.txt"
        )
        try Data("outside".utf8).write(to: outsideSentinel)
        try FileManager.default.createSymbolicLink(
            at: parallaxRoot,
            withDestinationURL: outsideParallax
        )
        inspector.setDead(processIdentifier: child.processIdentifier)

        XCTAssertTrue(restarted.isActive(identity: identity))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: outsideSentinel.path)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: originalParallax
                    .appendingPathComponent(
                        "ActiveLaunches",
                        isDirectory: true
                    )
                    .appendingPathComponent(
                        requestID.uuidString.lowercased()
                    ).path
            )
        )
        lease.release()
    }

    func testCorruptReceiptIsPreservedAndFailsClosed() throws {
        let support = try makeTemporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let inspector = FakeProcessIdentityInspector()
        inspector.setLive(identity: inspector.ownerIdentity)
        let identity = makeIdentity()
        let requestID = UUID()
        let store = try DurableLaunchActivityStore(
            applicationSupportURL: support
        )
        try store.createRequest(
            requestID: requestID,
            identity: identity,
            ownerProcess: inspector.ownerIdentity
        )
        try store.markOpening(requestID: requestID)
        let processURL = durableRoot(in: support)
            .appendingPathComponent(requestID.uuidString.lowercased())
            .appendingPathComponent("process.json")
        try Data("{not-json".utf8).write(to: processURL)

        let restarted = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let report = try restarted.reconcileDurableActivity()

        XCTAssertEqual(report.ambiguousCount, 1)
        XCTAssertTrue(restarted.isActive(identity: identity))
        XCTAssertTrue(FileManager.default.fileExists(atPath: processURL.path))
    }

    func testOpeningWithoutProcessIdentityFailsClosedAfterRestart() throws {
        let support = try makeTemporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let inspector = FakeProcessIdentityInspector()
        inspector.setLive(identity: inspector.ownerIdentity)
        let identity = makeIdentity()
        let requestID = UUID()
        let first = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let lease = try first.acquireLaunchLease(
            identity: identity,
            requestID: requestID
        )
        try first.markLaunchOpening(requestID: requestID)
        inspector.setDead(
            processIdentifier: inspector.ownerIdentity.processIdentifier
        )

        let restarted = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let report = try restarted.reconcileDurableActivity()

        XCTAssertEqual(report.ambiguousCount, 1)
        XCTAssertEqual(report.globalAmbiguousCount, 0)
        XCTAssertTrue(restarted.isActive(identity: identity))
        XCTAssertFalse(restarted.isActive(identity: makeIdentity()))
        lease.release()
    }

    func testSystemInspectorUsesStableStartIdentityForCurrentProcess() {
        let inspector = SystemProcessIdentityInspector()

        guard case .live(let first) = inspector.inspect(
            processIdentifier: Darwin.getpid()
        ), case .live(let second) = inspector.inspect(
            processIdentifier: Darwin.getpid()
        ) else {
            return XCTFail("Expected a live identity for the current process")
        }

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.processIdentifier, Darwin.getpid())
    }

    func testDurableMarkersAreRestrictiveAtomicAndContainNoConfiguration() throws {
        let support = try makeTemporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let inspector = FakeProcessIdentityInspector()
        inspector.setLive(identity: inspector.ownerIdentity)
        let child = ProcessStartIdentity(
            processIdentifier: 7_004,
            startTimeSeconds: 600,
            startTimeMicroseconds: 3
        )
        inspector.setLive(identity: child)
        let identity = makeIdentity()
        let requestID = UUID()
        let registry = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let lease = try registry.acquireLaunchLease(
            identity: identity,
            requestID: requestID
        )
        try registry.markLaunchOpening(requestID: requestID)
        try registry.recordRunningProcess(
            requestID: requestID,
            processIdentifier: child.processIdentifier
        )
        let root = durableRoot(in: support)
        let requestDirectory = root.appendingPathComponent(
            requestID.uuidString.lowercased()
        )

        XCTAssertEqual(try permissions(at: root), 0o700)
        XCTAssertEqual(try permissions(at: requestDirectory), 0o700)
        let names = try FileManager.default.contentsOfDirectory(
            atPath: requestDirectory.path
        )
        XCTAssertEqual(
            Set(names),
            ["request.json", "opening.json", "process.json"]
        )
        XCTAssertFalse(names.contains { $0.hasPrefix(".tmp-") })
        for name in names {
            let url = requestDirectory.appendingPathComponent(name)
            XCTAssertEqual(try permissions(at: url), 0o600)
            let contents = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(contents.contains("OPENAI_API_KEY"))
            XCTAssertFalse(contents.contains("CODEX_HOME"))
            XCTAssertFalse(contents.contains("--user-data-dir"))
        }

        try registry.completeDurableLaunch(
            requestID: requestID,
            completion: .terminated
        )
        lease.release()
    }

    func testSeparateRegistriesAtomicallyRejectSameProfileStorage()
        throws
    {
        let support = try makeTemporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let inspector = FakeProcessIdentityInspector()
        inspector.setLive(identity: inspector.ownerIdentity)
        let identity = makeIdentity()
        let first = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let second = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let lease = try first.acquireLaunchLease(
            identity: identity,
            requestID: UUID()
        )
        defer { lease.release() }

        XCTAssertThrowsError(
            try second.acquireLaunchLease(
                identity: ProfileActivityIdentity(
                    applicationID: UUID(),
                    applicationStorageID:
                        identity.applicationStorageID,
                    profileID: UUID(),
                    profileStorageID: identity.profileStorageID
                ),
                requestID: UUID()
            )
        ) { error in
            guard
                case DurableLaunchActivityStoreError
                    .profileAlreadyActive = error
            else {
                return XCTFail(
                    "Expected durable cross-registry profile exclusion, got \(error)"
                )
            }
        }
    }

    func testSeparateProfilesCannotClaimTheSameRunningProcess()
        throws
    {
        let support = try makeTemporarySupportDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let inspector = FakeProcessIdentityInspector()
        inspector.setLive(identity: inspector.ownerIdentity)
        let child = ProcessStartIdentity(
            processIdentifier: 7_099,
            startTimeSeconds: 9_000,
            startTimeMicroseconds: 9
        )
        inspector.setLive(identity: child)
        let first = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let second = try ProfileActivityRegistry(
            applicationSupportURL: support,
            processInspector: inspector
        )
        let firstIdentity = makeIdentity()
        let firstRequestID = UUID()
        let firstLease = try first.acquireLaunchLease(
            identity: firstIdentity,
            requestID: firstRequestID
        )
        defer { firstLease.release() }
        try first.markLaunchOpening(requestID: firstRequestID)
        try first.recordRunningProcess(
            requestID: firstRequestID,
            processIdentifier: child.processIdentifier
        )

        let secondIdentity = makeIdentity()
        let secondRequestID = UUID()
        let secondLease = try second.acquireLaunchLease(
            identity: secondIdentity,
            requestID: secondRequestID
        )
        defer { secondLease.release() }
        try second.markLaunchOpening(requestID: secondRequestID)

        XCTAssertThrowsError(
            try second.recordRunningProcess(
                requestID: secondRequestID,
                processIdentifier: child.processIdentifier
            )
        ) { error in
            guard
                case DurableLaunchActivityStoreError
                    .processAlreadyTracked(child.processIdentifier) = error
            else {
                return XCTFail(
                    "Expected duplicate process attribution rejection, got \(error)"
                )
            }
        }
    }

    private func makeIdentity() -> ProfileActivityIdentity {
        ProfileActivityIdentity(
            applicationID: UUID(),
            applicationStorageID: UUID(),
            profileID: UUID(),
            profileStorageID: UUID()
        )
    }

    private func makeTemporarySupportDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ParallaxDurableLaunchTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    private func durableRoot(in support: URL) -> URL {
        support.appendingPathComponent("Parallax", isDirectory: true)
            .appendingPathComponent("ActiveLaunches", isDirectory: true)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        ).intValue
    }
}

private final class LaunchHarness {
    let temporaryDirectory: URL
    let application: ManagedApplication
    let profile: LaunchProfile
    let identity: ProfileActivityIdentity
    let processState = TestWorkspaceProcessState()
    lazy var registry = ProfileActivityRegistry(
        processInspector: processState
    )
    let opener = FakeApplicationOpener()
    lazy var terminationObserver = FakeTerminationObserver(
        processState: processState
    )
    lazy var launcher = WorkspaceApplicationLauncher(
        opener: opener,
        terminationObserver: terminationObserver,
        processProvenanceInspector: processState,
        launchRequestTimeProvider: ProvenanceTestTimeProvider()
    )

    init() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ParallaxTrackedLaunchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        self.temporaryDirectory = temporaryDirectory
        application = ManagedApplication(
            displayName: "Test",
            appPath: temporaryDirectory.path
        )
        profile = LaunchProfile(name: "Profile")
        identity = ProfileActivityIdentity(
            applicationID: application.id,
            applicationStorageID: application.storageID,
            profileID: profile.id,
            profileStorageID: profile.storageID
        )
    }

    func prepared(requestID: UUID) -> PreparedLaunch {
        PreparedLaunch(
            requestID: requestID,
            applicationID: application.id,
            applicationStorageID: application.storageID,
            profileID: profile.id,
            profileStorageID: profile.storageID,
            applicationIdentity: WorkspaceApplicationBundleIdentity(
                bundleURL: URL(fileURLWithPath: application.appPath),
                bundleIdentifier: "com.parallax.profile-activity-test"
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
                LaunchConfigurationFingerprint(digest: "test")
        )
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

private final class LockedEvents: @unchecked Sendable {
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

private final class FakeApplicationOpener: WorkspaceApplicationOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<any RunningApplicationInstance, Error>) -> Void)?

    func openApplication(
        at url: URL,
        configuration: NSWorkspace.OpenConfiguration,
        completion: @escaping @Sendable (Result<any RunningApplicationInstance, Error>) -> Void
    ) {
        lock.withLock {
            self.completion = completion
        }
    }

    func complete(_ result: Result<any RunningApplicationInstance, Error>) {
        let callback = lock.withLock {
            let callback = completion
            completion = nil
            return callback
        }
        callback?(result)
    }
}

private final class FakeRunningApplication: RunningApplicationInstance, @unchecked Sendable {
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

private final class FakeTerminationObserver: RunningApplicationTerminationObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let processState: TestWorkspaceProcessState
    private var handlers: [ObjectIdentifier: @Sendable () -> Void] = [:]
    var terminateDuringObservation = false
    private(set) var lastObservation: FakeTerminationObservation?

    init(processState: TestWorkspaceProcessState) {
        self.processState = processState
    }

    func observeTermination(
        of application: any RunningApplicationInstance,
        handler: @escaping @Sendable () -> Void
    ) -> any RunningApplicationTerminationObservation {
        let observation = FakeTerminationObservation()
        lock.withLock {
            handlers[ObjectIdentifier(application)] = handler
            lastObservation = observation
        }
        if terminateDuringObservation {
            processState.markExited(
                processIdentifier: application.processIdentifier
            )
            handler()
        }
        return observation
    }

    func terminate(_ application: FakeRunningApplication) {
        application.markTerminated()
        processState.markExited(
            processIdentifier: application.processIdentifier
        )
        let handler = lock.withLock {
            handlers[ObjectIdentifier(application)]
        }
        handler?()
    }
}

private final class FakeTerminationObservation: RunningApplicationTerminationObservation, @unchecked Sendable {
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

private enum TestLaunchError: LocalizedError {
    case openFailed

    var errorDescription: String? {
        "open failed"
    }
}

private final class FakeProcessIdentityInspector:
    ProcessIdentityInspecting,
    @unchecked Sendable
{
    let ownerIdentity = ProcessStartIdentity(
        processIdentifier: Darwin.getpid(),
        startTimeSeconds: 100,
        startTimeMicroseconds: 9
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

    func setDead(processIdentifier: pid_t) {
        lock.withLock {
            inspections[processIdentifier] = .dead
        }
    }
}
