import SwiftUI

extension CorporateAccountTrackerContent {
    @ViewBuilder
    func accountUsage(
        _ account: TrackedAIAccount,
        metadata: CorporateAccountMetadataPresentation
    ) -> some View {
        switch metadata.freshness {
        case let .refreshing(kind, _):
            inFlightUsage(account, kind: kind)
        case let .failed(lastSuccessfulRefreshAt, _, failure):
            usageNotice(
                systemImage: "exclamationmark.triangle",
                tint: .orange,
                title: failureTitle(account: account, failure: failure),
                detail: failure.userMessage,
                retainedUsagePercent: metadata.retainedUsagePercent,
                lastSuccessfulRefreshAt: lastSuccessfulRefreshAt
            )
        case let .stale(lastSuccessfulRefreshAt, reason):
            usageNotice(
                systemImage: "clock.badge.exclamationmark",
                tint: .orange,
                title: String(localized: "Provider data is stale"),
                detail: staleDetail(reason),
                retainedUsagePercent: metadata.retainedUsagePercent,
                lastSuccessfulRefreshAt: lastSuccessfulRefreshAt
            )
        case .neverRefreshed:
            if account.isConnected != true {
                disconnectedUsage(account)
            } else {
                usageNotice(
                    systemImage: "arrow.clockwise.circle",
                    tint: .secondary,
                    title: String(localized: "Never refreshed"),
                    detail: String(
                        localized: "Refresh to load current provider status."
                    )
                )
            }
        case .current:
            if account.isConnected != true {
                disconnectedUsage(account)
            } else {
                usageBars(account, resetsAt: metadata.resetsAt)
            }
        }
    }

    /// The persisted record looks interrupted while an operation runs
    /// (deliberately, for crash recovery). Show the operation instead,
    /// keeping the last known bars visible and dimmed rather than flashing a
    /// failure on every refresh.
    @ViewBuilder
    private func inFlightUsage(
        _ account: TrackedAIAccount,
        kind: TrackedAccountAttemptKind
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !account.usageWindows.isEmpty
                || (account.provider == .codex
                    && account.lastSuccessfulRefreshAt != nil)
            {
                usageBars(account, resetsAt: nil)
                    .opacity(0.55)
            }
            HStack(spacing: 8) {
                ProgressView()
                    .controlSize(.small)
                Text(
                    kind == .signIn
                        ? String(localized: "Waiting for browser sign-in")
                        : String(localized: "Refreshing usage")
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .frame(minHeight: 38)
    }

    /// One layout for every non-live state: icon, title, detail, and the
    /// optional retained-usage line.
    @ViewBuilder
    private func usageNotice(
        systemImage: String,
        tint: Color,
        title: String,
        detail: String,
        retainedUsagePercent: Int? = nil,
        lastSuccessfulRefreshAt: Date? = nil
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let retained = retainedUsagePercent, let lastSuccessfulRefreshAt {
                    let usagePercent: Int = retained
                    Text(
                        "Last known usage: \(usagePercent)% from \(lastSuccessfulRefreshAt.formatted(.relative(presentation: .named))). Excluded from current status."
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .frame(minHeight: 38)
    }

    @ViewBuilder
    private func disconnectedUsage(_ account: TrackedAIAccount) -> some View {
        let isolation = CorporateAccountIsolationPresentation(
            provider: account.provider
        )
        usageNotice(
            systemImage: "person.crop.circle.badge.questionmark",
            tint: .secondary,
            title: String(
                localized: "Never refreshed — sign in to load status"
            ),
            detail: isolation.disconnectedDetail
        )
    }

    @ViewBuilder
    private func usageBars(
        _ account: TrackedAIAccount,
        resetsAt: Date?
    ) -> some View {
        if !account.usageWindows.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(account.usageWindows, id: \.identity) { window in
                    usageWindowRow(window)
                }
                if let lifetimeTokens = account.lifetimeTokens {
                    Text("\(lifetimeTokens.formatted()) lifetime tokens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Current rate-limit window")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(account.normalizedUsagePercent)%")
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(account.needsAttention ? Color.orange : Color.primary)
                }
                ProgressView(
                    value: Double(account.normalizedUsagePercent),
                    total: 100
                )
                .tint(account.needsAttention ? .orange : .accentColor)
                if let resetsAt {
                    Text(
                        "Resets \(resetsAt, format: .relative(presentation: .numeric))"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                if let lifetimeTokens = account.lifetimeTokens {
                    Text("\(lifetimeTokens.formatted()) lifetime tokens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func usageWindowRow(_ window: AIUsageWindow) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(usageWindowTitle(window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(window.normalizedUsagePercent)%")
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(
                        window.normalizedUsagePercent >= 85
                            ? Color.orange
                            : Color.primary
                    )
            }
            ProgressView(
                value: Double(window.normalizedUsagePercent),
                total: 100
            )
            .tint(
                window.normalizedUsagePercent >= 85
                    ? .orange
                    : .accentColor
            )
            if let resetsAt = window.resetsAt {
                Text(
                    "Resets \(resetsAt, format: .relative(presentation: .numeric))"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        // One VoiceOver element reading "Weekly · All models, 27 percent"
        // instead of an unlabeled progress indicator.
        .accessibilityElement(children: .combine)
        .accessibilityValue(
            Text("Usage: \(window.normalizedUsagePercent) percent")
        )
    }

    func usageWindowTitle(_ window: AIUsageWindow, bundle: Bundle = .main) -> String {
        switch window.kind {
        case .session:
            String(localized: "Current session", bundle: bundle)
        case .weeklyAllModels:
            String(localized: "Weekly · All models", bundle: bundle)
        case .weeklyModel:
            String(localized: "Weekly · \(window.modelName ?? String(localized: "Model", bundle: bundle))", bundle: bundle)
        }
    }

    private func staleDetail(_ reason: CorporateAccountStaleReason) -> String {
        switch reason {
        case .ageExpired:
            String(
                localized:
                    "The last successful refresh is older than 15 minutes."
            )
        case .clockAnomaly:
            String(
                localized:
                    "The saved refresh time is ahead of this Mac’s clock. Refresh again to verify it."
            )
        }
    }

    private func failureTitle(
        account: TrackedAIAccount,
        failure: TrackedAccountRefreshFailure
    ) -> String {
        CorporateAccountFailurePresentation(
            account: account,
            failure: failure
        ).noticeTitle
    }
}
