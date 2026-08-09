import Foundation
import XCTest
@testable import Parallax

final class ApplicationInstanceControllerTests: XCTestCase {
    private let appPath = "/Applications/ChatGPT.app"
    private let bundleID = "com.openai.chatgpt"

    @MainActor
    func testDiscoveryRequiresCanonicalPathAndMatchingNonemptyBundleID() {
        let profile = LaunchProfile(name: "Work")
        let application = makeApplication(profile: profile)
        let exact = process(501, seconds: 100, microseconds: 4)
        let wrongPath = process(502, seconds: 101)
        let wrongID = process(503, seconds: 102)
        let missingID = process(504, seconds: 103)
        let provider = FakeProcessProvider(processes: [
            workspace(exact, path: appPath + "/../ChatGPT.app", id: bundleID),
            workspace(wrongPath, path: "/Applications/Other.app", id: bundleID),
            workspace(wrongID, path: appPath, id: "example.other"),
            workspace(missingID, path: appPath, id: nil),
        ])
        let controller = ApplicationInstanceController(processProvider: provider)
        let tracked = running(exact, application: application, profile: profile)

        let instances = controller.instances(
            for: application,
            trackedProcesses: [tracked]
        )

        XCTAssertEqual(instances.map(\.process), [exact])
        XCTAssertEqual(instances.first?.requestID, tracked.requestID)
        XCTAssertTrue(instances.first?.hasTrackedAttribution == true)
        XCTAssertEqual(
            instances.first?.controlPresentation,
            .verificationUnavailable
        )
        XCTAssertFalse(instances.first?.isActionable == true)
    }

    @MainActor
    func testStaleStorageAttributionRemainsInformationalAndNonactionable() {
        let profile = LaunchProfile(name: "Work")
        let application = makeApplication(profile: profile)
        let identity = process(510, seconds: 100)
        let provider = FakeProcessProvider(processes: [workspace(identity)])
        let controller = ApplicationInstanceController(processProvider: provider)
        let stale = ProfileRunningProcess(
            requestID: UUID(),
            identity: ProfileActivityIdentity(
                applicationID: application.id,
                applicationStorageID: UUID(),
                profileID: profile.id,
                profileStorageID: profile.storageID
            ),
            process: identity
        )

        let instance = controller.instances(
            for: application,
            trackedProcesses: [stale]
        )[0]

        XCTAssertNil(instance.requestID)
        XCTAssertNil(instance.profileID)
        XCTAssertEqual(instance.controlPresentation, .outsideParallax)
        XCTAssertFalse(instance.isActionable)
        XCTAssertThrowsError(try controller.requestQuit(instance, from: application)) {
            XCTAssertUnmanaged($0, pid: 510)
        }
        XCTAssertTrue(provider.terminationRequests.isEmpty)
    }

    @MainActor
    func testDuplicateAttributionFailsClosed() {
        let profile = LaunchProfile(name: "Work")
        let application = makeApplication(profile: profile)
        let identity = process(511, seconds: 100)
        let provider = FakeProcessProvider(processes: [workspace(identity)])
        let controller = ApplicationInstanceController(processProvider: provider)
        let first = running(identity, application: application, profile: profile)
        let second = running(identity, application: application, profile: profile)

        let instance = controller.instances(
            for: application,
            trackedProcesses: [first, second]
        )[0]

        XCTAssertFalse(instance.isActionable)
        XCTAssertNil(instance.requestID)
    }

    @MainActor
    func testConflictingRuntimeMetadataForSameProcessIsOmitted() {
        let profile = LaunchProfile(name: "Work")
        let application = makeApplication(profile: profile)
        let identity = process(512)
        let provider = FakeProcessProvider(
            processes: [
                workspace(identity),
                workspace(
                    identity,
                    path: "/Applications/Other.app",
                    id: "example.other"
                ),
            ]
        )
        let controller = ApplicationInstanceController(
            processProvider: provider
        )

        XCTAssertTrue(
            controller.instances(
                for: application,
                trackedProcesses: [
                    running(
                        identity,
                        application: application,
                        profile: profile
                    )
                ]
            ).isEmpty
        )
    }

    @MainActor
    func testHistoricalMissingBundleIDFailsClosedAndRequiresRelink() {
        let application = ManagedApplication(
            displayName: "Legacy",
            bundleIdentifier: nil,
            appPath: appPath
        )
        let provider = FakeProcessProvider(processes: [workspace(process(520))])
        let controller = ApplicationInstanceController(processProvider: provider)

        XCTAssertTrue(
            controller.instances(for: application, trackedProcesses: []).isEmpty
        )
        XCTAssertTrue(provider.terminationRequests.isEmpty)
    }

    @MainActor
    func testOperationsPassFullIdentityAndMapProviderOutcomesTruthfully() throws {
        let profile = LaunchProfile(name: "Work")
        let application = makeApplication(profile: profile)
        let identity = process(530, seconds: 1, microseconds: 999)
        let provider = FakeProcessProvider(processes: [workspace(identity)])
        let controller = ApplicationInstanceController(processProvider: provider)
        let instance = controller.instances(
            for: application,
            trackedProcesses: [running(identity, application: application, profile: profile)]
        )[0].presenting(.verifiedParallaxInstance)

        try controller.requestActivate(instance, from: application)
        XCTAssertEqual(provider.activationRequests, [instance.processIdentity])

        provider.terminationResult = .identityChanged
        XCTAssertThrowsError(try controller.requestQuit(instance, from: application)) {
            guard case ApplicationInstanceControllerError.processIdentityChanged(530) = $0 else {
                return XCTFail("Expected identity-changed error, got \($0)")
            }
            XCTAssertFalse($0.localizedDescription.contains("did not accept"))
        }

        provider.terminationResult = .requestRejected
        XCTAssertThrowsError(try controller.requestQuit(instance, from: application)) {
            guard case ApplicationInstanceControllerError.quitRequestRejected(530) = $0 else {
                return XCTFail("Expected request-rejected error, got \($0)")
            }
            XCTAssertTrue($0.localizedDescription.contains("did not accept"))
        }
    }

    @MainActor
    func testProviderNonrequestOutcomesNeverUseRejectionCopy() {
        let profile = LaunchProfile(name: "Work")
        let application = makeApplication(profile: profile)
        let identity = process(531)
        let provider = FakeProcessProvider(processes: [workspace(identity)])
        let controller = ApplicationInstanceController(
            processProvider: provider
        )
        let instance = controller.instances(
            for: application,
            trackedProcesses: [
                running(
                    identity,
                    application: application,
                    profile: profile
                )
            ]
        )[0].presenting(.verifiedParallaxInstance)

        for result in [
            WorkspaceProcessOperationResult.noLongerRunning,
            .identityChanged,
            .applicationChanged,
            .verificationUnavailable,
        ] {
            provider.activationResult = result
            XCTAssertThrowsError(
                try controller.requestActivate(
                    instance,
                    from: application
                )
            ) { error in
                XCTAssertFalse(
                    error.localizedDescription.contains(
                        "did not accept"
                    ),
                    "\(result)"
                )
            }
        }
    }

    @MainActor
    func testProductionProviderRejectsPIDMicrosecondReuseBeforeQuit() {
        let expected = process(540, seconds: 10, microseconds: 1)
        let reused = process(540, seconds: 10, microseconds: 2)
        let inspector = SequenceProcessInspector([
            .live(expected), .live(expected), .live(reused),
        ])
        let handle = FakeOperationHandle(pid: 540, path: appPath, id: bundleID)
        let runtime = SequenceProcessRuntime([[handle]])
        let provider = NSWorkspaceApplicationProcessProvider(
            processInspector: inspector,
            runtime: runtime
        )

        XCTAssertEqual(provider.requestTermination(of: fullIdentity(expected)), .identityChanged)
        XCTAssertEqual(handle.terminationCount, 0)
    }

    @MainActor
    func testProductionDiscoveryRejectsConflictingRawMetadataForSamePID() {
        let expected = process(543)
        let inspector = RepeatingProcessInspector(.live(expected))
        let expectedHandle = FakeOperationHandle(
            pid: 543,
            path: appPath,
            id: bundleID
        )
        let conflictingHandle = FakeOperationHandle(
            pid: 543,
            path: "/Applications/Other.app",
            id: "example.other"
        )
        let runtime = SequenceProcessRuntime([
            [expectedHandle, conflictingHandle]
        ])
        let provider = NSWorkspaceApplicationProcessProvider(
            processInspector: inspector,
            runtime: runtime
        )

        XCTAssertTrue(provider.runningProcesses().isEmpty)
    }

    @MainActor
    func testProductionProviderRejectsPathOrIDSwapImmediatelyBeforeQuit() {
        for (path, id) in [
            ("/Applications/Other.app", bundleID),
            (appPath, "evil.swap"),
        ] {
            let expected = process(541)
            let inspector = RepeatingProcessInspector(.live(expected))
            let good = FakeOperationHandle(
                pid: 541,
                path: appPath,
                id: bundleID
            )
            let swapped = FakeOperationHandle(
                pid: 541,
                path: path,
                id: id
            )
            let runtime = SequenceProcessRuntime([[good], [swapped]])
            let provider = NSWorkspaceApplicationProcessProvider(
                processInspector: inspector,
                runtime: runtime
            )

            XCTAssertEqual(
                provider.requestTermination(
                    of: fullIdentity(expected)
                ),
                .applicationChanged
            )
            XCTAssertEqual(
                good.terminationCount + swapped.terminationCount,
                0
            )
        }
    }

    @MainActor
    func testProductionProviderRejectsAmbiguousPIDEnumeration() {
        let expected = process(542)
        let inspector = RepeatingProcessInspector(.live(expected))
        let first = FakeOperationHandle(pid: 542, path: appPath, id: bundleID)
        let second = FakeOperationHandle(pid: 542, path: appPath, id: bundleID)
        let runtime = SequenceProcessRuntime([[first, second]])
        let provider = NSWorkspaceApplicationProcessProvider(
            processInspector: inspector,
            runtime: runtime
        )

        XCTAssertEqual(
            provider.requestTermination(of: fullIdentity(expected)),
            .verificationUnavailable
        )
        XCTAssertEqual(first.terminationCount + second.terminationCount, 0)
    }

    @MainActor
    func testActivationRevalidatesAtEveryBoundaryAndNeverFallsBackAfterSwap() {
        for changedBoundary in 0..<4 {
            let expected = process(pid_t(550 + changedBoundary))
            let inspector = RepeatingProcessInspector(.live(expected))
            var handles: [FakeOperationHandle] = []
            var enumerations: [[any WorkspaceApplicationOperationHandle]] = []
            for boundary in 0..<4 {
                let handle = FakeOperationHandle(
                    pid: expected.processIdentifier,
                    path: appPath,
                    id: boundary == changedBoundary ? "evil.swap" : bundleID,
                    coordinatedResult: false
                )
                handles.append(handle)
                enumerations.append([handle])
            }
            let runtime = SequenceProcessRuntime(enumerations)
            let provider = NSWorkspaceApplicationProcessProvider(
                processInspector: inspector,
                runtime: runtime
            )

            XCTAssertEqual(
                provider.requestActivation(of: fullIdentity(expected)),
                .applicationChanged,
                "boundary \(changedBoundary)"
            )
            XCTAssertEqual(
                handles.reduce(0) { $0 + $1.fallbackCount },
                0,
                "boundary \(changedBoundary)"
            )
        }
    }

    @MainActor
    func testActivationFallbackRunsOnlyAfterFourExactRevalidations() {
        let expected = process(560)
        let inspector = RepeatingProcessInspector(.live(expected))
        let handles = (0..<4).map { _ in
            FakeOperationHandle(
                pid: 560,
                path: appPath,
                id: bundleID,
                coordinatedResult: false
            )
        }
        let runtime = SequenceProcessRuntime(handles.map { [$0] })
        let provider = NSWorkspaceApplicationProcessProvider(
            processInspector: inspector,
            runtime: runtime
        )

        XCTAssertEqual(provider.requestActivation(of: fullIdentity(expected)), .accepted)
        XCTAssertEqual(runtime.yieldCount, 1)
        XCTAssertEqual(handles[1].coordinatedCount, 1)
        XCTAssertEqual(handles[3].fallbackCount, 1)
        XCTAssertEqual(handles.reduce(0) { $0 + $1.fallbackCount }, 1)
    }

    private func makeApplication(profile: LaunchProfile) -> ManagedApplication {
        ManagedApplication(
            displayName: "ChatGPT",
            bundleIdentifier: bundleID,
            appPath: appPath,
            profiles: [profile]
        )
    }

    private func process(
        _ pid: pid_t,
        seconds: UInt64 = 100,
        microseconds: UInt64 = 0
    ) -> ProcessStartIdentity {
        ProcessStartIdentity(
            processIdentifier: pid,
            startTimeSeconds: seconds,
            startTimeMicroseconds: microseconds
        )
    }

    private func workspace(
        _ process: ProcessStartIdentity,
        path: String? = nil,
        id: String? = "com.openai.chatgpt"
    ) -> WorkspaceApplicationProcess {
        WorkspaceApplicationProcess(
            process: process,
            bundleURL: URL(fileURLWithPath: path ?? appPath),
            bundleIdentifier: id
        )
    }

    private func fullIdentity(_ process: ProcessStartIdentity) -> WorkspaceProcessIdentity {
        WorkspaceProcessIdentity(
            process: process,
            application: WorkspaceApplicationBundleIdentity(
                bundleURL: URL(fileURLWithPath: appPath),
                bundleIdentifier: bundleID
            )
        )
    }

    private func running(
        _ process: ProcessStartIdentity,
        application: ManagedApplication,
        profile: LaunchProfile
    ) -> ProfileRunningProcess {
        ProfileRunningProcess(
            requestID: UUID(),
            identity: ProfileActivityIdentity(
                applicationID: application.id,
                applicationStorageID: application.storageID,
                profileID: profile.id,
                profileStorageID: profile.storageID
            ),
            process: process
        )
    }
}

private func XCTAssertUnmanaged(
    _ error: Error,
    pid: pid_t,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    guard case ApplicationInstanceControllerError.unmanagedInstance(let actualPID) = error else {
        return XCTFail("Expected unmanaged instance, got \(error)", file: file, line: line)
    }
    XCTAssertEqual(actualPID, pid, file: file, line: line)
}

@MainActor
private final class FakeProcessProvider: WorkspaceApplicationProcessProviding {
    var processes: [WorkspaceApplicationProcess]
    var terminationResult: WorkspaceProcessOperationResult = .accepted
    var activationResult: WorkspaceProcessOperationResult = .accepted
    private(set) var terminationRequests: [WorkspaceProcessIdentity] = []
    private(set) var activationRequests: [WorkspaceProcessIdentity] = []

    init(processes: [WorkspaceApplicationProcess]) {
        self.processes = processes
    }

    func runningProcesses() -> [WorkspaceApplicationProcess] { processes }

    func requestTermination(
        of identity: WorkspaceProcessIdentity
    ) -> WorkspaceProcessOperationResult {
        terminationRequests.append(identity)
        return terminationResult
    }

    func requestActivation(
        of identity: WorkspaceProcessIdentity
    ) -> WorkspaceProcessOperationResult {
        activationRequests.append(identity)
        return activationResult
    }
}

private final class RepeatingProcessInspector: ProcessIdentityInspecting, @unchecked Sendable {
    private let result: ProcessIdentityInspection

    init(_ result: ProcessIdentityInspection) { self.result = result }

    func inspect(processIdentifier: pid_t) -> ProcessIdentityInspection { result }
}

private final class SequenceProcessInspector: ProcessIdentityInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [ProcessIdentityInspection]

    init(_ results: [ProcessIdentityInspection]) { self.results = results }

    func inspect(processIdentifier: pid_t) -> ProcessIdentityInspection {
        lock.withLock {
            if results.count > 1 { return results.removeFirst() }
            return results[0]
        }
    }
}

@MainActor
private final class FakeOperationHandle: WorkspaceApplicationOperationHandle {
    let processIdentifier: pid_t
    var bundleURL: URL?
    var bundleIdentifier: String?
    var isTerminated = false
    let coordinatedResult: Bool
    private(set) var terminationCount = 0
    private(set) var coordinatedCount = 0
    private(set) var fallbackCount = 0

    init(
        pid: pid_t,
        path: String,
        id: String?,
        coordinatedResult: Bool = true
    ) {
        processIdentifier = pid
        bundleURL = URL(fileURLWithPath: path)
        bundleIdentifier = id
        self.coordinatedResult = coordinatedResult
    }

    func requestTermination() -> Bool {
        terminationCount += 1
        return true
    }

    func requestCoordinatedActivation() -> Bool {
        coordinatedCount += 1
        return coordinatedResult
    }

    func requestFallbackActivation() -> Bool {
        fallbackCount += 1
        return true
    }
}

@MainActor
private final class SequenceProcessRuntime: WorkspaceApplicationProcessRuntime {
    private var enumerations: [[any WorkspaceApplicationOperationHandle]]
    private(set) var yieldCount = 0

    init(_ enumerations: [[any WorkspaceApplicationOperationHandle]]) {
        self.enumerations = enumerations
    }

    func runningApplications() -> [any WorkspaceApplicationOperationHandle] {
        if enumerations.count > 1 { return enumerations.removeFirst() }
        return enumerations[0]
    }

    func yieldActivation(to application: any WorkspaceApplicationOperationHandle) {
        yieldCount += 1
    }
}
