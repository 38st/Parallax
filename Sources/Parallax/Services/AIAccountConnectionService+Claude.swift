import AppKit
import CoreFoundation
import Foundation
import os

extension AIAccountConnectionService {
    typealias ClaudeProcessRunner = @Sendable (
        TrustedProviderExecutable, [String], [String: String], TimeInterval
    ) async throws -> ProviderProcessResult

    static func connectClaude(
        configDirectory: URL,
        executable: TrustedProviderExecutable? = nil,
        processRegistry: ProviderProcessRegistry = .shared,
        runProcess: ClaudeProcessRunner? = nil
    ) async throws -> ConnectedAIAccountStatus {
        try await runClaudeLogin(
            configDirectory: configDirectory, executable: executable,
            processRegistry: processRegistry, runProcess: runProcess
        )
        do {
            return try await readClaudeStatus(
                configDirectory: configDirectory, executable: executable,
                processRegistry: processRegistry, runProcess: runProcess
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch AIAccountConnectionError.notAuthenticated {
            // A subsequent explicit signed-out answer supersedes login success.
            throw AIAccountConnectionError.notAuthenticated
        } catch {
            // The login itself succeeded. A failed status read only leaves
            // provider details missing until the next refresh, as for Codex.
            try Task.checkCancellation()
            return ConnectedAIAccountStatus(
                email: nil, planName: nil, usagePercent: nil,
                resetsAt: nil, lifetimeTokens: nil
            )
        }
    }

    private static func claudeProcessRunner(registry: ProviderProcessRegistry) -> ClaudeProcessRunner {
        { executable, arguments, environment, timeout in
            try await ProviderProcessRunner.runDetached(
                executable: executable, arguments: arguments,
                environment: environment, timeout: timeout, registry: registry
            )
        }
    }

    static func runClaudeLogin(
        configDirectory: URL,
        executable: TrustedProviderExecutable? = nil,
        processRegistry: ProviderProcessRegistry = .shared,
        runProcess: ClaudeProcessRunner? = nil
    ) async throws {
        let executable = try executable ?? trustedExecutable(named: "claude")
        let result: ProviderProcessResult
        do {
            let runner = runProcess ?? claudeProcessRunner(registry: processRegistry)
            result = try await runner(
                executable, ["auth", "login", "--claudeai"],
                claudeTrackingEnvironment(configDirectory: configDirectory), 300
            )
        } catch ProviderProcessFailure.cancelled {
            throw CancellationError()
        } catch ProviderProcessFailure.unsafeExecutable {
            throw AIAccountConnectionError.executableMissing("Claude")
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
        configDirectory: URL,
        executable: TrustedProviderExecutable? = nil,
        processRegistry: ProviderProcessRegistry = .shared,
        runProcess: ClaudeProcessRunner? = nil
    ) async throws -> ConnectedAIAccountStatus {
        let executable = try executable ?? trustedExecutable(named: "claude")
        let runProcess = runProcess ?? claudeProcessRunner(registry: processRegistry)
        let result: ProviderProcessResult
        do {
            result = try await runProcess(
                executable,
                ["auth", "status", "--json"],
                claudeTrackingEnvironment(
                    configDirectory: configDirectory
                ),
                15
            )
        } catch ProviderProcessFailure.cancelled {
            throw CancellationError()
        } catch ProviderProcessFailure.unsafeExecutable {
            throw AIAccountConnectionError.executableMissing("Claude")
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
        let usageWindows: [AIUsageWindow]?
        do {
            usageWindows = try await readClaudeUsage(
                executable: executable,
                configDirectory: configDirectory,
                runProcess: runProcess
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            // Authentication is confirmed. Missing usage must not undo it.
            usageWindows = nil
        }
        let primaryWindow = usageWindows?.mostExhausted

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
        configDirectory: URL,
        runProcess: ClaudeProcessRunner
    ) async throws -> [AIUsageWindow] {
        let result: ProviderProcessResult
        do {
            result = try await runProcess(
                executable,
                [
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
                claudeTrackingEnvironment(
                    configDirectory: configDirectory
                ),
                30
            )
        } catch ProviderProcessFailure.cancelled {
            throw CancellationError()
        } catch ProviderProcessFailure.unsafeExecutable {
            throw AIAccountConnectionError.executableMissing("Claude")
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
