import Foundation
import RelayEngine
import XCTest

final class RelayCodexConnectionTests: XCTestCase {
    func testMalformedProtocolFailsSessionAndReapsOwnedProcess() async throws {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        let codexHome = fixture.root.appendingPathComponent(
            "CodexHome",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: codexHome,
            withIntermediateDirectories: false
        )
        let executable = try makeExecutable(
            in: fixture.root,
            body: "printf 'not-json\\n'\nexec /bin/sleep 30"
        )
        let connection = try RelayCodexConnection.launch(
            executable: RelayExecutableIdentity(inspecting: executable),
            codexHome: codexHome,
            context: fixture.context
        )

        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while connection.terminalFailure == nil,
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(connection.terminalFailure, .protocolViolation)
        while connection.failureControlOutcome == nil,
              ContinuousClock.now < deadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .reaped = connection.failureControlOutcome else {
            return XCTFail("Protocol-failed app-server was not automatically reaped")
        }
        let state = await connection.session.state
        XCTAssertEqual(state, .failed)
        let stopOutcome = await connection.stop()
        guard case .reaped = stopOutcome else {
            return XCTFail("Protocol-failed app-server was not reaped")
        }
    }

    func testStopTerminatesReapsAndJoinsPumps() async throws {
        let fixture = try RelayCodexTestContextFixture()
        defer { fixture.remove() }
        let codexHome = fixture.root.appendingPathComponent(
            "CodexHome",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: codexHome,
            withIntermediateDirectories: false
        )
        let executable = try makeExecutable(
            in: fixture.root,
            body: "trap 'exit 0' INT TERM\nwhile :; do sleep 1; done"
        )
        let connection = try RelayCodexConnection.launch(
            executable: RelayExecutableIdentity(inspecting: executable),
            codexHome: codexHome,
            context: fixture.context
        )

        let first = await connection.stop()
        let second = await connection.stop()

        guard case .reaped = first else {
            return XCTFail("App-server was not reaped")
        }
        XCTAssertEqual(first, second)
        XCTAssertNil(connection.terminalFailure)
        let state = await connection.session.state
        XCTAssertEqual(state, .closed)
    }

    private func makeExecutable(in directory: URL, body: String) throws -> URL {
        let url = directory.appendingPathComponent(
            "fake-codex-\(UUID().uuidString)",
            isDirectory: false
        )
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: url.path
        )
        return url
    }
}
