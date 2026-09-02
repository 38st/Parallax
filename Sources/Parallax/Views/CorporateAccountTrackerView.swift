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
                                "Claude account",
                                systemImage: AIProvider.claude.systemImage
                            )
                        }
                    } label: {
                        Label("Add account", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 12) {
                    AccountSummaryCard(
                        value: "\(store.trackedAccounts.count)",
                        label: String(localized: "Accounts tracked"),
                        systemImage: "person.crop.rectangle.stack",
                        tone: .blue
                    )
                    AccountSummaryCard(
                        value: "\(providerCount(.codex))",
                        label: String(localized: "Codex accounts"),
                        systemImage: AIProvider.codex.systemImage,
                        tone: .blue
                    )
                    AccountSummaryCard(
                        value: "\(providerCount(.claude))",
                        label: String(localized: "Claude accounts"),
                        systemImage: AIProvider.claude.systemImage,
                        tone: .purple
                    )
                    AccountSummaryCard(
                        value: "\(currentNearLimitCount)",
                        label: String(localized: "Near a limit"),
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

                            // Rows take the tallest card's height; without an
                            // explicit alignment each shorter card floats in
                            // the middle of its row.
                            LazyVGrid(
                                columns: [
                                    GridItem(
                                        .adaptive(minimum: 290),
                                        spacing: 12,
                                        alignment: .top
                                    )
                                ],
                                alignment: .leading,
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
            await operationCoordinator.refreshDueAccounts()
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
        let inFlightAttemptKind = store.inFlightAttemptKind(for: account.id)
        let metadata = CorporateAccountMetadataPresentation(
            account: account,
            now: store.currentDate,
            inFlightAttemptKind: inFlightAttemptKind
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
                        .truncationMode(.middle)
                        .help(account.email)
                }
                Spacer()
                AccountStatusPill(
                    account: account,
                    now: store.currentDate,
                    inFlightAttemptKind: inFlightAttemptKind
                )
            }

            accountUsage(account, metadata: metadata)

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
    private func accountUsage(
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

    private func usageWindowTitle(_ window: AIUsageWindow) -> String {
        switch window.kind {
        case .session:
            String(localized: "Current session")
        case .weeklyAllModels:
            String(localized: "Weekly · All models")
        case .weeklyModel:
            String(localized: "Weekly · \(window.modelName ?? "Model")")
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
        if failure == .authenticationRequired || account.needsSignIn {
            return String(localized: "Sign-in required")
        }
        if account.lastAttemptKind == .signIn {
            return String(localized: "Sign-in failed")
        }
        if failure == .incompleteProviderData {
            return String(localized: "Current usage is unavailable")
        }
        return String(localized: "Refresh failed")
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

            // A card offers "Sign in" when the account was never connected or
            // the provider reported no login; otherwise "Refresh".
            Button {
                if account.isSignedIn {
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
                } else if account.isSignedIn {
                    Label("Refresh", systemImage: "arrow.clockwise")
                } else {
                    Label(
                        "Sign in",
                        systemImage: "person.crop.circle.badge.plus"
                    )
                }
            }
            .buttonStyle(.bordered)
            .disabled(
                activity(for: account).isWorking
                    || operationCoordinator.isMutationScopeBusy(for: account)
            )

            Menu {
                Button("Edit details…") {
                    editorContext = AccountEditorContext(account: account)
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
        Text(LocalizedCount.accounts(providerCount(provider)))
    }

    @ViewBuilder
    private func identityDetail(_ account: TrackedAIAccount) -> some View {
        if !account.email.isEmpty {
            Text(verbatim: account.email)
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
