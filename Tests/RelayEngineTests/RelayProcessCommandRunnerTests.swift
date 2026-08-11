import Darwin
import Foundation
import RelayCore
import XCTest
@testable import RelayEngine

final class RelayProcessCommandRunnerTests: XCTestCase {
    func testUnsafeHostLauncherIsBlockedBeforeLaunch() async throws {
        let fixture = try RunnerFixture(executablePath: "/bin/sleep")
        let authorization = try fixture.authorize()
        let runner = RelayAuthorizedCommandRunner(
            launcher: RelayUnsafeHostCommandLauncher()
        )

        let evidence = await runner.run(
            authorization: authorization,
            arguments: ["30"],
            workingDirectory: fixture.root,
            environment: try RelayMinimalEnvironment()
        )

        guard case .launchRejected(.sandboxUnsupported(let blockers)) =
            evidence.termination
        else {
            return XCTFail("Unsafe host launch must be rejected.")
        }
        XCTAssertEqual(blockers.count, 4)
        XCTAssertNil(evidence.processIdentity)
    }

    func testRunnerCapturesBoundsDigestsAndRedactsBothStreams() async throws {
        let fixture = try RunnerFixture(
            executablePath: "/bin/sh",
            outputLimit: 64
        )
        let runner = RelayAuthorizedCommandRunner(
            launcher: ProvenTestLauncher(),
            redactor: RelayEvidenceRedactor(
                sensitiveLiterals: ["relay-secret"]
            )
        )

        let evidence = await runner.run(
            authorization: try fixture.authorize(),
            arguments: [
                "-c",
                "printf 'relay-secret and more'; printf 'relay-secret err' >&2; sleep 0.1",
            ],
            workingDirectory: fixture.root,
            environment: try RelayMinimalEnvironment()
        )

        XCTAssertEqual(evidence.termination, .exited(code: 0))
        XCTAssertFalse(evidence.standardOutput.text.contains("relay-secret"))
        XCTAssertFalse(evidence.standardError.text.contains("relay-secret"))
        XCTAssertEqual(evidence.standardOutput.redactionCount, 1)
        XCTAssertEqual(evidence.standardError.redactionCount, 1)
        XCTAssertEqual(evidence.standardOutput.totalByteCount, 21)
        XCTAssertNotNil(evidence.processIdentity)
        XCTAssertEqual(evidence.commandDigest.count, 64)
    }

    func testRunnerTimesOutAndReapsBeforeReturning() async throws {
        let fixture = try RunnerFixture(
            executablePath: "/bin/sleep",
            wallTime: .milliseconds(100)
        )
        let runner = RelayAuthorizedCommandRunner(
            launcher: ProvenTestLauncher()
        )
        let started = ContinuousClock.now

        let evidence = await runner.run(
            authorization: try fixture.authorize(),
            arguments: ["30"],
            workingDirectory: fixture.root,
            environment: try RelayMinimalEnvironment()
        )

        XCTAssertEqual(evidence.termination, .timedOut)
        XCTAssertLessThan(started.duration(to: .now), .seconds(4))
        XCTAssertNotNil(evidence.processIdentity)
    }

    func testRevokingInFlightCapabilityCancelsAndReaps() async throws {
        let fixture = try RunnerFixture(
            executablePath: "/bin/sleep",
            wallTime: .seconds(30)
        )
        let authorization = try fixture.authorize()
        let runner = RelayAuthorizedCommandRunner(
            launcher: ProvenTestLauncher()
        )
        let task = Task {
            await runner.run(
                authorization: authorization,
                arguments: ["30"],
                workingDirectory: fixture.root,
                environment: try RelayMinimalEnvironment()
            )
        }
        try await Task.sleep(for: .milliseconds(100))

        fixture.issuer.revoke(fixture.handle)
        let evidence = try await task.value

        XCTAssertEqual(evidence.termination, .cancelled)
        XCTAssertNotNil(evidence.processIdentity)
    }

    func testWorkspaceRootReplacementBlocksExecution() async throws {
        let fixture = try RunnerFixture(executablePath: "/bin/sleep")
        let authorization = try fixture.authorize()
        try FileManager.default.moveItem(
            at: fixture.root,
            to: fixture.root.appendingPathExtension("replaced")
        )
        try FileManager.default.createDirectory(
            at: fixture.root,
            withIntermediateDirectories: true
        )
        let runner = RelayAuthorizedCommandRunner(
            launcher: ProvenTestLauncher()
        )

        let evidence = await runner.run(
            authorization: authorization,
            arguments: ["1"],
            workingDirectory: fixture.root,
            environment: try RelayMinimalEnvironment()
        )

        XCTAssertEqual(
            evidence.termination,
            .launchRejected(.invalidWorkingDirectory)
        )
        XCTAssertNil(evidence.processIdentity)
    }
}

private struct ProvenTestLauncher: RelayCommandProcessLaunching {
    let capabilityReport = RelaySandboxCapabilityReport(
        backendIdentifier: "proven-test-only",
        filesystemBoundary: .proven(mechanism: "test fixture"),
        networkDeny: .proven(mechanism: "test fixture"),
        processContainment: .proven(mechanism: "test fixture"),
        executableIdentityPinning: .proven(mechanism: "test fixture")
    )

    func launch(
        executable: RelayExecutableIdentity,
        arguments: [String],
        workingDirectory: URL,
        environment: RelayMinimalEnvironment,
        onStandardOutput: @escaping @Sendable (Data) -> Void,
        onStandardError: @escaping @Sendable (Data) -> Void
    ) throws -> RelayManagedProcess {
        try RelayManagedProcess.launch(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            onStandardOutput: onStandardOutput,
            onStandardError: onStandardError,
            publishesOutputStreams: false
        )
    }
}

private final class RunnerFixture {
    let taskID = RelayTaskID()
    let stageID = RelayStageID()
    let attemptID = RelayAttemptID()
    let root: URL
    let executable: RelayExecutableIdentity
    let issuer = RelayStageCapabilityIssuer()
    let handle: RelayStageCapabilityHandle
    private let policy: RelayStageCapabilityPolicy

    init(
        executablePath: String,
        wallTime: Duration = .seconds(2),
        outputLimit: Int = 1_024
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "relay-runner-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        let git = root.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(
            at: git,
            withIntermediateDirectories: true
        )
        var rootStatus = stat()
        var gitStatus = stat()
        guard lstat(root.path, &rootStatus) == 0,
              lstat(git.path, &gitStatus) == 0
        else {
            throw CocoaError(.fileReadUnknown)
        }
        let oid = RelayGitOID(rawValue: String(repeating: "c", count: 40))!
        let digest = RelayDigest(rawValue: String(repeating: "d", count: 64))!
        let workspace = RelayWorkspaceIdentity(
            taskID: taskID,
            repositoryRootPath: root.path,
            gitCommonDirectoryPath: git.path,
            repositoryFileIdentity: RelayFileIdentity(
                deviceID: UInt64(rootStatus.st_dev),
                fileID: UInt64(rootStatus.st_ino)
            ),
            gitCommonDirectoryFileIdentity: RelayFileIdentity(
                deviceID: UInt64(gitStatus.st_dev),
                fileID: UInt64(gitStatus.st_ino)
            ),
            baseCommit: oid,
            headCommit: oid,
            workspaceDigest: digest,
            taskReference: "refs/relay/test",
            isClean: true,
            preparedAt: RelayInstant(rawValue: 0)
        )
        executable = try RelayExecutableIdentity(
            inspecting: URL(fileURLWithPath: executablePath)
        )
        policy = try RelayStageCapabilityPolicy(
            taskID: taskID,
            stageID: stageID,
            attemptID: attemptID,
            workspaceIdentity: workspace,
            workspaceDigest: digest,
            authority: RelayAuthority(
                fileSystem: .workspaceWrite,
                execution: .test,
                network: .none,
                git: .read,
                credentials: .none
            ),
            allowedExecutables: [executable],
            commandBudget: RelayCommandBudget(
                wallTime: wallTime,
                interruptGrace: .milliseconds(250),
                terminateGrace: .milliseconds(250),
                maximumStandardOutputBytes: outputLimit,
                maximumStandardErrorBytes: outputLimit
            )
        )
        handle = issuer.issue(policy)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: root.appendingPathExtension("replaced"))
    }

    func authorize() throws -> RelayStageExecutionAuthorization {
        let report = ProvenTestLauncher().capabilityReport
        guard case .authorized(let sandbox) =
            RelaySandboxValidator().validate(report)
        else {
            throw CocoaError(.featureUnsupported)
        }
        let context = RelayStageExecutionContext(
            taskID: taskID,
            stageID: stageID,
            attemptID: attemptID,
            workspaceIdentity: policy.workspaceIdentity,
            workspaceDigest: policy.workspaceDigest,
            executable: executable
        )
        guard case .success(let authorization) = issuer.authorizeExecution(
            handle: handle,
            context: context,
            sandbox: sandbox,
            now: RelayInstant(rawValue: 1)
        ) else {
            throw CocoaError(.userCancelled)
        }
        return authorization
    }
}
