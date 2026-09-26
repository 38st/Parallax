import AppKit
import CoreFoundation
import Foundation
import os

extension AIAccountConnectionService {
    static func runClaudeLogin(configDirectory: URL) async throws {
        let executable = try trustedExecutable(named: "claude")
        let result: ProviderProcessResult
        do {
            result = try await ProviderProcessRunner.runDetached(
                executable: executable,
                arguments: ["auth", "login", "--claudeai"],
                environment: claudeTrackingEnvironment(
                    configDirectory: configDirectory
                ),
                timeout: 300
            )
        } catch ProviderProcessFailure.cancelled {
            throw CancellationError()
        } catch {
            throw AIAccountConnectionError.loginFailed
        }
        guard result.status == 0 else {
            ProviderDiagnostics.log(
                provider: "claude",
                event: "login exited with status \(result.status)",
                detail: result.errorOutput
            )
            throw AIAccountConnectionError.loginFailed
        }
    }

    static func readClaudeStatus(
        configDirectory: URL
    ) async throws -> ConnectedAIAccountStatus {
        let executable = try trustedExecutable(named: "claude")
        let result: ProviderProcessResult
        do {
            result = try await ProviderProcessRunner.runDetached(
                executable: executable,
                arguments: ["auth", "status", "--json"],
                environment: claudeTrackingEnvironment(
                    configDirectory: configDirectory
                ),
                timeout: 15
            )
        } catch ProviderProcessFailure.cancelled {
            throw CancellationError()
        } catch {
            throw AIAccountConnectionError.statusUnavailable
        }
        // The CLI exits non-zero both when logged out and on any internal
        // failure, so the exit code carries no authentication meaning. Only
        // an explicit `loggedIn: false` in decodable output does.
        let authentication: ClaudeAuthenticationStatus
        do {
            authentication = try ClaudeAuthenticationStatusDecoder.decode(
                result.output
            )
        } catch {
            ProviderDiagnostics.log(
                provider: "claude",
                event: "auth status undecodable (exit \(result.status))",
                detail: result.errorOutput
            )
            throw AIAccountConnectionError.statusUnavailable
        }
        guard authentication.isAuthenticated else {
            throw AIAccountConnectionError.notAuthenticated
        }
        let usageWindows = try await readClaudeUsage(
            executable: executable,
            configDirectory: configDirectory
        )
        let primaryWindow = usageWindows.mostExhausted

        return ConnectedAIAccountStatus(
            email: authentication.email,
            planName: authentication.planName,
            usagePercent: primaryWindow?.normalizedUsagePercent,
            resetsAt: primaryWindow?.resetsAt,
            lifetimeTokens: nil,
            usageWindows: usageWindows
        )
    }

    private static func readClaudeUsage(
        executable: TrustedProviderExecutable,
        configDirectory: URL
    ) async throws -> [AIUsageWindow] {
        let result: ProviderProcessResult
        do {
            result = try await ProviderProcessRunner.runDetached(
                executable: executable,
                arguments: [
                    "-p",
                    "/usage",
                    "--output-format",
                    "json",
                    "--tools",
                    "",
                    "--safe-mode",
                    "--no-session-persistence",
                    "--max-budget-usd",
                    "0.000001",
                ],
                environment: claudeTrackingEnvironment(
                    configDirectory: configDirectory
                ),
                timeout: 30
            )
        } catch ProviderProcessFailure.cancelled {
            throw CancellationError()
        } catch {
            throw AIAccountConnectionError.statusUnavailable
        }
        guard result.status == 0 else {
            ProviderDiagnostics.log(
                provider: "claude",
                event: "usage read exited with status \(result.status)",
                detail: result.errorOutput
            )
            throw AIAccountConnectionError.statusUnavailable
        }
        do {
            return try ClaudeUsageOutputParser.parse(result.output)
        } catch {
            ProviderDiagnostics.log(
                provider: "claude",
                event: "usage output unparseable: \(error)",
                detail: result.errorOutput
            )
            throw AIAccountConnectionError.statusUnavailable
        }
    }

    /// Every Control Center Claude account receives a distinct provider home.
    /// Claude Code stores authentication and configuration beneath this path,
    /// keeping sign-in and usage reads bound to the selected tracking record.
    static func claudeTrackingEnvironment(
        configDirectory: URL
    ) -> [String: String] {
        [
            "CLAUDE_CONFIG_DIR": configDirectory.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "TZ": "UTC",
        ]
    }

    static func claudeConfig(accountID: UUID) throws -> URL {
        try accountSessionDirectory(
            accountID: accountID,
            component: "ClaudeConfig"
        )
    }
}
