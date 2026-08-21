import SwiftUI

private typealias ProviderMark = CorporateProviderMarkContent

struct CorporateLiveAccountOverviewContent: View {
    @Bindable var store: CorporateUsageStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Overview")
                        .font(.largeTitle.weight(.semibold))
                    Text("A live summary of the subscriptions tracked on this Mac.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    CorporateAccountSummaryCardContent(
                        value: "\(store.trackedAccounts.count)",
                        label: "Accounts tracked",
                        systemImage: "person.crop.rectangle.stack",
                        tone: .blue
                    )
                    CorporateAccountSummaryCardContent(
                        value: "\(connectedAccounts.count)",
                        label: "Connected",
                        systemImage: "checkmark.shield",
                        tone: .green
                    )
                    CorporateAccountSummaryCardContent(
                        value: "\(availableCodexAccounts.count)",
                        label: "Codex available",
                        systemImage: "gauge.with.dots.needle.33percent",
                        tone: .blue
                    )
                    CorporateAccountSummaryCardContent(
                        value: "\(accountsNearLimit.count)",
                        label: "Near a limit",
                        systemImage: "exclamationmark.triangle",
                        tone: .orange
                    )
                }

                CorporateAccountTrackingNoticeContent()

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        attentionCard
                        recentSyncsCard
                    }
                    VStack(spacing: 14) {
                        attentionCard
                        recentSyncsCard
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .leading)
        }
        .navigationTitle("Overview")
    }

    private var connectedAccounts: [TrackedAIAccount] {
        store.trackedAccounts.filter { $0.isConnected == true }
    }

    private var availableCodexAccounts: [TrackedAIAccount] {
        usageAggregation.availableAccounts
    }

    private var accountsNearLimit: [TrackedAIAccount] {
        usageAggregation.nearLimitAccounts
    }

    private var usageAggregation: CorporateAccountUsageAggregation {
        CorporateAccountUsageAggregation(
            accounts: store.trackedAccounts,
            now: store.currentDate
        )
    }

    private var recentlySyncedAccounts: [TrackedAIAccount] {
        store.trackedAccounts
            .filter { $0.lastRefreshAttemptAt != nil }
            .sorted {
                ($0.lastRefreshAttemptAt ?? .distantPast)
                    > ($1.lastRefreshAttemptAt ?? .distantPast)
            }
    }

    private var attentionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading(
                "Needs attention",
                subtitle: "Connected accounts close to their current limit"
            )
            .padding(18)
            Divider()

            if accountsNearLimit.isEmpty {
                ContentUnavailableView(
                    "No accounts near a limit",
                    systemImage: "checkmark.circle",
                    description: Text("Connected Codex accounts currently have room.")
                )
                .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                ForEach(Array(accountsNearLimit.prefix(4).enumerated()), id: \.element.id) { index, account in
                    LiveAccountRow(
                        account: account,
                        now: store.currentDate
                    )
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                    if index < min(accountsNearLimit.count, 4) - 1 {
                        Divider().padding(.leading, 58)
                    }
                }
            }
        }
        .corporateCard()
        .frame(maxWidth: .infinity)
    }

    private var recentSyncsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading(
                "Recent checks",
                subtitle: "Latest provider refresh attempts"
            )
            .padding(18)
            Divider()

            if recentlySyncedAccounts.isEmpty {
                ContentUnavailableView(
                    "Nothing checked yet",
                    systemImage: "arrow.clockwise",
                    description: Text("Sign in to an account to load provider data.")
                )
                .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                ForEach(Array(recentlySyncedAccounts.prefix(4).enumerated()), id: \.element.id) { index, account in
                    LiveAccountRow(
                        account: account,
                        now: store.currentDate,
                        showsSyncTime: true
                    )
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                    if index < min(recentlySyncedAccounts.count, 4) - 1 {
                        Divider().padding(.leading, 58)
                    }
                }
            }
        }
        .corporateCard()
        .frame(maxWidth: .infinity)
    }
}

struct CorporateLiveAccountPeopleContent: View {
    @Bindable var store: CorporateUsageStore
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("People")
                    .font(.largeTitle.weight(.semibold))
                Text("The account identities attached to tracked subscriptions.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)

            HStack {
                TextField("Search accounts", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Spacer()
                Text("\(filteredAccounts.count) identities")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 14)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredAccounts.enumerated()), id: \.element.id) { index, account in
                    LiveAccountRow(
                        account: account,
                        now: store.currentDate,
                        showsPlan: true
                    )
                            .padding(.horizontal, 16)
                            .padding(.vertical, 13)
                        if index < filteredAccounts.count - 1 {
                            Divider().padding(.leading, 58)
                        }
                    }
                }
                .corporateCard()
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("People")
    }

    private var filteredAccounts: [TrackedAIAccount] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.trackedAccounts }
        return store.trackedAccounts.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.email.localizedCaseInsensitiveContains(query)
                || $0.provider.displayName.localizedCaseInsensitiveContains(query)
        }
    }
}

struct CorporateLiveAccountProvidersContent: View {
    @Bindable var store: CorporateUsageStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Providers")
                        .font(.largeTitle.weight(.semibold))
                    Text("Real connection and usage coverage by provider.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                ForEach(AIProvider.allCases) { provider in
                    providerCard(provider)
                }
            }
            .padding(28)
            .frame(maxWidth: 1050, alignment: .leading)
        }
        .navigationTitle("Providers")
    }

    private func providerCard(_ provider: AIProvider) -> some View {
        let accounts = store.trackedAccounts.filter { $0.provider == provider }
        let connected = accounts.filter { $0.isConnected == true }
        let usageAggregation = CorporateAccountUsageAggregation(
            accounts: accounts,
            now: store.currentDate
        )

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                ProviderMark(provider: provider)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.displayName)
                        .font(.title2.weight(.semibold))
                    Text(provider.shortDescription)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(connected.count) of \(accounts.count) connected")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                ProviderStat(value: "\(accounts.count)", label: "Tracked")
                ProviderStat(value: "\(connected.count)", label: "Connected")
                ProviderStat(
                    value: "\(usageAggregation.nearLimitAccounts.count)",
                    label: "Near limit"
                )
                ProviderStat(
                    value: usageAggregation.averageUsagePercent.map {
                        "\($0)%"
                    } ?? "—",
                    label: "Average usage"
                )
                Spacer()
            }

            if provider == .claude {
                Label(
                    CorporateAccountIsolationPresentation(
                        provider: provider
                    ).capabilityDetail,
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                LiveAccountRow(
                    account: account,
                    now: store.currentDate,
                    showsPlan: true
                )
                if index < accounts.count - 1 { Divider().padding(.leading, 42) }
            }
        }
        .padding(20)
        .corporateCard()
    }
}

struct CorporateLiveAccountActivityContent: View {
    @Bindable var store: CorporateUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Activity")
                    .font(.largeTitle.weight(.semibold))
                Text("Provider refresh attempts recorded from tracked accounts.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(28)

            if syncedAccounts.isEmpty {
                ContentUnavailableView(
                    "No account activity",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Sign in or refresh an account to record a sync.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(syncedAccounts.enumerated()), id: \.element.id) { index, account in
                            HStack(spacing: 12) {
                                ProviderMark(provider: account.provider)
                                    .scaleEffect(0.82)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(
                                        CorporateAccountStatusPresentation(
                                            account: account,
                                            now: store.currentDate
                                        ).activityTitle
                                    )
                                        .font(.callout.weight(.medium))
                                    Text(account.email.isEmpty ? account.provider.displayName : account.email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let attemptedAt = account.lastRefreshAttemptAt {
                                    Text(attemptedAt, format: .relative(presentation: .named))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(16)
                            if index < syncedAccounts.count - 1 { Divider() }
                        }
                    }
                    .corporateCard()
                    .padding(.horizontal, 28)
                    .padding(.bottom, 28)
                }
            }
        }
        .navigationTitle("Activity")
    }

    private var syncedAccounts: [TrackedAIAccount] {
        store.trackedAccounts
            .filter { $0.lastRefreshAttemptAt != nil }
            .sorted {
                ($0.lastRefreshAttemptAt ?? .distantPast)
                    > ($1.lastRefreshAttemptAt ?? .distantPast)
            }
    }
}

private struct LiveAccountRow: View {
    let account: TrackedAIAccount
    let now: Date
    var showsSyncTime = false
    var showsPlan = false

    var body: some View {
        HStack(spacing: 12) {
            ProviderMark(provider: account.provider)
                .scaleEffect(0.82)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email.isEmpty ? account.label : account.email)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if metadata.hasCurrentUsage {
                Text("\(account.normalizedUsagePercent)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(account.needsAttention ? Color.orange : Color.secondary)
            }
            CorporateAccountStatusPillContent(account: account, now: now)
        }
    }

    private var metadata: CorporateAccountMetadataPresentation {
        CorporateAccountMetadataPresentation(account: account, now: now)
    }

    private var detail: String {
        if showsSyncTime, let attemptedAt = account.lastRefreshAttemptAt {
            return "\(account.provider.displayName) · Attempted \(attemptedAt.formatted(.relative(presentation: .named)))"
        }
        if showsPlan, let planName = metadata.planName {
            return "\(account.label) · \(account.provider.displayName) · Tracked plan: \(planName)"
        }
        return "\(account.provider.displayName) · \(account.label)"
    }
}

struct CorporateProviderMarkContent: View {
    let provider: AIProvider

    var body: some View {
        Image(systemName: provider.systemImage)
            .font(.title3.weight(.medium))
            .foregroundStyle(provider == .claude ? Color.purple : Color.blue)
            .frame(width: 38, height: 38)
            .background(
                (provider == .claude ? Color.purple : Color.blue).opacity(0.12),
                in: RoundedRectangle(cornerRadius: 10)
            )
    }
}

private struct ProviderStat: View {
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title2.monospacedDigit().weight(.semibold))
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private func sectionHeading(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 3) {
        Text(title)
            .font(.headline)
        Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private extension View {
    func corporateCard() -> some View {
        background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.035), radius: 10, y: 3)
    }
}
