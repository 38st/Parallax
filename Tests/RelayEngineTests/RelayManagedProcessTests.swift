import Darwin
import Foundation
import XCTest
@testable import RelayEngine

final class RelayManagedProcessTests: XCTestCase {
    func testManagedProcessStreamsOutputAndReapsExactProcess() async throws {
        let process = try RelayManagedProcess.launch(
            executable: RelayExecutableIdentity(
                inspecting: URL(fileURLWithPath: "/bin/cat")
            ),
            arguments: [],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: try RelayMinimalEnvironment()
        )
        let outputTask = Task {
            var bytes = Data()
            for await chunk in process.standardOutput { bytes.append(chunk) }
            return bytes
        }

        try process.writeStandardInput(Data("hello relay\n".utf8))
        process.closeStandardInput()
        let termination = await process.waitUntilExit()
        let output = await outputTask.value

        XCTAssertEqual(termination, .exited(code: 0))
        XCTAssertEqual(String(decoding: output, as: UTF8.self), "hello relay\n")
        XCTAssertGreaterThan(process.processIdentity.processIdentifier, 0)
        XCTAssertEqual(
            process.sandboxCapabilities,
            .unsafeHostProcess,
            "A managed host process must not claim OS isolation."
        )
    }

    func testTerminateAndReapWaitsForTerminalState() async throws {
        let process = try RelayManagedProcess.launch(
            executable: RelayExecutableIdentity(
                inspecting: URL(fileURLWithPath: "/bin/sleep")
            ),
            arguments: ["30"],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: try RelayMinimalEnvironment()
        )

        let outcome = await process.terminateAndReap(
            interruptGrace: .seconds(1),
            terminateGrace: .seconds(1),
            killGrace: .seconds(5)
        )

        guard case .reaped(let reapedTermination) = outcome else {
            return XCTFail("Expected bounded termination and reaping, got \(outcome)")
        }
        let completed = await process.waitUntilExit(upTo: .seconds(10))
        XCTAssertEqual(completed, reapedTermination)
    }

    func testConcurrentTerminationRequestsShareOneReapingSequence() async throws {
        let process = try RelayManagedProcess.launch(
            executable: RelayExecutableIdentity(
                inspecting: URL(fileURLWithPath: "/bin/sleep")
            ),
            arguments: ["30"],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: try RelayMinimalEnvironment()
        )

        let outcomes = await withTaskGroup(
            of: RelayManagedProcessControlOutcome.self,
            returning: [RelayManagedProcessControlOutcome].self
        ) { group in
            for _ in 0..<8 {
                group.addTask {
                    await process.terminateAndReap(
                        interruptGrace: .seconds(1),
                        terminateGrace: .seconds(1),
                        killGrace: .seconds(5)
                    )
                }
            }
            var results: [RelayManagedProcessControlOutcome] = []
            for await result in group { results.append(result) }
            return results
        }

        XCTAssertEqual(outcomes.count, 8)
        for outcome in outcomes {
            guard case .reaped = outcome else {
                return XCTFail("Concurrent control did not reap: \(outcome)")
            }
        }
    }

    func testUnconsumedOutputIsBoundedAndFailsClosed() async throws {
        let process = try RelayManagedProcess.launch(
            executable: RelayExecutableIdentity(
                inspecting: URL(fileURLWithPath: "/usr/bin/yes")
            ),
            arguments: ["0123456789abcdef0123456789abcdef"],
            workingDirectory: FileManager.default.temporaryDirectory,
            environment: try RelayMinimalEnvironment(),
            maximumBufferedStreamChunks: 1
        )

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.streamFailure == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(
            process.streamFailure,
            .bufferLimitExceeded(.standardOutput)
        )
        let outcome = await process.terminateAndReap(
            interruptGrace: .seconds(1),
            terminateGrace: .seconds(1),
            killGrace: .seconds(5)
        )
        guard case .reaped = outcome else {
            return XCTFail(
                "Overflowed process was not reaped: \(outcome)"
            )
        }
    }

    func testExactSignalerRejectsPIDReuseWithoutSendingSignal() {
        let expected = RelayProcessStartIdentity(
            processIdentifier: getpid(),
            startTimeSeconds: 1,
            startTimeMicroseconds: 2
        )
        let rebound = RelayProcessStartIdentity(
            processIdentifier: getpid(),
            startTimeSeconds: 3,
            startTimeMicroseconds: 4
        )
        let signaler = RelayExactProcessSignaler(
            inspector: FixedProcessInspector(result: .live(rebound))
        )

        XCTAssertEqual(
            signaler.send(SIGTERM, to: expected),
            .identityChanged
        )
    }

    func testExactSignalerFailsClosedOnAmbiguousInspection() {
        let expected = RelayProcessStartIdentity(
            processIdentifier: getpid(),
            startTimeSeconds: 1,
            startTimeMicroseconds: 2
        )
        let signaler = RelayExactProcessSignaler(
            inspector: FixedProcessInspector(result: .ambiguous)
        )

        XCTAssertEqual(
            signaler.send(SIGINT, to: expected),
            .identityUnavailable
        )
    }
}

private struct FixedProcessInspector: RelayProcessIdentityInspecting {
    let result: RelayProcessIdentityInspection

    func inspect(processIdentifier: pid_t) -> RelayProcessIdentityInspection {
        result
    }
}
