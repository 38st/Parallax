import Darwin
import Foundation
import XCTest
@testable import Parallax

/// Provider transport and classification: only an explicit provider answer
/// may mean "not signed in"; everything else is status-unavailable.
final class ProviderClassificationTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ProviderClassificationTests-\(UUID().uuidString)",
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

    // MARK: - Codex account/read classification

    func testCodexAccountReadErrorIsStatusUnavailableNotSignedOut()
        async throws
    {
        let home = try makeHome("error-home")
        let trusted = try trustedExecutable(
            named: "error-codex",
            contents: appServerScript(
                accountReply: #"{"id":1,"error":{"code":-32603,"message":"token refresh failed"}}"#
            )
        )

        await assertConnectThrows(
            .statusUnavailable,
            executable: trusted,
            home: home
        )
    }

    func testCodexNullAccountIsTheOnlySignedOutAnswer() async throws {
        let home = try makeHome("null-home")
        let trusted = try trustedExecutable(
            named: "null-codex",
            contents: appServerScript(
                accountReply: #"{"id":1,"result":{"account":null,"requiresOpenaiAuth":true}}"#
            )
        )

        await assertConnectThrows(
            .notAuthenticated,
            executable: trusted,
            home: home
        )
    }

    func testCodexResultWithoutAccountFieldIsStatusUnavailable() async throws {
        let home = try makeHome("schema-home")
        let trusted = try trustedExecutable(
            named: "schema-codex",
            contents: appServerScript(
                accountReply: #"{"id":1,"result":{"requiresOpenaiAuth":true}}"#
            )
        )

        await assertConnectThrows(
            .statusUnavailable,
            executable: trusted,
            home: home
        )
    }

    func testCodexAppServerExitBeforeAccountReadIsStatusUnavailable()
        async throws
    {
        let home = try makeHome("exit-home")
        let trusted = try trustedExecutable(
            named: "exit-codex",
            contents: appServerScript(accountReply: nil, exitOnAccountRead: true)
        )

        await assertConnectThrows(
            .statusUnavailable,
            executable: trusted,
            home: home
        )
    }

    func testCodexUsageWindowsReadPrimaryAndSecondary() {
        let bucket: [String: Any] = [
            "primary": [
                "usedPercent": 12,
                "windowDurationMins": 300,
                "resetsAt": 1_800_000_000,
            ],
            "secondary": [
                "usedPercent": 100,
                "windowDurationMins": 10_080,
                "resetsAt": 1_800_500_000,
            ],
        ]

        let windows = AIAccountConnectionService.codexUsageWindows(
            bucket: bucket
        )

        XCTAssertEqual(windows.map(\.kind), [.session, .weeklyAllModels])
        XCTAssertEqual(windows.map(\.usagePercent), [12, 100])
        XCTAssertEqual(
            windows.last?.resetsAt,
            Date(timeIntervalSince1970: 1_800_500_000)
        )
        XCTAssertEqual(
            windows.mostExhausted?.usagePercent,
            100,
            "A weekly exhaustion is not hidden behind a fresh short window"
        )
        XCTAssertTrue(
            AIAccountConnectionService.codexUsageWindows(bucket: nil).isEmpty
        )

        // Durations are optional in the protocol. Without them the key order
        // still yields two distinct windows, never a collapsed pair.
        let undated: [String: Any] = [
            "primary": ["usedPercent": 10, "windowDurationMins": NSNull()],
            "secondary": ["usedPercent": 90],
        ]
        let undatedWindows = AIAccountConnectionService.codexUsageWindows(
            bucket: undated
        )
        XCTAssertEqual(
            undatedWindows.map(\.kind),
            [.session, .weeklyAllModels]
        )
        XCTAssertEqual(undatedWindows.map(\.usagePercent), [10, 90])
        XCTAssertEqual(
            Set(undatedWindows.map(\.identity)).count,
            2,
            "Rows keep distinct identities for view diffing"
        )

        // A reversed duration order still labels the shorter window as the
        // session.
        let reversed: [String: Any] = [
            "primary": ["usedPercent": 1, "windowDurationMins": 10_080],
            "secondary": ["usedPercent": 2, "windowDurationMins": 300],
        ]
        XCTAssertEqual(
            AIAccountConnectionService.codexUsageWindows(bucket: reversed)
                .map(\.usagePercent),
            [2, 1]
        )
    }

    // MARK: - Transport

    func testCollectorIgnoresServerInitiatedRequestsWithClientIDs() {
        let collector = JSONLineResponseCollector()
        collector.append(Data("""
        {"id":1,"method":"item/tool/call","params":{"name":"shell"}}
        {"id":2,"method":"account/chatgptAuthTokens/refresh","params":{}}

        """.utf8))
        XCTAssertNil(collector.response(id: 1))
        XCTAssertNil(collector.response(id: 2))

        collector.append(Data("""
        {"id":1,"result":{"account":null}}

        """.utf8))
        XCTAssertNotNil(collector.response(id: 1)?["result"])
    }

    func testWriteToClosedPipeThrowsInsteadOfRaisingSIGPIPE() throws {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        XCTAssertEqual(fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1), 0)
        try pipe.fileHandleForReading.close()

        // Without F_SETNOSIGPIPE this write would deliver SIGPIPE and end the
        // test process rather than throw.
        XCTAssertThrowsError(try writer.write(contentsOf: Data("x".utf8)))
    }

    func testSendToExitedAppServerThrowsNotRunning() async throws {
        let trusted = try trustedExecutable(
            named: "gone-codex",
            contents: "#!/bin/sh\nexit 0\n"
        )
        let session = CodexAppServerSession(
            executable: trusted,
            codexHome: try makeHome("gone-home")
        )
        try session.start()
        defer { session.close() }

        let outcome = try await session.waitForResponses(
            ids: [1],
            timeout: 2,
            pollInterval: .milliseconds(5)
        )
        XCTAssertEqual(outcome, .processExited)
        XCTAssertThrowsError(try session.send(["method": "ping"])) { error in
            XCTAssertEqual(
                error as? CodexAppServerSessionFailure,
                .notRunning
            )
        }
    }

    func testProcessRunnerSeparatesStandardErrorFromOutput() throws {
        let trusted = try trustedExecutable(
            named: "noisy-provider",
            contents: """
            #!/bin/sh
            printf 'Warning: configuration file was corrupted\\n' >&2
            printf '{"loggedIn":true}\\n'
            exit 0
            """
        )

        let result = try ProviderProcessRunner.run(
            executable: trusted,
            arguments: [],
            environment: [:],
            timeout: 5
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, #"{"loggedIn":true}"#)
        XCTAssertEqual(
            result.errorOutput,
            "Warning: configuration file was corrupted"
        )
        XCTAssertNoThrow(
            try ClaudeAuthenticationStatusDecoder.decode(result.output)
        )
    }

    func testDetachedRunnerHonorsTaskCancellation() async throws {
        let trusted = try trustedExecutable(
            named: "stuck-provider",
            contents: """
            #!/bin/sh
            trap '' TERM
            while :; do :; done
            """
        )

        let worker = Task {
            try await ProviderProcessRunner.runDetached(
                executable: trusted,
                arguments: [],
                environment: [:],
                timeout: 30
            )
        }
        try await Task.sleep(for: .milliseconds(50))
        let startedCancelling = ProcessInfo.processInfo.systemUptime
        worker.cancel()

        do {
            _ = try await worker.value
            XCTFail("Expected cancellation")
        } catch ProviderProcessFailure.cancelled {
            // Expected.
        } catch {
            XCTFail("Expected cancelled, got \(error)")
        }
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - startedCancelling,
            5
        )
    }

    // MARK: - Claude usage parser reset dates

    func testClaudeUsageParserKeepsRecentPastResetAndRollsYearBoundary()
        throws
    {
        let september = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-01T12:00:00Z")
        )
        let recentPast = try ClaudeUsageOutputParser.parse(
            envelope(
                "Current session: 6% used · resets Sep 1 at 4:59am (UTC)"
            ),
            now: september
        )
        XCTAssertEqual(
            recentPast.first?.resetsAt,
            ISO8601DateFormatter().date(from: "2026-09-01T04:59:00Z"),
            "Cached usage with an already-passed reset stays in the past"
        )

        let december = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-12-30T12:00:00Z")
        )
        let nextYear = try ClaudeUsageOutputParser.parse(
            envelope(
                "Current week (all models): 2% used · resets Jan 2 at 1:59pm (UTC)"
            ),
            now: december
        )
        XCTAssertEqual(
            nextYear.first?.resetsAt,
            ISO8601DateFormatter().date(from: "2027-01-02T13:59:00Z")
        )
    }

    // MARK: - Support

    private func assertConnectThrows(
        _ expected: AIAccountConnectionError,
        executable: TrustedProviderExecutable,
        home: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await AIAccountConnectionService.connectCodex(
                executable: executable,
                codexHome: home,
                urlOpener: ProviderAuthURLOpener { _ in true }
            )
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as AIAccountConnectionError {
            switch (error, expected) {
            case (.statusUnavailable, .statusUnavailable),
                (.notAuthenticated, .notAuthenticated),
                (.loginFailed, .loginFailed):
                break
            default:
                XCTFail(
                    "Expected \(expected), got \(error)",
                    file: file,
                    line: line
                )
            }
        } catch {
            XCTFail("Expected \(expected), got \(error)", file: file, line: line)
        }
    }

    /// A login server that succeeds through the browser step and then answers
    /// `account/read` with the given line (or exits instead).
    private func appServerScript(
        accountReply: String?,
        exitOnAccountRead: Bool = false
    ) -> String {
        let accountCommand: String
        if exitOnAccountRead {
            accountCommand = "exit 0"
        } else {
            accountCommand = "printf '%s\\n' '\(accountReply ?? "")'"
        }
        return """
        #!/bin/sh
        while IFS= read -r line; do
          case "$line" in
            *account*login*start*)
              printf '{"id":4,"result":{"loginId":"login-1","authUrl":"https://auth.openai.com/oauth/authorize?state=fixture"}}\\n'
              printf '{"method":"account/login/completed","params":{"loginId":"login-1","success":true}}\\n'
              ;;
            *account*rateLimits*read*)
              printf '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":42}}}}\\n'
              ;;
            *account*usage*read*)
              printf '{"id":3,"result":{"summary":{"lifetimeTokens":1}}}\\n'
              ;;
            *account*read*)
              \(accountCommand)
              ;;
          esac
        done
        """
    }

    private func envelope(_ result: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: [
                "type": "result",
                "subtype": "success",
                "result": result,
                "total_cost_usd": 0,
                "usage": ["input_tokens": 0, "output_tokens": 0],
            ],
            options: [.sortedKeys]
        )
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func makeHome(_ name: String) throws -> URL {
        let home = temporaryDirectory.appendingPathComponent(
            name,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )
        return home
    }

    private func trustedExecutable(
        named name: String,
        contents: String
    ) throws -> TrustedProviderExecutable {
        let executableDirectory = temporaryDirectory.appendingPathComponent(
            "executables-\(name)",
            isDirectory: true
        )
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
}
