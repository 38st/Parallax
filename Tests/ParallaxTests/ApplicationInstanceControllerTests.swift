import Foundation
import XCTest
@testable import Parallax

final class ApplicationInstanceControllerTests: XCTestCase {
    @MainActor
    func testDiscoveryLabelsTrackedSpaceAndKeepsOutsideInstanceVisible() {
        let profile = LaunchProfile(name: "Work")
        let application = ManagedApplication(
            displayName: "ChatGPT",
            bundleIdentifier: "com.openai.codex",
            appPath: "/Applications/ChatGPT.app",
            profiles: [profile]
        )
        let trackedProcess = process(
            identifier: 501,
            startSeconds: 100
        )
        let outsideProcess = process(
            identifier: 502,
            startSeconds: 200
        )
        let provider = FakeWorkspaceApplicationProcessProvider(
            processes: [
                workspaceProcess(
                    trackedProcess,
                    path: application.appPath
                ),
                workspaceProcess(
                    outsideProcess,
                    path: application.appPath
                ),
                workspaceProcess(
                    process(identifier: 503, startSeconds: 300),
                    path: "/Applications/Other.app"
                ),
            ]
        )
        let controller = ApplicationInstanceController(
            processProvider: provider
        )
        let tracked = ProfileRunningProcess(
            requestID: UUID(),
            identity: ProfileActivityIdentity(
                applicationID: application.id,
                applicationStorageID: application.storageID,
                profileID: profile.id,
                profileStorageID: profile.storageID
            ),
            process: trackedProcess
        )

        let instances = controller.instances(
            for: application,
            trackedProcesses: [tracked]
        )

        XCTAssertEqual(instances.count, 2)
        XCTAssertEqual(instances[0].process, trackedProcess)
        XCTAssertEqual(instances[0].profileID, profile.id)
        XCTAssertEqual(instances[0].displayName, "Work")
        XCTAssertTrue(instances[0].isTrackedSpace)
        XCTAssertEqual(instances[1].process, outsideProcess)
        XCTAssertNil(instances[1].profileID)
        XCTAssertEqual(instances[1].displayName, "Other instance")
        XCTAssertFalse(instances[1].isTrackedSpace)
    }

    @MainActor
    func testQuitTargetsOnlyTheSelectedProcess() throws {
        let application = ManagedApplication(
            displayName: "ChatGPT",
            appPath: "/Applications/ChatGPT.app"
        )
        let first = process(identifier: 601, startSeconds: 100)
        let second = process(identifier: 602, startSeconds: 200)
        let provider = FakeWorkspaceApplicationProcessProvider(
            processes: [
                workspaceProcess(first, path: application.appPath),
                workspaceProcess(second, path: application.appPath),
            ]
        )
        let controller = ApplicationInstanceController(
            processProvider: provider
        )
        let instances = controller.instances(
            for: application,
            trackedProcesses: []
        )

        try controller.requestQuit(
            instances[0],
            from: application
        )

        XCTAssertEqual(provider.terminationRequests, [first])
        XCTAssertEqual(
            provider.processes.map(\.process),
            [first, second]
        )
    }

    @MainActor
    func testActivateTargetsOnlyTheSelectedProcess() throws {
        let application = ManagedApplication(
            displayName: "ChatGPT",
            appPath: "/Applications/ChatGPT.app"
        )
        let first = process(identifier: 651, startSeconds: 100)
        let second = process(identifier: 652, startSeconds: 200)
        let provider = FakeWorkspaceApplicationProcessProvider(
            processes: [
                workspaceProcess(first, path: application.appPath),
                workspaceProcess(second, path: application.appPath),
            ]
        )
        let controller = ApplicationInstanceController(
            processProvider: provider
        )
        let instances = controller.instances(
            for: application,
            trackedProcesses: []
        )

        try controller.requestActivate(
            instances[1],
            from: application
        )

        XCTAssertEqual(provider.activationRequests, [second])
        XCTAssertTrue(provider.terminationRequests.isEmpty)
    }

    @MainActor
    func testActivateReportsRejectionForOnlyTheSelectedProcess() {
        let application = ManagedApplication(
            displayName: "ChatGPT",
            appPath: "/Applications/ChatGPT.app"
        )
        let first = process(identifier: 661, startSeconds: 100)
        let second = process(identifier: 662, startSeconds: 200)
        let provider = FakeWorkspaceApplicationProcessProvider(
            processes: [
                workspaceProcess(first, path: application.appPath),
                workspaceProcess(second, path: application.appPath),
            ]
        )
        provider.acceptsActivation = false
        let controller = ApplicationInstanceController(
            processProvider: provider
        )
        let instances = controller.instances(
            for: application,
            trackedProcesses: []
        )

        XCTAssertThrowsError(
            try controller.requestActivate(
                instances[1],
                from: application
            )
        ) { error in
            guard
                case ApplicationInstanceControllerError
                    .activationRequestRejected(662) = error
            else {
                return XCTFail(
                    "Expected activation rejection for the selected process."
                )
            }
        }

        XCTAssertEqual(provider.activationRequests, [second])
        XCTAssertTrue(provider.terminationRequests.isEmpty)
    }

    @MainActor
    func testQuitRejectsPIDReuseAndAnotherApplication() {
        let application = ManagedApplication(
            displayName: "ChatGPT",
            appPath: "/Applications/ChatGPT.app"
        )
        let original = process(identifier: 701, startSeconds: 100)
        let provider = FakeWorkspaceApplicationProcessProvider(
            processes: [
                workspaceProcess(original, path: application.appPath)
            ]
        )
        let controller = ApplicationInstanceController(
            processProvider: provider
        )
        let instance = controller.instances(
            for: application,
            trackedProcesses: []
        )[0]

        provider.processes = [
            workspaceProcess(
                process(identifier: 701, startSeconds: 101),
                path: application.appPath
            )
        ]

        XCTAssertThrowsError(
            try controller.requestQuit(instance, from: application)
        ) { error in
            guard
                case ApplicationInstanceControllerError
                    .processIdentityChanged(701) = error
            else {
                return XCTFail("Expected PID reuse rejection.")
            }
        }
        XCTAssertTrue(provider.terminationRequests.isEmpty)

        provider.processes = [
            workspaceProcess(
                original,
                path: "/Applications/Other.app"
            )
        ]

        XCTAssertThrowsError(
            try controller.requestQuit(instance, from: application)
        ) { error in
            guard
                case ApplicationInstanceControllerError
                    .applicationIdentityChanged(701) = error
            else {
                return XCTFail(
                    "Expected application identity rejection."
                )
            }
        }
        XCTAssertTrue(provider.terminationRequests.isEmpty)
    }

    private func process(
        identifier: pid_t,
        startSeconds: UInt64
    ) -> ProcessStartIdentity {
        ProcessStartIdentity(
            processIdentifier: identifier,
            startTimeSeconds: startSeconds,
            startTimeMicroseconds: 0
        )
    }

    private func workspaceProcess(
        _ process: ProcessStartIdentity,
        path: String
    ) -> WorkspaceApplicationProcess {
        WorkspaceApplicationProcess(
            process: process,
            bundleURL: URL(fileURLWithPath: path),
            bundleIdentifier: nil
        )
    }
}

@MainActor
private final class FakeWorkspaceApplicationProcessProvider:
    WorkspaceApplicationProcessProviding
{
    var processes: [WorkspaceApplicationProcess]
    private(set) var terminationRequests:
        [ProcessStartIdentity] = []
    private(set) var activationRequests:
        [ProcessStartIdentity] = []
    var acceptsTermination = true
    var acceptsActivation = true

    init(processes: [WorkspaceApplicationProcess]) {
        self.processes = processes
    }

    func runningProcesses() -> [WorkspaceApplicationProcess] {
        processes
    }

    func requestTermination(
        of process: ProcessStartIdentity
    ) -> Bool {
        terminationRequests.append(process)
        return acceptsTermination
    }

    func requestActivation(
        of process: ProcessStartIdentity
    ) -> Bool {
        activationRequests.append(process)
        return acceptsActivation
    }
}
