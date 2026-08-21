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
    }

    func testClaudeDescribesItsAccountSpecificParallaxHome() {
        let presentation = CorporateAccountIsolationPresentation(
            provider: .claude
        )

        XCTAssertEqual(
            presentation.disconnectedDetail,
            "Parallax uses an account-specific Claude Code home for this tracked account."
        )
        XCTAssertEqual(
            presentation.capabilityDetail,
            "Claude Code uses an account-specific Parallax home for sign-in, configuration, saved sessions, and live usage limits."
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

    func testRefreshedCodexShowsOnlyProviderSuppliedReset() {
        let providerReset = Date(timeIntervalSince1970: 9_500)
        let presentation = CorporateAccountMetadataPresentation(
            account: account(
                provider: .codex,
                planName: "Team",
                isConnected: true,
                lastCheckedAt: Date(timeIntervalSince1970: 2_000),
                providerResetsAt: providerReset
            ),
            now: Date(timeIntervalSince1970: 2_100)
        )

        XCTAssertEqual(presentation.planName, "Team")
        XCTAssertEqual(presentation.resetsAt, providerReset)
        XCTAssertTrue(presentation.hasCurrentUsage)
    }

    func testRefreshedCodexNeverPromotesLegacyEditableReset() {
        let presentation = CorporateAccountMetadataPresentation(
            account: account(
                provider: .codex,
                planName: "Team",
                isConnected: true,
                lastCheckedAt: Date(timeIntervalSince1970: 2_000)
            ),
            now: Date(timeIntervalSince1970: 2_100)
        )

        XCTAssertNil(presentation.resetsAt)
    }

    func testRefreshedClaudeShowsPlanAndLiveUsageWindowReset() {
        let reset = Date(timeIntervalSince1970: 9_999)
        let presentation = CorporateAccountMetadataPresentation(
            account: account(
                provider: .claude,
                planName: "Max",
                isConnected: true,
                lastCheckedAt: Date(timeIntervalSince1970: 2_000),
                usageWindows: [
                    AIUsageWindow(
                        kind: .session,
                        usagePercent: 42,
                        resetsAt: reset
                    )
                ]
            ),
            now: Date(timeIntervalSince1970: 2_100)
        )

        XCTAssertEqual(presentation.planName, "Max")
        XCTAssertEqual(presentation.resetsAt, reset)
        XCTAssertTrue(presentation.hasCurrentUsage)
    }

    func testRefreshedPlaceholderPlanRemainsHidden() {
        let presentation = CorporateAccountMetadataPresentation(
            account: account(
                provider: .codex,
                planName: "Subscription",
                isConnected: true,
                lastCheckedAt: Date(timeIntervalSince1970: 2_000)
            ),
            now: Date(timeIntervalSince1970: 2_100)
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
            ),
            now: Date(timeIntervalSince1970: 2_100)
        )

        XCTAssertEqual(presentation.label, "Never refreshed")
        XCTAssertEqual(presentation.tone, .secondary)
        XCTAssertEqual(
            presentation.activityTitle,
            "Provider status has not refreshed for Test account"
        )
    }

    func testClaudeStatusReflectsHighestLiveUsageWindow() {
        let presentation = CorporateAccountStatusPresentation(
            account: account(
                provider: .claude,
                planName: "Max",
                usagePercent: 100,
                isConnected: true,
                lastCheckedAt: Date(timeIntervalSince1970: 2_000),
                usageWindows: [
                    AIUsageWindow(kind: .session, usagePercent: 12),
                    AIUsageWindow(
                        kind: .weeklyAllModels,
                        usagePercent: 100
                    ),
                ]
            ),
            now: Date(timeIntervalSince1970: 2_100)
        )

        XCTAssertEqual(presentation.label, "Limit reached")
        XCTAssertEqual(presentation.tone, .attention)
        XCTAssertEqual(
            presentation.activityTitle,
            "Usage synced for Test account"
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
            ],
            now: Date(timeIntervalSince1970: 2_100)
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

    func testAgeExpiryMarksRetainedUsageStaleAndExcludesIt() {
        let account = account(
            provider: .codex,
            planName: "Team",
            usagePercent: 90,
            isConnected: true,
            lastCheckedAt: Date(timeIntervalSince1970: 2_000)
        )
        let now = Date(
            timeIntervalSince1970: 2_000
                + CorporateAccountFreshnessPolicy.currentAgeThreshold + 1
        )
        let metadata = CorporateAccountMetadataPresentation(
            account: account,
            now: now
        )
        let status = CorporateAccountStatusPresentation(
            account: account,
            now: now
        )
        let aggregation = CorporateAccountUsageAggregation(
            accounts: [account],
            now: now
        )

        XCTAssertEqual(
            metadata.freshness,
            .stale(
                lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 2_000),
                reason: .ageExpired
            )
        )
        XCTAssertEqual(metadata.retainedUsagePercent, 90)
        XCTAssertFalse(metadata.hasCurrentUsage)
        XCTAssertEqual(status.label, "Stale")
        XCTAssertTrue(aggregation.currentUsageAccounts.isEmpty)
    }

    func testClockRollbackFailsClosedUntilAnotherRefresh() {
        let account = account(
            provider: .codex,
            planName: "Team",
            usagePercent: 20,
            isConnected: true,
            lastCheckedAt: Date(timeIntervalSince1970: 3_000)
        )
        let metadata = CorporateAccountMetadataPresentation(
            account: account,
            now: Date(timeIntervalSince1970: 2_999)
        )

        XCTAssertEqual(
            metadata.freshness,
            .stale(
                lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 3_000),
                reason: .clockAnomaly
            )
        )
        XCTAssertFalse(metadata.hasCurrentUsage)
        XCTAssertEqual(metadata.retainedUsagePercent, 20)
    }

    func testFailureRetainsLastKnownUsageButNeverTreatsItAsCurrent() {
        let failedAt = Date(timeIntervalSince1970: 2_200)
        let account = account(
            provider: .codex,
            planName: "Team",
            usagePercent: 90,
            isConnected: true,
            lastCheckedAt: Date(timeIntervalSince1970: 2_000),
            lastRefreshAttemptAt: failedAt,
            lastRefreshFailure: .statusUnavailable
        )
        let metadata = CorporateAccountMetadataPresentation(
            account: account,
            now: failedAt
        )
        let status = CorporateAccountStatusPresentation(
            account: account,
            now: failedAt
        )

        XCTAssertEqual(
            metadata.freshness,
            .failed(
                lastSuccessfulRefreshAt: Date(timeIntervalSince1970: 2_000),
                attemptedAt: failedAt,
                failure: .statusUnavailable
            )
        )
        XCTAssertEqual(metadata.retainedUsagePercent, 90)
        XCTAssertFalse(metadata.hasCurrentUsage)
        XCTAssertEqual(status.label, "Refresh failed")
        XCTAssertEqual(status.tone, .attention)
    }

    func testLegacyClaudeRefreshWithoutUsageDoesNotClaimLiveUsage() {
        let account = account(
            provider: .claude,
            planName: "Max",
            usagePercent: 100,
            isConnected: true,
            lastCheckedAt: Date(timeIntervalSince1970: 2_000)
        )
        let metadata = CorporateAccountMetadataPresentation(
            account: account,
            now: Date(timeIntervalSince1970: 2_100)
        )

        XCTAssertTrue(metadata.freshness.isCurrent)
        XCTAssertFalse(metadata.hasCurrentUsage)
        XCTAssertNil(metadata.retainedUsagePercent)
    }

    func testIncompleteCodexSuccessRetainsUsageButReturnsFailure() {
        let original = account(
            provider: .codex,
            planName: "Team",
            usagePercent: 90,
            isConnected: true,
            lastCheckedAt: Date(timeIntervalSince1970: 2_000)
        )
        let application = CorporateAccountRefreshApplication(
            status: ConnectedAIAccountStatus(
                email: "new@example.com",
                planName: "Pro",
                usagePercent: nil,
                resetsAt: nil,
                lifetimeTokens: nil
            ),
            account: original
        )

        XCTAssertEqual(application.failure, .incompleteProviderData)
        XCTAssertEqual(application.account.usagePercent, 90)
        XCTAssertEqual(application.account.planName, "Team")
        XCTAssertEqual(application.account.email, "new@example.com")
    }

    func testCompleteCodexRefreshReplacesResetProvenanceExactly() {
        let oldReset = Date(timeIntervalSince1970: 8_000)
        let newReset = Date(timeIntervalSince1970: 9_500)
        let original = account(
            provider: .codex,
            planName: "Team",
            isConnected: true,
            lastCheckedAt: Date(timeIntervalSince1970: 2_000),
            providerResetsAt: oldReset
        )

        let refreshed = CorporateAccountRefreshApplication(
            status: ConnectedAIAccountStatus(
                email: nil,
                planName: "Pro",
                usagePercent: 42,
                resetsAt: newReset,
                lifetimeTokens: 123
            ),
            account: original
        )
        let resetOmitted = CorporateAccountRefreshApplication(
            status: ConnectedAIAccountStatus(
                email: nil,
                planName: "Pro",
                usagePercent: 43,
                resetsAt: nil,
                lifetimeTokens: 124
            ),
            account: refreshed.account
        )

        XCTAssertNil(refreshed.failure)
        XCTAssertEqual(refreshed.account.providerResetsAt, newReset)
        XCTAssertEqual(refreshed.account.resetsAt, newReset)
        XCTAssertNil(resetOmitted.failure)
        XCTAssertNil(resetOmitted.account.providerResetsAt)
        XCTAssertEqual(resetOmitted.account.resetsAt, newReset)
    }

    func testSignInFailureHasDistinctCopyActivityAndAccessibility() {
        let attemptedAt = Date(timeIntervalSince1970: 2_100)
        let presentation = CorporateAccountStatusPresentation(
            account: account(
                provider: .codex,
                planName: "Team",
                isConnected: false,
                lastCheckedAt: nil,
                lastRefreshAttemptAt: attemptedAt,
                lastRefreshCompletedAt: attemptedAt,
                lastAttemptKind: .signIn,
                lastRefreshFailure: .signInFailed
            ),
            now: attemptedAt
        )

        XCTAssertEqual(presentation.label, "Sign-in failed")
        XCTAssertEqual(
            presentation.activityTitle,
            "Sign-in failed for Test account"
        )
        XCTAssertEqual(
            presentation.accessibilityLabel,
            "Sign-in failed for Test account"
        )
    }

    func testClaudeAuthMethodIsNeverPromotedToPlanMetadata() {
        let original = account(
            provider: .claude,
            planName: "Subscription",
            isConnected: false,
            lastCheckedAt: nil
        )
        let application = CorporateAccountRefreshApplication(
            status: ConnectedAIAccountStatus(
                email: "claude@example.com",
                planName: "oauth",
                usagePercent: 22,
                resetsAt: nil,
                lifetimeTokens: nil,
                usageWindows: [
                    AIUsageWindow(kind: .session, usagePercent: 22)
                ]
            ),
            account: original
        )
        var refreshed = application.account
        refreshed.lastCheckedAt = Date(timeIntervalSince1970: 2_000)
        let metadata = CorporateAccountMetadataPresentation(
            account: refreshed,
            now: Date(timeIntervalSince1970: 2_100)
        )

        XCTAssertNil(application.failure)
        XCTAssertEqual(application.account.planName, "Subscription")
        XCTAssertNil(metadata.planName)
        XCTAssertTrue(metadata.hasCurrentUsage)
    }

    func testAccountEditorRoundTripPreservesFreshnessLifecycleExactly() {
        let successfulAt = Date(timeIntervalSince1970: 3_000)
        let attemptedAt = Date(timeIntervalSince1970: 3_100)
        let completedAt = Date(timeIntervalSince1970: 3_140)
        let original = account(
            provider: .codex,
            planName: "Team",
            usagePercent: 44,
            isConnected: false,
            lastCheckedAt: nil,
            lastRefreshAttemptAt: attemptedAt,
            lastRefreshCompletedAt: completedAt,
            lastAttemptKind: .signIn,
            lastRefreshFailure: .signInFailed,
            lastSuccessfulRefreshAt: successfulAt,
            providerResetsAt: Date(timeIntervalSince1970: 4_000)
        )
        var draft = TrackedAccountEditorDraft(account: original)
        draft.label = " Edited account "
        draft.usagePercent = 50

        let edited = draft.account(id: original.id)

        XCTAssertEqual(edited.label, "Edited account")
        XCTAssertEqual(edited.usagePercent, 50)
        XCTAssertEqual(edited.lastSuccessfulRefreshAt, successfulAt)
        XCTAssertEqual(edited.lastRefreshAttemptAt, attemptedAt)
        XCTAssertEqual(edited.lastRefreshCompletedAt, completedAt)
        XCTAssertEqual(edited.lastAttemptKind, .signIn)
        XCTAssertEqual(edited.lastRefreshFailure, .signInFailed)
        XCTAssertEqual(
            edited.providerResetsAt,
            Date(timeIntervalSince1970: 4_000)
        )
        XCTAssertEqual(edited.isConnected, original.isConnected)
        XCTAssertEqual(edited.lifetimeTokens, original.lifetimeTokens)
    }

    func testAccountEditorMergeKeepsExistingProviderImmutable() {
        let original = account(
            provider: .codex,
            planName: "Team",
            isConnected: true,
            lastCheckedAt: Date(timeIntervalSince1970: 3_000)
        )
        var draft = TrackedAccountEditorDraft(account: original)
        draft.provider = .claude
        draft.label = "Edited account"

        let edited = draft.merging(into: original)

        XCTAssertEqual(edited.provider, .codex)
        XCTAssertEqual(edited.label, "Edited account")
    }

    func testInvalidatedBusyActivityIsHiddenAndCannotMatchNewGeneration() {
        let generation = UUID()
        let replacementGeneration = UUID()
        let operation = AccountConnectionOperation(
            generation: generation,
            activity: .refreshing
        )

        XCTAssertEqual(
            operation.visibleActivity(isGenerationCurrent: true),
            .refreshing
        )
        XCTAssertEqual(
            operation.visibleActivity(isGenerationCurrent: false),
            .idle
        )
        XCTAssertTrue(operation.belongs(to: generation))
        XCTAssertFalse(operation.belongs(to: replacementGeneration))
    }

    private func account(
        provider: AIProvider,
        planName: String,
        usagePercent: Int = 90,
        isConnected: Bool,
        lastCheckedAt: Date?,
        lastRefreshAttemptAt: Date? = nil,
        lastRefreshCompletedAt: Date? = nil,
        lastAttemptKind: TrackedAccountAttemptKind? = nil,
        lastRefreshFailure: TrackedAccountRefreshFailure? = nil,
        lastSuccessfulRefreshAt: Date? = nil,
        usageWindows: [AIUsageWindow] = [],
        providerResetsAt: Date? = nil
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
            lifetimeTokens: nil,
            lastSuccessfulRefreshAt:
                lastSuccessfulRefreshAt ?? lastCheckedAt,
            lastRefreshAttemptAt: lastRefreshAttemptAt,
            lastRefreshCompletedAt: lastRefreshCompletedAt,
            lastAttemptKind: lastAttemptKind,
            lastRefreshFailure: lastRefreshFailure,
            usageWindows: usageWindows,
            providerResetsAt: providerResetsAt
        )
    }
}
