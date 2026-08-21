import SwiftUI

private typealias AccountEditorContext =
    CorporateAccountEditorContext
private typealias TrackedAccountEditorView =
    CorporateTrackedAccountEditorContent
private typealias AccountSummaryCard =
    CorporateAccountSummaryCardContent
private typealias AccountStatusPill =
    CorporateAccountStatusPillContent
private typealias AccountTrackingNotice =
    CorporateAccountTrackingNoticeContent
private typealias ProviderMark =
    CorporateProviderMarkContent
struct CorporateAccountTrackerContent: View {
    @Bindable var store: CorporateUsageStore
    @Bindable var operationCoordinator:
        CorporateAccountOperationCoordinator
    @State private var editorContext: AccountEditorContext?
    @State private var accountPendingRemoval: TrackedAIAccount?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("AI accounts")
                            .font(.largeTitle.weight(.semibold))
                        Text(
                            "Track AI account sign-ins and the provider status available on this Mac."
                        )
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Menu {
                        Button {
                            addAndConnect(.codex)
                        } label: {
                            Label(
                                "Codex account",
                                systemImage: AIProvider.codex.systemImage
                            )
                        }
                        Button {
                            addAndConnect(.claude)
                        } label: {
                            Label(
                                "Claude Code identity",
                                systemImage: AIProvider.claude.systemImage
                            )
                        }
                        .disabled(
                            !store.canAddTrackedAccount(provider: .claude)
                        )
                    } label: {
                        Label("Add account", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 12) {
                    AccountSummaryCard(
                        value: "\(store.trackedAccounts.count)",
                        label: "Accounts tracked",
                        systemImage: "person.crop.rectangle.stack",
                        tone: .blue
                    )
                    AccountSummaryCard(
                        value: "\(providerCount(.codex))",
                        label: "Codex accounts",
                        systemImage: AIProvider.codex.systemImage,
                        tone: .blue
                    )
                    AccountSummaryCard(
                        value: "\(providerCount(.claude))",
                        label: "Claude Code identity",
                        systemImage: AIProvider.claude.systemImage,
                        tone: .purple
                    )
                    AccountSummaryCard(
                        value: "\(currentNearLimitCount)",
                        label: "Near a limit",
                        systemImage: "exclamationmark.triangle",
                        tone: .orange
                    )
                }

                AccountTrackingNotice()

                ForEach(AIProvider.allCases) { provider in
                    let accounts = accounts(for: provider)
                    if !accounts.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                ProviderMark(provider: provider)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(provider.displayName)
                                        .font(.title2.weight(.semibold))
                                    providerInventoryDescription(provider)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            LazyVGrid(
                                columns: [
                                    GridItem(.adaptive(minimum: 290), spacing: 12)
                                ],
                                spacing: 12
                            ) {
                                ForEach(accounts) { account in
                                    accountCard(account)
                                }
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .leading)
        }
        .navigationTitle("Accounts")
        .task {
            await operationCoordinator.refreshAccountsOnPresentation()
        }
        .sheet(item: $editorContext) { context in
            TrackedAccountEditorView(store: store, context: context)
        }
        .confirmationDialog(
            "Remove this account?",
            isPresented: Binding(
                get: { accountPendingRemoval != nil },
                set: { if !$0 { accountPendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: accountPendingRemoval
        ) { account in
            Button("Remove \(account.label)", role: .destructive) {
                operationCoordinator.removeTrackedAccount(account)
                accountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                accountPendingRemoval = nil
            }
        } message: { account in
            Text("This removes only the local tracking record for \(account.label). It does not change the provider account.")
        }
    }

    private func accountCard(_ account: TrackedAIAccount) -> some View {
        let metadata = CorporateAccountMetadataPresentation(
            account: account,
            now: store.currentDate
        )

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.label)
                        .font(.headline)
                    identityDetail(account)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                AccountStatusPill(account: account, now: store.currentDate)
            }

            accountUsage(account)

            if let planName = metadata.planName {
                Label(
                    "Tracked plan: \(planName)",
                    systemImage: "creditcard"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Divider()

            if case let .failed(message) = activity(for: account) {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            accountActions(account)
        }
        .padding(16)
        .corporateCard()
    }

    @ViewBuilder
    private func accountUsage(_ account: TrackedAIAccount) -> some View {
        let metadata = CorporateAccountMetadataPresentation(
            account: account,
            now: store.currentDate
        )

        switch metadata.freshness {
        case let .failed(lastSuccessfulRefreshAt, _, failure):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(failureTitle(account: account, failure: failure))
                        .font(.callout.weight(.medium))
                    Text(failure.userMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    retainedUsageDetail(
                        metadata.retainedUsagePercent,
                        lastSuccessfulRefreshAt: lastSuccessfulRefreshAt
                    )
                }
                Spacer()
            }
            .frame(minHeight: 38)
        case let .stale(lastSuccessfulRefreshAt, reason):
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Provider data is stale")
                        .font(.callout.weight(.medium))
                    Text(staleDetail(reason))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    retainedUsageDetail(
                        metadata.retainedUsagePercent,
                        lastSuccessfulRefreshAt: lastSuccessfulRefreshAt
                    )
                }
                Spacer()
            }
            .frame(minHeight: 38)
        case .neverRefreshed:
            if account.isConnected != true {
                disconnectedUsage(account)
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise.circle")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Never refreshed")
                            .font(.callout.weight(.medium))
                        Text("Refresh to load current provider status.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .frame(minHeight: 38)
            }
        case .current:
            currentAccountUsage(account)
        }
    }

    @ViewBuilder
    private func disconnectedUsage(_ account: TrackedAIAccount) -> some View {
            let isolation = CorporateAccountIsolationPresentation(
                provider: account.provider
            )
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Never refreshed — sign in to load status")
                        .font(.callout.weight(.medium))
                    Text(isolation.disconnectedDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(minHeight: 38)
    }

    @ViewBuilder
    private func currentAccountUsage(_ account: TrackedAIAccount) -> some View {
        if account.isConnected != true {
            disconnectedUsage(account)
        } else if account.provider == .claude,
            !account.usageWindows.isEmpty
        {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(
                    Array(account.usageWindows.enumerated()),
                    id: \.offset
                ) { _, window in
                    claudeUsageWindow(window)
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
                if let lifetimeTokens = account.lifetimeTokens {
                    Text("\(lifetimeTokens.formatted()) lifetime tokens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func claudeUsageWindow(_ window: AIUsageWindow) -> some View {
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
    }

    private func usageWindowTitle(_ window: AIUsageWindow) -> String {
        switch window.kind {
        case .session:
            "Current session"
        case .weeklyAllModels:
            "Weekly · All models"
        case .weeklyModel:
            "Weekly · \(window.modelName ?? "Model")"
        }
    }

    @ViewBuilder
    private func retainedUsageDetail(
        _ usagePercent: Int?,
        lastSuccessfulRefreshAt: Date?
    ) -> some View {
        if let usagePercent, let lastSuccessfulRefreshAt {
            Text(
                "Last known usage: \(usagePercent)% from \(lastSuccessfulRefreshAt.formatted(.relative(presentation: .named))). Excluded from current status."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
    }

    private func staleDetail(_ reason: CorporateAccountStaleReason) -> String {
        switch reason {
        case .ageExpired:
            "The last successful refresh is older than 15 minutes."
        case .clockAnomaly:
            "The saved refresh time is ahead of this Mac’s clock. Refresh again to verify it."
        }
    }

    private func failureTitle(
        account: TrackedAIAccount,
        failure: TrackedAccountRefreshFailure
    ) -> String {
        if failure == .authenticationRequired { return "Sign-in required" }
        if account.lastAttemptKind == .signIn { return "Sign-in failed" }
        if failure == .incompleteProviderData {
            return "Current usage is unavailable"
        }
        return "Refresh failed"
    }

    private func accountActions(_ account: TrackedAIAccount) -> some View {
        HStack {
            if let lastAttemptAt = account.lastRefreshAttemptAt {
                Text("Attempted \(lastAttemptAt, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    account.isConnected == true
                        ? "Refresh needed"
                        : "Not connected"
                )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                if account.isConnected == true {
                    operationCoordinator.startRefresh(account)
                } else {
                    operationCoordinator.startConnect(account)
                }
            } label: {
                if activity(for: account) == .signingIn {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Finish in browser")
                    }
                } else if activity(for: account) == .refreshing {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small)
                        Text("Refreshing")
                    }
                } else {
                    Label(
                        account.isConnected == true ? "Refresh" : "Sign in",
                        systemImage: account.isConnected == true
                            ? "arrow.clockwise"
                            : "person.crop.circle.badge.plus"
                    )
                }
            }
            .buttonStyle(.bordered)
            .disabled(
                activity(for: account).isWorking
                    || operationCoordinator.isMutationScopeBusy(for: account)
            )

            Menu {
                if account.provider == .codex {
                    Button("Edit details…") {
                        editorContext = AccountEditorContext(account: account)
                    }
                }
                Button("Remove…", role: .destructive) {
                    accountPendingRemoval = account
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More actions for \(account.label)")
        }
    }

    @ViewBuilder
    private func providerInventoryDescription(
        _ provider: AIProvider
    ) -> some View {
        let count = providerCount(provider)
        if provider == .claude {
            if count == 0 {
                Text("No Claude Code identity")
            } else {
                Text("Current macOS-user identity")
            }
        } else {
            Text("\(count) \(count == 1 ? "account" : "accounts")")
        }
    }

    @ViewBuilder
    private func identityDetail(_ account: TrackedAIAccount) -> some View {
        if !account.email.isEmpty {
            Text(verbatim: account.email)
        } else if account.provider == .claude {
            Text("Current macOS sign-in")
        } else {
            Text("Add account email")
        }
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
