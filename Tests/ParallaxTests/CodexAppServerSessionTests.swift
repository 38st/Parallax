import Darwin
import Foundation
import XCTest
@testable import Parallax

final class CodexAppServerSessionTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "Parallax-CodexAppServerSession-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testCollectorReassemblesFragmentedLinesAndCorrelatesLogin() throws {
        let collector = JSONLineResponseCollector()
        collector.append(Data("{\"id\":7,\"result\":{\"ok\"".utf8))
        XCTAssertNil(collector.response(id: 7))

        collector.append(Data("""
        :true}}
        {"method":"account/login/completed","params":{"loginId":"login-1","success":true}}

        """.utf8))

        let response = try XCTUnwrap(collector.response(id: 7))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(
            collector.loginCompletion(loginID: "login-1")?["success"] as? Bool,
            true
        )
    }

    func testCollectorRejectsBooleanFractionalAndOutOfRangeIDs() {
        let collector = JSONLineResponseCollector()
        collector.append(Data("""
        {"id":true,"result":"boolean"}
        {"id":1.5,"result":"fractional"}
        {"id":1e100,"result":"huge"}
        {"id":1,"result":"valid"}

        """.utf8))

        XCTAssertEqual(collector.response(id: 1)?["result"] as? String, "valid")
        XCTAssertNil(collector.response(id: 0))
        XCTAssertNil(collector.response(id: Int.max))
    }

    func testSessionInitializesOnceUsesScopedHomeAndReapsOnClose() async throws {
        let home = directory("codex-home")
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        let transcript = home.appendingPathComponent("transcript")
        let trusted = try trustedExecutable(
            named: "fake-codex",
            contents: """
            #!/bin/sh
            while IFS= read -r line; do
              printf '%s\\n' "$line" >> "$CODEX_HOME/transcript"
              case "$line" in
                *'"id":7'*) printf '{"id":7,"result":{"ok":true}}\\n' ;;
              esac
            done
            """
        )
        let processRecorder = SessionProcessIDRecorder()
        let session = CodexAppServerSession(
            executable: trusted,
            codexHome: home,
            startedHandler: { processRecorder.record($0) }
        )

        try session.start()
        defer { session.close() }
        try session.sendInitialization()
        try session.send(["method": "fixture/read", "id": 7])
        let receivedResponse = try await session.waitForResponse(
            id: 7,
            timeout: 1,
            pollInterval: .milliseconds(5)
        )
        XCTAssertTrue(receivedResponse)
        XCTAssertEqual(
            (session.response(id: 7)?["result"] as? [String: Any])?["ok"]
                as? Bool,
            true
        )

        session.close()
        session.close()

        let lines = try String(contentsOf: transcript, encoding: .utf8)
            .split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        let methods = try lines.map { line in
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(line.utf8))
                    as? [String: Any]
            )
            return try XCTUnwrap(object["method"] as? String)
        }
        XCTAssertEqual(
            methods,
            ["initialize", "initialized", "fixture/read"]
        )
        try assertProcessIsGone(pid: try XCTUnwrap(processRecorder.pid))
    }

    func testWaitReturnsPromptlyWhenAppServerExitsAndCloseReaps() async throws {
        let trusted = try trustedExecutable(
            named: "exiting-codex",
            contents: "#!/bin/sh\nexit 0\n"
        )
        let processRecorder = SessionProcessIDRecorder()
        let session = CodexAppServerSession(
            executable: trusted,
            codexHome: temporaryDirectory,
            startedHandler: { processRecorder.record($0) }
        )
        let startedAt = ProcessInfo.processInfo.systemUptime

        try session.start()
        defer { session.close() }
        let received = try await session.waitForResponse(
            id: 1,
            timeout: 2,
            pollInterval: .milliseconds(5)
        )
        session.close()

        XCTAssertFalse(received)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 1)
        try assertProcessIsGone(pid: try XCTUnwrap(processRecorder.pid))
    }

    func testTimeoutThenCloseKillsAndReapsUncooperativeAppServer() async throws {
        let trusted = try uncooperativeExecutable(named: "timeout-codex")
        let processRecorder = SessionProcessIDRecorder()
        let session = CodexAppServerSession(
            executable: trusted,
            codexHome: temporaryDirectory,
            startedHandler: { processRecorder.record($0) }
        )

        try session.start()
        defer { session.close() }
        let received = try await session.waitForResponse(
            id: 1,
            timeout: 0.05,
            pollInterval: .milliseconds(5)
        )
        session.close()

        XCTAssertFalse(received)
        try assertProcessIsGone(pid: try XCTUnwrap(processRecorder.pid))
    }

    func testCancellationClosesAndReapsAppServerBeforeTaskReturns() async throws {
        let trusted = try uncooperativeExecutable(named: "cancel-codex")
        let processRecorder = SessionProcessIDRecorder()
        let session = CodexAppServerSession(
            executable: trusted,
            codexHome: temporaryDirectory,
            startedHandler: { processRecorder.record($0) }
        )
        try session.start()
        let pid = try XCTUnwrap(processRecorder.pid)

        let waiter = Task {
            defer { session.close() }
            return try await session.waitForResponse(
                id: 1,
                timeout: 5,
                pollInterval: .milliseconds(5)
            )
        }
        try await Task.sleep(for: .milliseconds(30))
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        try assertProcessIsGone(pid: pid)
    }

    private func directory(_ name: String) -> URL {
        temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    }

    private func trustedExecutable(
        named name: String,
        contents: String
    ) throws -> TrustedProviderExecutable {
        let executableDirectory = directory("executables-\(name)")
        try FileManager.default.createDirectory(
            at: executableDirectory,
            withIntermediateDirectories: true
        )
        let executable = executableDirectory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: executable.path
        )
        return try ProviderExecutableLocator(
            currentUserID: getuid(),
            fixedDirectories: [executableDirectory]
        ).locate(named: name)
    }

    private func uncooperativeExecutable(
        named name: String
    ) throws -> TrustedProviderExecutable {
        try trustedExecutable(
            named: name,
            contents: """
            #!/bin/sh
            trap '' TERM
            while :; do :; done
            """
        )
    }

    private func assertProcessIsGone(pid: pid_t) throws {
        errno = 0
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}

private final class SessionProcessIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedPID: pid_t?

    func record(_ pid: pid_t) {
        lock.withLock { recordedPID = pid }
    }

    var pid: pid_t? {
        lock.withLock { recordedPID }
    }
}
