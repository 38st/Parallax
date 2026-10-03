import Darwin
import Foundation
import XCTest

@testable import Parallax

final class ProviderAccountAuditRegressionTests: XCTestCase {
    func testConfirmedClaudeAuthenticationSurvivesEveryUsageFailure() async throws {
        let (root, executable) = try fixture("#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: root) }
        for failure in ["exit", "timeout", "missing", "inference"] {
            let status = try await AIAccountConnectionService.readClaudeStatus(
                configDirectory: root, executable: executable,
                runProcess: { _, arguments, _, _ in
                    if arguments.first == "auth" {
                        return .init(
                            status: 0,
                            output:
                                #"{"loggedIn":true,"email":"fixture@example.com","subscriptionType":"max"}"#
                        )
                    }
                    if failure == "timeout" { throw ProviderProcessFailure.timedOut }
                    return .init(
                        status: failure == "exit" ? 1 : 0,
                        output: failure == "inference"
                            ? #"{"result":"No limits","total_cost_usd":1,"usage":{"input_tokens":1,"output_tokens":1}}"#
                            : #"{"result":"No plan limits","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0}}"#
                    )
                }
            )
            XCTAssertEqual(status.email, "fixture@example.com")
            XCTAssertNil(status.usageWindows)
            var account = TrackedAIAccount(
                id: UUID(), provider: .claude, label: "Fixture", email: "", planName: "",
                usagePercent: 0, resetsAt: .distantPast, lastCheckedAt: nil, isConnected: false,
                lifetimeTokens: nil)
            account.signInRequired = true
            let applied = CorporateAccountRefreshApplication(status: status, account: account)
            XCTAssertEqual(applied.failure, .incompleteProviderData)
            XCTAssertTrue(applied.account.isSignedIn)
        }
    }

    func testClaudeUsageCancellationStillCancelsConfirmedAuthentication() async throws {
        let (root, executable) = try fixture("#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await AIAccountConnectionService.readClaudeStatus(
                configDirectory: root, executable: executable,
                runProcess: { _, arguments, _, _ in
                    if arguments.first == "auth" {
                        return .init(status: 0, output: #"{"loggedIn":true}"#)
                    }
                    throw ProviderProcessFailure.cancelled
                }
            )
            XCTFail("Expected cancellation")
        } catch is CancellationError {}
    }

    func testClaudeUnsafeExecutableMatchesCodexClassification() async throws {
        let (root, executable) = try fixture("#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777], ofItemAtPath: root.appendingPathComponent("provider").path)
        for login in [false, true] {
            do {
                if login {
                    try await AIAccountConnectionService.runClaudeLogin(
                        configDirectory: root, executable: executable)
                } else {
                    _ = try await AIAccountConnectionService.readClaudeStatus(
                        configDirectory: root, executable: executable)
                }
                XCTFail("Expected untrusted tool rejection")
            } catch AIAccountConnectionError.executableMissing {} catch {
                XCTFail("Expected executableMissing, got \(error)")
            }
        }
    }

    func testCompletedCodexLoginSurvivesFailedAccountRead() async throws {
        let (root, executable) = try fixture(
            """
            #!/bin/sh
            while IFS= read -r line; do
              case "$line" in
                *account*login*start*)
                  printf '{"id":4,"result":{"loginId":"fixture","authUrl":"https://auth.openai.com/oauth/authorize"}}\\n'
                  printf '{"method":"account/login/completed","params":{"loginId":"fixture","success":true}}\\n'
                  ;;
                *account*read*) printf '{"id":1,"error":{"code":-1}}\\n' ;;
              esac
            done
            """)
        defer { try? FileManager.default.removeItem(at: root) }
        let status = try await AIAccountConnectionService.connectCodex(
            executable: executable, codexHome: root, urlOpener: .init { _ in true })
        XCTAssertNil(status.usagePercent)
        XCTAssertNil(status.usageWindows)
    }

    func testRelativeResetRejectsNonfiniteNegativeAndExcessiveIntervals() throws {
        for interval in ["1e308 days", "inf hours", "-1 hours 120 minutes", "100000 days"] {
            let windows = try ClaudeUsageOutputParser.parse(
                envelope("Current session: 10% used · resets in \(interval)"),
                now: Date(timeIntervalSince1970: 1_800_000_000))
            XCTAssertEqual(windows.first?.usagePercent, 10)
            XCTAssertNil(windows.first?.resetsAt, interval)
            XCTAssertNoThrow(try JSONEncoder().encode(windows))
        }
    }

    func testOverLimitPercentagesStayVisibleAsExhausted() {
        for value in [100.1, 150, Double.greatestFiniteMagnitude] {
            XCTAssertEqual(ProviderNumericDecoder.percentage(value), 100)
            XCTAssertEqual(
                AIAccountConnectionService.codexUsageWindows(bucket: [
                    "primary": ["usedPercent": value]
                ]).first?.normalizedUsagePercent, 100)
        }
    }

    func testDirectCodexRefreshAccountReadErrorsAndExitAreStatusUnavailable() async throws {
        for reply in ["printf '{\"id\":1,\"error\":{\"code\":-1}}\\n'", "exit 1"] {
            let (root, executable) = try fixture(
                """
                #!/bin/sh
                while IFS= read -r line; do
                  case "$line" in
                    *account*read*) \(reply) ;;
                  esac
                done
                """)
            defer { try? FileManager.default.removeItem(at: root) }
            do {
                _ = try await AIAccountConnectionService.readCodexStatus(
                    executable: executable, codexHome: root)
                XCTFail("Expected unavailable status")
            } catch AIAccountConnectionError.statusUnavailable {} catch {
                XCTFail("Expected statusUnavailable, got \(error)")
            }
        }
    }

    func testCompletedClaudeLoginWithUnavailableAuthStatusReturnsEmptyConnectedStatus() async throws {
        let (root, executable) = try fixture("#!/bin/sh\nexit 0\n")
        defer { try? FileManager.default.removeItem(at: root) }
        for timedOut in [false, true] {
            let status = try await AIAccountConnectionService.connectClaude(
                configDirectory: root, executable: executable,
                runProcess: { _, arguments, _, _ in
                    if arguments.contains("login") { return .init(status: 0, output: "") }
                    if timedOut { throw ProviderProcessFailure.timedOut }
                    return .init(status: 0, output: "undecodable")
                })
            XCTAssertNil(status.email)
            XCTAssertNil(status.planName)
            XCTAssertNil(status.usagePercent)
            XCTAssertNil(status.usageWindows)
        }
        do {
            _ = try await AIAccountConnectionService.connectClaude(configDirectory: root, executable: executable,
                runProcess: { _, arguments, _, _ in
                    .init(status: 0, output: arguments.contains("login") ? "" : #"{"loggedIn":false}"#)
                })
            XCTFail("Explicit signed-out status must supersede login success")
        } catch AIAccountConnectionError.notAuthenticated {}
    }

    func testAuditExpiredClaudeWindowReportsZeroUsage() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for reset in ["Jan 15 at 7:59am (UTC)", "Jan 15 at 8:00am (UTC)"] {
            let windows = try ClaudeUsageOutputParser.parse(envelope("Current session: 80% used · resets \(reset)"), now: now)
            XCTAssertEqual(windows.first?.usagePercent, 0)
            XCTAssertNotNil(windows.first?.resetsAt)
        }
    }

    private func envelope(_ value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "result": value, "total_cost_usd": 0, "usage": ["input_tokens": 0, "output_tokens": 0],
        ])
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func fixture(_ script: String) throws -> (URL, TrustedProviderExecutable) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProviderAccountAudit-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try removeTestDirectory(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("provider")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return (
            root,
            try ProviderExecutableLocator(currentUserID: getuid(), fixedDirectories: [root]).locate(
                named: "provider")
        )
    }
}
