import AppKit
import Foundation
import XCTest
@testable import Parallax

@MainActor
final class NSWorkspaceApplicationLauncherIntegrationTests: XCTestCase {
    func testFailedAndTimedOutCompilerAlwaysRemoveDisposableRoot() throws {
        let failureSuffix = "buildfailure\(compactUUID())"
        let failureRoot = fixtureRoot(suffix: failureSuffix)
        XCTAssertThrowsError(
            try ProductionLaunchApplicationFixture.build(
                mode: .created,
                compilerExecutableURL: URL(fileURLWithPath: "/usr/bin/false"),
                compilerArgumentsOverride: [],
                suffixOverride: failureSuffix
            )
        ) { error in
            guard case ProductionLaunchApplicationFixtureError.compilationFailed = error else {
                return XCTFail("Expected compiler failure, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: failureRoot.path))

        let timeoutSuffix = "buildtimeout\(compactUUID())"
        let timeoutRoot = fixtureRoot(suffix: timeoutSuffix)
        XCTAssertThrowsError(
            try ProductionLaunchApplicationFixture.build(
                mode: .created,
                compilerExecutableURL: URL(fileURLWithPath: "/bin/sleep"),
                compilerArgumentsOverride: ["30"],
                compilerTimeout: 0.05,
                suffixOverride: timeoutSuffix
            )
        ) { error in
            guard case ProductionLaunchApplicationFixtureError.compilationTimedOut = error else {
                return XCTFail("Expected compiler timeout, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: timeoutRoot.path))
    }

    func testOpenCallbackLossTimesOutWithoutLeakingContinuation() async throws {
        let fixture = try makeFixture(.created)
        do {
            _ = try await fixture.awaitOpen(timeout: .milliseconds(50)) { _ in }
            XCTFail("A missing NSWorkspace callback must time out.")
        } catch ProductionLaunchApplicationFixtureError.openTimedOut {
            // Expected fail-closed result.
        }
    }

    func testCleanupTerminatesJournaledProcessAbsentFromWorkspaceRegistration()
        async throws
    {
        let fixture = try makeFixture(.created)
        let process = try fixture.launchUnregistered(
            arguments: ["--unregistered-cleanup"],
            environmentValue: "unregistered"
        )
        try await fixture.wait(description: "unregistered process journal identity") {
            try fixture.journalEvents().contains { event in
                event.event == "launched"
                    && event.processIdentifier == process.processIdentifier
            }
        }
        let event = try XCTUnwrap(
            fixture.journalEvents().first {
                $0.event == "launched"
                    && $0.processIdentifier == process.processIdentifier
            }
        )
        let expected = ProcessStartIdentity(
            processIdentifier: event.processIdentifier,
            startTimeSeconds: event.startTimeSeconds,
            startTimeMicroseconds: event.startTimeMicroseconds
        )
        XCTAssertFalse(
            fixture.exactRunningApplications().contains {
                $0.processIdentifier == expected.processIdentifier
            }
        )

        try await fixture.cleanup()

        switch SystemProcessIdentityInspector().inspect(
            processIdentifier: expected.processIdentifier
        ) {
        case .dead:
            break
        case .live(let current):
            XCTAssertNotEqual(current, expected, "Cleanup must not leave the exact process alive.")
        case .ambiguous:
            XCTFail("Cleanup must establish dead-or-rebound process identity.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL.path))
    }

    func testRealActivationRequiredModeParserIsStrict() throws {
        XCTAssertFalse(try RealActivationTestRequirement.parse(nil))
        XCTAssertFalse(try RealActivationTestRequirement.parse("0"))
        XCTAssertTrue(try RealActivationTestRequirement.parse("1"))
        for invalid in ["", "true", "yes", " 1", "1 ", "2"] {
            XCTAssertThrowsError(try RealActivationTestRequirement.parse(invalid))
        }
    }

    func testCreatedProcessReceivesExactArgumentsEnvironmentAndIdentity() async throws {
        let fixture = try makeFixture(.created)
        let profile = LaunchProfile(name: "Created")
        let application = fixture.managedApplication(profiles: [profile])
        let arguments = ["--adapter-proof", "value with spaces", "--sentinel=✓"]
        let environmentValue = UUID().uuidString
        let prepared = fixture.preparedLaunch(
            application: application,
            profile: profile,
            arguments: arguments,
            environmentValue: environmentValue
        )
        let registry = ProfileActivityRegistry()

        let launch = try WorkspaceApplicationLauncher().launchTracked(
            prepared: prepared,
            activityRegistry: registry,
            eventHandler: { _ in }
        )
        let identity = try await waitForRunning(launch, fixture: fixture)
        try await fixture.wait(description: "created-process launch journal entry") {
            try fixture.journalEvents().contains { $0.event == "launched" }
        }
        let launched = try XCTUnwrap(
            fixture.journalEvents().first { $0.event == "launched" }
        )

        XCTAssertEqual(launched.processIdentifier, identity.processIdentifier)
        XCTAssertEqual(Array(launched.arguments.suffix(arguments.count)), arguments)
        XCTAssertEqual(launched.environmentValue, environmentValue)
        XCTAssertEqual(launched.bundleIdentifier, fixture.bundleIdentifier)
        XCTAssertEqual(canonical(URL(fileURLWithPath: launched.bundlePath)), canonical(fixture.applicationURL))
        XCTAssertEqual(identity.application.bundleIdentifier, fixture.bundleIdentifier)
        XCTAssertEqual(canonical(identity.application.bundleURL), canonical(fixture.applicationURL))
    }

    func testSelfExitingProcessReleasesRegistryWithTruthfulTerminalState() async throws {
        let fixture = try makeFixture(.selfExit)
        let profile = LaunchProfile(name: "Self exit")
        let application = fixture.managedApplication(profiles: [profile])
        let prepared = fixture.preparedLaunch(
            application: application,
            profile: profile,
            arguments: ["--self-exit-proof"],
            environmentValue: "self-exit"
        )
        let registry = ProfileActivityRegistry()
        let launch = try WorkspaceApplicationLauncher().launchTracked(
            prepared: prepared,
            activityRegistry: registry,
            eventHandler: { _ in }
        )

        try await fixture.wait(description: "self-exit terminal lifecycle") {
            launch.currentLifecycle.state.isTerminal
        }
        switch launch.currentLifecycle.state {
        case .terminated, .failed:
            break
        default:
            XCTFail("Self-exit must resolve to a truthful terminal state.")
        }
        XCTAssertFalse(registry.isActive(identity: activityIdentity(for: prepared)))
        try await fixture.wait { fixture.exactRunningApplications().isEmpty }
        XCTAssertEqual(
            try fixture.journalEvents().filter { $0.event == "launched" }.count,
            1
        )
    }

    func testPreexistingSingletonIsRefusedWithoutASecondLaunch() async throws {
        let fixture = try makeFixture(.singleton)
        let preexistingToken = "preexisting-\(UUID().uuidString)"
        let preexisting = try await fixture.openPreexisting(
            arguments: ["--token", preexistingToken],
            environmentValue: "preexisting"
        )
        try await fixture.wait(description: "preexisting singleton launch journal entry") {
            try fixture.journalEvents().filter { $0.event == "launched" }.count == 1
        }
        let profile = LaunchProfile(name: "Singleton")
        let application = fixture.managedApplication(profiles: [profile])
        let managedToken = "managed-\(UUID().uuidString)"
        let prepared = fixture.preparedLaunch(
            application: application,
            profile: profile,
            arguments: ["--token", managedToken],
            environmentValue: "managed"
        )
        let registry = ProfileActivityRegistry()
        let launch = try WorkspaceApplicationLauncher().launchTracked(
            prepared: prepared,
            activityRegistry: registry,
            eventHandler: { _ in }
        )

        try await fixture.wait { launch.currentLifecycle.state.isTerminal }
        XCTAssertEqual(
            launch.currentLifecycle.openingDisposition,
            .preExistingSingletonRefused(
                processIdentifier: preexisting.processIdentifier
            )
        )
        XCTAssertFalse(registry.isActive(identity: activityIdentity(for: prepared)))
        try await Task.sleep(for: .milliseconds(300))
        let launches = try fixture.journalEvents().filter { $0.event == "launched" }
        XCTAssertEqual(launches.count, 1)
        XCTAssertTrue(launches[0].arguments.contains(preexistingToken))
        XCTAssertFalse(launches[0].arguments.contains(managedToken))
    }

    func testWorkspaceControllerActivatesOnlyTheExactTrackedInstance() async throws {
        _ = NSApplication.shared
        let activationRequired = try RealActivationTestRequirement.parse(
            ProcessInfo.processInfo.environment[
                "PARALLAX_REQUIRE_REAL_ACTIVATION_TESTS"
            ]
        )
        guard NSRunningApplication.current.isActive else {
            let result = "currentProcessIsActive=false, activationPolicy=\(NSApplication.shared.activationPolicy().rawValue)"
            let command = "PARALLAX_REQUIRE_REAL_ACTIVATION_TESTS=1 swift test --filter NSWorkspaceApplicationLauncherIntegrationTests/testWorkspaceControllerActivatesOnlyTheExactTrackedInstance"
            if activationRequired {
                throw RealActivationTestRequirement.Error.requiredCapabilityUnavailable(
                    "\(result); required command: \(command)"
                )
            }
            throw XCTSkip(
                "Real activation not proven: \(result). Run a foreground-capable host with: \(command)"
            )
        }
        let fixture = try makeFixture(.activationCapable)
        let firstProfile = LaunchProfile(name: "Activation target")
        let secondProfile = LaunchProfile(name: "Activation sibling")
        let application = fixture.managedApplication(
            profiles: [firstProfile, secondProfile]
        )
        let firstPrepared = fixture.preparedLaunch(
            application: application,
            profile: firstProfile,
            arguments: ["--activation-instance", "target"],
            environmentValue: "target"
        )
        let secondPrepared = fixture.preparedLaunch(
            application: application,
            profile: secondProfile,
            arguments: ["--activation-instance", "sibling"],
            environmentValue: "sibling"
        )
        let registry = ProfileActivityRegistry()
        let launcher = WorkspaceApplicationLauncher()
        let firstLaunch = try launcher.launchTracked(
            prepared: firstPrepared,
            activityRegistry: registry,
            eventHandler: { _ in }
        )
        let firstIdentity = try await waitForRunning(firstLaunch, fixture: fixture)
        let secondLaunch = try launcher.launchTracked(
            prepared: secondPrepared,
            activityRegistry: registry,
            eventHandler: { _ in }
        )
        let secondIdentity = try await waitForRunning(secondLaunch, fixture: fixture)
        let tracked = [
            runningProcess(firstPrepared, process: firstIdentity.process),
            runningProcess(secondPrepared, process: secondIdentity.process),
        ]
        let controller = ApplicationInstanceController()
        try await fixture.wait(description: "activation instance discovery") {
            controller.instances(for: application, trackedProcesses: tracked).count == 2
        }
        let instances = controller.instances(for: application, trackedProcesses: tracked)
        let target = try XCTUnwrap(
            instances.first { $0.processIdentifier == firstIdentity.processIdentifier }
        ).presenting(.verifiedParallaxInstance)
        let sibling = try XCTUnwrap(
            instances.first { $0.processIdentifier == secondIdentity.processIdentifier }
        ).presenting(.verifiedParallaxInstance)
        XCTAssertTrue(
            NSRunningApplication.current.activate(options: [.activateAllWindows])
        )
        try await fixture.wait(description: "foreground host before activation handoff") {
            NSRunningApplication.current.isActive
        }
        let targetBaseline = try activationCount(
            for: target.processIdentifier,
            fixture: fixture
        )
        let siblingBaseline = try activationCount(
            for: sibling.processIdentifier,
            fixture: fixture
        )

        try controller.requestActivate(target, from: application)
        try await fixture.wait(description: "exact target activation marker") {
            try self.activationCount(for: target.processIdentifier, fixture: fixture)
                > targetBaseline
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(
            try activationCount(for: sibling.processIdentifier, fixture: fixture),
            siblingBaseline
        )
        XCTAssertTrue(
            NSRunningApplication(processIdentifier: target.processIdentifier)?.isActive == true
        )
        XCTAssertFalse(
            NSRunningApplication(processIdentifier: sibling.processIdentifier)?.isActive == true
        )
    }

    func testControllerQuitsOnlyTheExactTrackedInstanceWhileSiblingRemains() async throws {
        let fixture = try makeFixture(.cooperativeQuit)
        let firstProfile = LaunchProfile(name: "First")
        let secondProfile = LaunchProfile(name: "Second")
        let application = fixture.managedApplication(
            profiles: [firstProfile, secondProfile]
        )
        let firstPrepared = fixture.preparedLaunch(
            application: application,
            profile: firstProfile,
            arguments: ["--instance", "first"],
            environmentValue: "first"
        )
        let secondPrepared = fixture.preparedLaunch(
            application: application,
            profile: secondProfile,
            arguments: ["--instance", "second"],
            environmentValue: "second"
        )
        let registry = ProfileActivityRegistry()
        let launcher = WorkspaceApplicationLauncher()
        let firstLaunch = try launcher.launchTracked(
            prepared: firstPrepared,
            activityRegistry: registry,
            eventHandler: { _ in }
        )
        let firstIdentity = try await waitForRunning(firstLaunch, fixture: fixture)
        let secondLaunch = try launcher.launchTracked(
            prepared: secondPrepared,
            activityRegistry: registry,
            eventHandler: { _ in }
        )
        let secondIdentity = try await waitForRunning(secondLaunch, fixture: fixture)
        XCTAssertNotEqual(firstIdentity.processIdentifier, secondIdentity.processIdentifier)

        let tracked = [
            runningProcess(firstPrepared, process: firstIdentity.process),
            runningProcess(secondPrepared, process: secondIdentity.process),
        ]
        let controller = ApplicationInstanceController()
        try await fixture.wait(description: "controller discovery of both exact instances") {
            controller.instances(for: application, trackedProcesses: tracked).count == 2
        }
        let instances = controller.instances(
            for: application,
            trackedProcesses: tracked
        )
        let first = try XCTUnwrap(
            instances.first { $0.processIdentifier == firstIdentity.processIdentifier }
        ).presenting(.verifiedParallaxInstance)
        let second = try XCTUnwrap(
            instances.first { $0.processIdentifier == secondIdentity.processIdentifier }
        ).presenting(.verifiedParallaxInstance)
        try controller.requestQuit(first, from: application)
        try await fixture.wait(description: "target cooperative termination") {
            !fixture.exactRunningApplications().contains {
                $0.processIdentifier == first.processIdentifier
            }
        }
        XCTAssertTrue(
            fixture.exactRunningApplications().contains {
                $0.processIdentifier == second.processIdentifier
            }
        )
        XCTAssertTrue(
            try fixture.journalEvents().contains {
                $0.event == "quit-requested"
                    && $0.processIdentifier == first.processIdentifier
            }
        )
        XCTAssertFalse(
            try fixture.journalEvents().contains {
                $0.event == "quit-requested"
                    && $0.processIdentifier == second.processIdentifier
            }
        )
    }

    private func makeFixture(
        _ mode: ProductionLaunchApplicationFixture.Mode
    ) throws -> ProductionLaunchApplicationFixture {
        _ = NSApplication.shared
        let fixture = try ProductionLaunchApplicationFixture.build(mode: mode)
        addTeardownBlock { @MainActor in
            try await fixture.cleanup()
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.rootURL.path))
            XCTAssertTrue(fixture.exactRunningApplications().isEmpty)
        }
        return fixture
    }

    private func waitForRunning(
        _ launch: TrackedApplicationLaunch,
        fixture: ProductionLaunchApplicationFixture
    ) async throws -> WorkspaceProcessIdentity {
        do {
            try await fixture.wait(
                description: "running lifecycle for request \(launch.currentLifecycle.requestID)",
                timeout: .seconds(20)
            ) {
                switch launch.currentLifecycle.state {
                case .running, .runningDegraded, .failed:
                    true
                default:
                    false
                }
            }
        } catch {
            XCTFail(
                "Timed out in \(launch.currentLifecycle.state); journal=\((try? fixture.journalEvents()) ?? [])"
            )
            throw error
        }
        if case .failed(let message) = launch.currentLifecycle.state {
            XCTFail("Launch failed: \(message)")
        }
        return try XCTUnwrap(launch.supervisedProcessIdentity)
    }

    private func activityIdentity(for prepared: PreparedLaunch) -> ProfileActivityIdentity {
        ProfileActivityIdentity(
            applicationID: prepared.applicationID,
            applicationStorageID: prepared.applicationStorageID,
            profileID: prepared.profileID,
            profileStorageID: prepared.profileStorageID
        )
    }

    private func runningProcess(
        _ prepared: PreparedLaunch,
        process: ProcessStartIdentity
    ) -> ProfileRunningProcess {
        ProfileRunningProcess(
            requestID: prepared.requestID,
            identity: activityIdentity(for: prepared),
            process: process
        )
    }

    private func activationCount(
        for processIdentifier: pid_t,
        fixture: ProductionLaunchApplicationFixture
    ) throws -> Int {
        try fixture.journalEvents().filter {
            $0.event == "activated" && $0.processIdentifier == processIdentifier
        }.count
    }

    private func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func compactUUID() -> String {
        UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }

    private func fixtureRoot(suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "parallax-production-adapter-fixture.\(suffix)",
            isDirectory: true
        )
    }
}

private enum RealActivationTestRequirement {
    enum Error: Swift.Error, Equatable {
        case invalidValue(String)
        case requiredCapabilityUnavailable(String)
    }

    static func parse(_ value: String?) throws -> Bool {
        switch value {
        case nil, "0": false
        case "1": true
        case .some(let invalid): throw Error.invalidValue(invalid)
        }
    }
}
