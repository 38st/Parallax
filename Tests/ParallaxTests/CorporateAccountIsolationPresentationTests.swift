import XCTest
@testable import Parallax

final class CorporateAccountIsolationPresentationTests: XCTestCase {
    func testCodexDescribesItsAccountSpecificParallaxLoginHome() {
        let presentation = CorporateAccountIsolationPresentation(
            provider: .codex
        )

        XCTAssertEqual(
            presentation.disconnectedDetail,
            "Parallax uses an account-specific Codex login home for this tracked account."
        )
        XCTAssertEqual(
            presentation.capabilityDetail,
            "Codex uses its official local app-server with an account-specific Parallax login home for ChatGPT sign-in and live limits."
        )
        XCTAssertNil(presentation.sharedIdentityWarning)
    }

    func testClaudeDescribesTheMacCurrentSignInWithoutClaimingIsolation() {
        let presentation = CorporateAccountIsolationPresentation(
            provider: .claude
        )

        XCTAssertEqual(
            presentation.disconnectedDetail,
            "Parallax uses this Mac’s current Claude Code sign-in; this record does not create a separate Claude identity."
        )
        XCTAssertEqual(
            presentation.capabilityDetail,
            "Claude uses this Mac’s current Claude Code sign-in. Multiple Claude records do not create independent logins, and Anthropic does not expose plan usage through a supported third-party endpoint."
        )
        XCTAssertFalse(
            presentation.disconnectedDetail.contains(
                "separate login for this account"
            )
        )
        XCTAssertEqual(
            presentation.sharedIdentityWarning,
            CorporateSharedIdentityWarning(
                title: "Change this Mac’s Claude Code sign-in?",
                message: "Continuing changes this Mac’s ambient Claude Code identity, which Claude Code and every Claude record in Parallax share. It does not create a separate account session.",
                continueTitle: "Continue to Claude Sign-In"
            )
        )
    }

    func testDisconnectedAccountHidesFallbackMetadata() {
        let presentation = CorporateAccountMetadataPresentation(
            account: account(
                provider: .codex,
                planName: "Team",
                isConnected: false,
                lastCheckedAt: nil
            )
        )

        XCTAssertNil(presentation.planName)
        XCTAssertNil(presentation.resetsAt)
        XCTAssertFalse(presentation.hasCurrentUsage)
    }

    func testConnectedButUnrefreshedAccountHidesFallbackMetadata() {
        let presentation = CorporateAccountMetadataPresentation(
            account: account(
                provider: .codex,
                planName: "Team",
                isConnected: true,
                lastCheckedAt: nil
            )
        )

        XCTAssertNil(presentation.planName)
        XCTAssertNil(presentation.resetsAt)
        XCTAssertFalse(presentation.hasCurrentUsage)
    }

    func testRefreshedCodexShowsNonPlaceholderPlanButNoUnprovenReset() {
        let presentation = CorporateAccountMetadataPresentation(
            account: account(
                provider: .codex,
                planName: "Team",
                isConnected: true,
                lastCheckedAt: Date(timeIntervalSince1970: 2_000)
            )
        )

        XCTAssertEqual(presentation.planName, "Team")
        XCTAssertNil(presentation.resetsAt)
        XCTAssertTrue(presentation.hasCurrentUsage)
    }

    func testRefreshedClaudeDoesNotClaimCurrentUsageOrReset() {
        let presentation = CorporateAccountMetadataPresentation(
            account: account(
                provider: .claude,
                planName: "Max",
                isConnected: true,
                lastCheckedAt: Date(timeIntervalSince1970: 2_000)
            )
        )

        XCTAssertEqual(presentation.planName, "Max")
        XCTAssertNil(presentation.resetsAt)
        XCTAssertFalse(presentation.hasCurrentUsage)
    }

    func testRefreshedPlaceholderPlanRemainsHidden() {
        let presentation = CorporateAccountMetadataPresentation(
            account: account(
                provider: .codex,
                planName: "Subscription",
                isConnected: true,
                lastCheckedAt: Date(timeIntervalSince1970: 2_000)
            )
        )

        XCTAssertNil(presentation.planName)
    }

    func testConnectedUnrefreshedCodexRequiresRefreshWithoutLimitStatus() {
        let presentation = CorporateAccountStatusPresentation(
            account: account(
                provider: .codex,
                planName: "Team",
                usagePercent: 100,
                isConnected: true,
                lastCheckedAt: nil
            )
        )

        XCTAssertEqual(presentation.label, "Refresh needed")
        XCTAssertEqual(presentation.tone, .secondary)
        XCTAssertEqual(
            presentation.activityTitle,
            "Provider status refreshed for Test account"
        )
    }

    func testClaudeStatusDescribesAuthenticationWithoutUsage() {
        let presentation = CorporateAccountStatusPresentation(
            account: account(
                provider: .claude,
                planName: "Max",
                usagePercent: 100,
                isConnected: true,
                lastCheckedAt: Date(timeIntervalSince1970: 2_000)
            )
        )

        XCTAssertEqual(presentation.label, "Authenticated")
        XCTAssertEqual(presentation.tone, .available)
        XCTAssertEqual(
            presentation.activityTitle,
            "Authentication status refreshed for Test account"
        )
    }

    func testUsageAggregationExcludesUnrefreshedCodexAndClaudeFallbacks() {
        let aggregation = CorporateAccountUsageAggregation(
            accounts: [
                account(
                    provider: .codex,
                    planName: "Team",
                    usagePercent: 100,
                    isConnected: true,
                    lastCheckedAt: nil
                ),
                account(
                    provider: .claude,
                    planName: "Max",
                    usagePercent: 100,
                    isConnected: true,
                    lastCheckedAt: Date(timeIntervalSince1970: 2_000)
                ),
                account(
                    provider: .codex,
                    planName: "Team",
                    usagePercent: 90,
                    isConnected: true,
                    lastCheckedAt: Date(timeIntervalSince1970: 2_000)
                ),
                account(
                    provider: .codex,
                    planName: "Team",
                    usagePercent: 20,
                    isConnected: true,
                    lastCheckedAt: Date(timeIntervalSince1970: 2_000)
                )
            ]
        )

        XCTAssertEqual(aggregation.currentUsageAccounts.count, 2)
        XCTAssertEqual(aggregation.availableAccounts.count, 1)
        XCTAssertEqual(aggregation.nearLimitAccounts.count, 1)
        XCTAssertEqual(aggregation.averageUsagePercent, 55)
        XCTAssertTrue(
            aggregation.currentUsageAccounts.allSatisfy {
                $0.provider == .codex && $0.lastCheckedAt != nil
            }
        )
    }

    private func account(
        provider: AIProvider,
        planName: String,
        usagePercent: Int = 90,
        isConnected: Bool,
        lastCheckedAt: Date?
    ) -> TrackedAIAccount {
        TrackedAIAccount(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            provider: provider,
            label: "Test account",
            email: "test@example.com",
            planName: planName,
            usagePercent: usagePercent,
            resetsAt: Date(timeIntervalSince1970: 9_999),
            lastCheckedAt: lastCheckedAt,
            isConnected: isConnected,
            lifetimeTokens: nil
        )
    }
}
