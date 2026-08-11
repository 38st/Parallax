import SwiftUI

private enum CorporateSection: String, CaseIterable, Identifiable {
    case accounts
    case overview
    case people
    case providers
    case activity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .accounts: "Accounts"
        case .overview: "Overview"
        case .people: "People"
        case .providers: "Providers"
        case .activity: "Activity"
        }
    }

    var systemImage: String {
        switch self {
        case .accounts: "person.crop.rectangle.stack"
        case .overview: "chart.bar.xaxis"
        case .people: "person.2"
        case .providers: "square.stack.3d.up"
        case .activity: "clock.arrow.circlepath"
        }
    }
}

struct ParallaxWorkspaceView: View {
    @Bindable var store: LibraryStore
    @State private var corporateStore = CorporateUsageStore()

    var body: some View {
        TabView {
            CorporateControlCenterView(store: corporateStore)
                .tabItem {
                    Label("Control Center", systemImage: "building.2")
                }

            LocalSpacesView(store: store)
                .tabItem {
                    Label("Local Spaces", systemImage: "macwindow.on.rectangle")
                }
        }
        .accessibilityIdentifier("workspace.root")
    }
}

struct CorporateControlCenterView: View {
    @Bindable var store: CorporateUsageStore
    @State private var selection: CorporateSection? = .accounts

    var body: some View {
        NavigationSplitView {
            List(CorporateSection.allCases, selection: $selection) { section in
                Label(section.label, systemImage: section.systemImage)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationTitle("Parallax")
            .safeAreaInset(edge: .bottom) {
                organizationFooter
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            Group {
                switch selection ?? .accounts {
                case .accounts:
                    CorporateAccountTrackerView(store: store)
                case .overview:
                    LiveAccountOverviewView(store: store)
                case .people:
                    LiveAccountPeopleView(store: store)
                case .providers:
                    LiveAccountProvidersView(store: store)
                case .activity:
                    LiveAccountActivityView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var organizationFooter: some View {
        let connectedCount = store.trackedAccounts.filter {
            $0.isConnected == true
        }.count
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.16))
                Image(systemName: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("Account tracking")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("\(connectedCount) of \(store.trackedAccounts.count) connected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.bar)
    }
}

private struct AccountEditorContext: Identifiable {
    let id: UUID
    let account: TrackedAIAccount?

    init(account: TrackedAIAccount? = nil) {
        self.account = account
        id = account?.id ?? UUID()
    }
}

struct TrackedAccountEditorDraft: Equatable, Sendable {
    var provider: AIProvider
    var label: String
    var email: String
    var planName: String
    var usagePercent: Int
    var resetsAt: Date
    private let lifecycleSource: TrackedAIAccount?

    init(account: TrackedAIAccount?, now: Date = Date()) {
        lifecycleSource = account
        provider = account?.provider ?? .codex
        label = account?.label ?? ""
        email = account?.email ?? ""
        planName = account?.planName ?? "Subscription"
        usagePercent = account?.normalizedUsagePercent ?? 0
        resetsAt = account?.resetsAt
            ?? Calendar.current.date(byAdding: .month, value: 1, to: now)
            ?? now
    }

    func account(id: UUID) -> TrackedAIAccount {
        TrackedAIAccount(
            id: id,
            provider: provider,
            label: label.trimmingCharacters(in: .whitespacesAndNewlines),
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            planName: planName.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
                ? "Subscription"
                : planName.trimmingCharacters(in: .whitespacesAndNewlines),
            usagePercent: usagePercent,
            resetsAt: resetsAt,
            lastCheckedAt: nil,
            isConnected: lifecycleSource?.isConnected ?? false,
            lifetimeTokens: lifecycleSource?.lifetimeTokens,
            lastSuccessfulRefreshAt:
                lifecycleSource?.lastSuccessfulRefreshAt,
            lastRefreshAttemptAt: lifecycleSource?.lastRefreshAttemptAt,
            lastRefreshCompletedAt:
                lifecycleSource?.lastRefreshCompletedAt,
            lastAttemptKind: lifecycleSource?.lastAttemptKind,
            lastRefreshFailure: lifecycleSource?.lastRefreshFailure
        )
    }

    /// Applies only fields changed in the editor to the latest live record.
    /// Untouched provider data and the entire freshness lifecycle survive a
    /// refresh that completes while the editor is open.
    func merging(into current: TrackedAIAccount) -> TrackedAIAccount {
        guard let baseline = lifecycleSource, baseline.id == current.id else {
            return account(id: current.id)
        }
        var merged = current
        if provider != baseline.provider { merged.provider = provider }
        if label != baseline.label {
            merged.label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if email != baseline.email {
            merged.email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if planName != baseline.planName {
            let normalized = planName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            merged.planName = normalized.isEmpty ? "Subscription" : normalized
        }
        if usagePercent != baseline.normalizedUsagePercent {
            merged.usagePercent = usagePercent
        }
        if resetsAt != baseline.resetsAt { merged.resetsAt = resetsAt }
        return merged
    }
}

enum AccountConnectionActivity: Equatable {
    case idle
    case refreshing
    case signingIn
    case failed(String)

    var isWorking: Bool {
        self == .refreshing || self == .signingIn
    }
}

struct AccountConnectionOperation: Equatable {
    let generation: UUID
    let activity: AccountConnectionActivity

    func visibleActivity(
        isGenerationCurrent: Bool
    ) -> AccountConnectionActivity {
        activity.isWorking && !isGenerationCurrent ? .idle : activity
    }

    func belongs(to generation: UUID) -> Bool {
        self.generation == generation
    }
}

struct CorporateAccountIsolationPresentation: Equatable, Sendable {
    let disconnectedDetail: String
    let capabilityDetail: String
    let sharedIdentityWarning: CorporateSharedIdentityWarning?

    init(provider: AIProvider) {
        switch provider {
        case .codex:
            disconnectedDetail = String(
                localized:
                    "Parallax uses an account-specific Codex login home for this tracked account."
            )
            capabilityDetail = String(
                localized:
                    "Codex uses its official local app-server with an account-specific Parallax login home for ChatGPT sign-in and live limits."
            )
            sharedIdentityWarning = nil
        case .claude:
            disconnectedDetail = String(
                localized:
                    "Parallax uses this Mac’s current Claude Code sign-in; this record does not create a separate Claude identity."
            )
            capabilityDetail = String(
                localized:
                    "Claude uses this Mac’s current Claude Code sign-in. Multiple Claude records do not create independent logins, and Anthropic does not expose plan usage through a supported third-party endpoint."
            )
            sharedIdentityWarning = CorporateSharedIdentityWarning(
                title: String(
                    localized: "Change this Mac’s Claude Code sign-in?"
                ),
                message: String(
                    localized:
                        "Continuing changes this Mac’s ambient Claude Code identity, which Claude Code and every Claude record in Parallax share. It does not create a separate account session."
                ),
                continueTitle: String(
                    localized: "Continue to Claude Sign-In"
                )
            )
        }
    }
}

struct CorporateSharedIdentityWarning: Equatable, Sendable {
    let title: String
    let message: String
    let continueTitle: String
}

struct CorporateAccountMetadataPresentation: Equatable, Sendable {
    let planName: String?
    let resetsAt: Date?
    let hasCurrentUsage: Bool
    let retainedUsagePercent: Int?
    let freshness: CorporateAccountFreshnessState

    init(
        account: TrackedAIAccount,
        now: Date = Date(),
        ageThreshold: TimeInterval =
            CorporateAccountFreshnessPolicy.currentAgeThreshold
    ) {
        freshness = CorporateAccountFreshnessPolicy.state(
            for: account,
            now: now,
            ageThreshold: ageThreshold
        )
        if account.provider == .codex,
            account.lastSuccessfulRefreshAt != nil,
            !freshness.isCurrent
        {
            retainedUsagePercent = account.normalizedUsagePercent
        } else {
            retainedUsagePercent = nil
        }

        guard account.isConnected == true, freshness.isCurrent else {
            planName = nil
            resetsAt = nil
            hasCurrentUsage = false
            return
        }

        if account.provider == .codex {
            let trimmedPlan = account.planName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            planName = trimmedPlan.isEmpty || trimmedPlan == "Subscription"
                ? nil
                : trimmedPlan
        } else {
            planName = nil
        }

        // TrackedAIAccount predates live provider connections and always stores
        // a reset date. Without provenance, that value may still be its locally
        // invented fallback even after a refresh that returned no reset.
        resetsAt = nil
        hasCurrentUsage = account.provider == .codex
    }
}

enum CorporateAccountStatusTone: Equatable, Sendable {
    case secondary
    case available
    case attention
}

struct CorporateAccountStatusPresentation: Equatable, Sendable {
    let label: String
    let tone: CorporateAccountStatusTone
    let activityTitle: String
    let accessibilityLabel: String

    init(account: TrackedAIAccount, now: Date = Date()) {
        let metadata = CorporateAccountMetadataPresentation(
            account: account,
            now: now
        )

        switch metadata.freshness {
        case let .failed(_, _, failure):
            if failure == .authenticationRequired {
                label = String(localized: "Sign-in required")
                activityTitle = String(
                    localized: "Sign-in required for \(account.label)"
                )
                accessibilityLabel = String(
                    localized: "Sign-in required for \(account.label)"
                )
            } else if account.lastAttemptKind == .signIn {
                label = String(localized: "Sign-in failed")
                activityTitle = String(
                    localized: "Sign-in failed for \(account.label)"
                )
                accessibilityLabel = String(
                    localized: "Sign-in failed for \(account.label)"
                )
            } else {
                label = failure == .incompleteProviderData
                    ? String(localized: "Usage unavailable")
                    : String(localized: "Refresh failed")
                activityTitle = String(
                    localized: "Refresh failed for \(account.label)"
                )
                accessibilityLabel = String(
                    localized: "Refresh failed for \(account.label)"
                )
            }
            tone = .attention
            return
        case .stale:
            label = String(localized: "Stale")
            tone = .secondary
            activityTitle = String(
                localized: "Provider data is stale for \(account.label)"
            )
            accessibilityLabel = String(
                localized: "Provider data is stale for \(account.label)"
            )
            return
        case .neverRefreshed:
            if account.isConnected == true {
                label = String(localized: "Never refreshed")
                tone = .secondary
                activityTitle = String(
                    localized: "Provider status has not refreshed for \(account.label)"
                )
                accessibilityLabel = String(
                    localized: "Provider status has never refreshed for \(account.label)"
                )
                return
            }
        case .current:
            break
        }

        guard account.isConnected == true else {
            label = String(localized: "Not connected")
            tone = .secondary
            activityTitle = String(
                localized: "Provider status checked for \(account.label)"
            )
            accessibilityLabel = String(
                localized: "Not connected: \(account.label)"
            )
            return
        }

        if account.provider == .claude {
            label = String(localized: "Authenticated")
            tone = .available
            activityTitle = String(
                localized: "Authentication status refreshed for \(account.label)"
            )
            accessibilityLabel = String(
                localized: "Authenticated: \(account.label)"
            )
        } else if !metadata.hasCurrentUsage {
            label = String(localized: "Refresh needed")
            tone = .secondary
            activityTitle = String(
                localized: "Provider status refreshed for \(account.label)"
            )
            accessibilityLabel = String(
                localized: "Refresh needed for \(account.label)"
            )
        } else if account.normalizedUsagePercent >= 100 {
            label = String(localized: "Limit reached")
            tone = .attention
            activityTitle = String(
                localized: "Usage synced for \(account.label)"
            )
            accessibilityLabel = String(
                localized: "Limit reached for \(account.label)"
            )
        } else if account.needsAttention {
            label = String(localized: "Running low")
            tone = .attention
            activityTitle = String(
                localized: "Usage synced for \(account.label)"
            )
            accessibilityLabel = String(
                localized: "Running low: \(account.label)"
            )
        } else {
            label = String(localized: "Available")
            tone = .available
            activityTitle = String(
                localized: "Usage synced for \(account.label)"
            )
            accessibilityLabel = String(
                localized: "Available: \(account.label)"
            )
        }
    }
}

struct CorporateAccountUsageAggregation: Equatable, Sendable {
    let currentUsageAccounts: [TrackedAIAccount]

    init(accounts: [TrackedAIAccount], now: Date = Date()) {
        currentUsageAccounts = accounts.filter {
            CorporateAccountMetadataPresentation(account: $0, now: now)
                .hasCurrentUsage
        }
    }

    var availableAccounts: [TrackedAIAccount] {
        currentUsageAccounts.filter { !$0.needsAttention }
    }

    var nearLimitAccounts: [TrackedAIAccount] {
        currentUsageAccounts
            .filter(\.needsAttention)
            .sorted {
                $0.normalizedUsagePercent > $1.normalizedUsagePercent
            }
    }

    var averageUsagePercent: Int? {
        guard !currentUsageAccounts.isEmpty else { return nil }
        return currentUsageAccounts.reduce(0) {
            $0 + $1.normalizedUsagePercent
        } / currentUsageAccounts.count
    }
}

struct CorporateAccountRefreshApplication: Equatable, Sendable {
    let account: TrackedAIAccount
    let failure: TrackedAccountRefreshFailure?

    init(status: ConnectedAIAccountStatus, account: TrackedAIAccount) {
        var updated = account
        updated.isConnected = true
        if let email = status.email, !email.isEmpty {
            updated.email = email
        }

        switch account.provider {
        case .claude:
            // Claude's status field is an authentication method, not a paid
            // plan or subscription name.
            updated.lifetimeTokens = nil
            self.account = updated
            failure = nil
        case .codex:
            guard let usagePercent = status.usagePercent else {
                self.account = updated
                failure = .incompleteProviderData
                return
            }
            updated.usagePercent = usagePercent
            if let planName = status.planName, !planName.isEmpty {
                updated.planName = planName.capitalized
            }
            if let resetsAt = status.resetsAt {
                updated.resetsAt = resetsAt
            }
            updated.lifetimeTokens = status.lifetimeTokens
            self.account = updated
            failure = nil
        }
    }
}

private enum ClaudeSignInTarget {
    case newAccount
    case existing(TrackedAIAccount)
}

private struct CorporateAccountTrackerView: View {
    @Bindable var store: CorporateUsageStore
    @State private var editorContext: AccountEditorContext?
    @State private var accountPendingRemoval: TrackedAIAccount?
    @State private var pendingClaudeSignIn: ClaudeSignInTarget?
    @State private var connectionActivity:
        [UUID: AccountConnectionOperation] = [:]

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
                            requestAddAndConnect(.claude)
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
                        label: "Claude accounts",
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
                                    Text("\(accounts.count) \(accounts.count == 1 ? "account" : "accounts")")
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
            await refreshConnectedAccounts()
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
                store.removeTrackedAccount(id: account.id)
                connectionActivity.removeValue(forKey: account.id)
                accountPendingRemoval = nil
            }
            Button("Cancel", role: .cancel) {
                accountPendingRemoval = nil
            }
        } message: { account in
            Text("This removes only the local tracking record for \(account.label). It does not change the provider account.")
        }
        .alert(
            claudeSignInWarning.title,
            isPresented: Binding(
                get: { pendingClaudeSignIn != nil },
                set: { if !$0 { pendingClaudeSignIn = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) {
                pendingClaudeSignIn = nil
            }
            Button(claudeSignInWarning.continueTitle) {
                continueClaudeSignIn()
            }
        } message: {
            Text(claudeSignInWarning.message)
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
                    Text(account.email.isEmpty ? "Add account email" : account.email)
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
        } else if account.provider == .claude {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Authenticated")
                        .font(.callout.weight(.medium))
                    Text("Plan usage is available through Claude Code’s /usage screen.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(minHeight: 38)
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

    @ViewBuilder
    private func retainedUsageDetail(
        _ usagePercent: Int?,
        lastSuccessfulRefreshAt: Date?
    ) -> some View {
        if let usagePercent, let lastSuccessfulRefreshAt {
            Text(
                "Last known Codex usage: \(usagePercent)% from \(lastSuccessfulRefreshAt.formatted(.relative(presentation: .named))). Excluded from current status."
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
            return "Current Codex usage is unavailable"
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
                    Task {
                        await refresh(account)
                    }
                } else if account.provider == .claude {
                    pendingClaudeSignIn = .existing(account)
                } else {
                    Task {
                        await connect(account)
                    }
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
            .disabled(activity(for: account).isWorking)

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

    private func activity(
        for account: TrackedAIAccount
    ) -> AccountConnectionActivity {
        guard let operation = connectionActivity[account.id] else {
            return .idle
        }
        return operation.visibleActivity(
            isGenerationCurrent: store.isCurrentOperation(
                accountID: account.id,
                generation: operation.generation
            )
        )
    }

    private func setActivity(
        _ activity: AccountConnectionActivity,
        accountID: UUID,
        generation: UUID
    ) {
        connectionActivity[accountID] = AccountConnectionOperation(
            generation: generation,
            activity: activity
        )
    }

    private func finishActivity(
        accountID: UUID,
        generation: UUID,
        failureMessage: String? = nil
    ) {
        guard
            connectionActivity[accountID]?.belongs(to: generation) == true
        else {
            return
        }
        if let failureMessage {
            setActivity(
                .failed(failureMessage),
                accountID: accountID,
                generation: generation
            )
        } else {
            connectionActivity.removeValue(forKey: accountID)
        }
    }

    @MainActor
    private func connect(_ account: TrackedAIAccount) async {
        guard let generation = store.recordRefreshAttempt(
            accountID: account.id,
            kind: .signIn
        ) else { return }
        setActivity(.signingIn, accountID: account.id, generation: generation)
        do {
            let status = try await AIAccountConnectionService.login(
                provider: account.provider,
                accountID: account.id
            )
            _ = apply(status, to: account, generation: generation)
            finishActivity(accountID: account.id, generation: generation)
        } catch {
            let applied = store.recordRefreshFailure(
                accountID: account.id,
                operationGeneration: generation,
                failure: refreshFailure(for: error, attemptKind: .signIn)
            )
            if applied {
                finishActivity(
                    accountID: account.id,
                    generation: generation,
                    failureMessage: error.localizedDescription
                )
            } else {
                finishActivity(accountID: account.id, generation: generation)
            }
        }
    }

    @MainActor
    private func refresh(_ account: TrackedAIAccount) async {
        guard let generation = store.recordRefreshAttempt(
            accountID: account.id,
            kind: .refresh
        ) else { return }
        setActivity(.refreshing, accountID: account.id, generation: generation)
        do {
            let status = try await AIAccountConnectionService.refresh(
                provider: account.provider,
                accountID: account.id
            )
            _ = apply(status, to: account, generation: generation)
            finishActivity(accountID: account.id, generation: generation)
        } catch AIAccountConnectionError.notAuthenticated {
            let applied = store.recordRefreshFailure(
                accountID: account.id,
                operationGeneration: generation,
                failure: .authenticationRequired,
                disconnect: true
            )
            _ = applied
            finishActivity(accountID: account.id, generation: generation)
        } catch {
            let applied = store.recordRefreshFailure(
                accountID: account.id,
                operationGeneration: generation,
                failure: refreshFailure(for: error, attemptKind: .refresh)
            )
            if applied {
                finishActivity(
                    accountID: account.id,
                    generation: generation,
                    failureMessage: error.localizedDescription
                )
            } else {
                finishActivity(accountID: account.id, generation: generation)
            }
        }
    }

    @MainActor
    private func refreshConnectedAccounts() async {
        for account in store.trackedAccounts
        where account.isConnected == true || account.provider == .claude
        {
            await refresh(account)
        }
    }

    @MainActor
    private func apply(
        _ status: ConnectedAIAccountStatus,
        to account: TrackedAIAccount,
        generation: UUID
    ) -> Bool {
        guard let current = store.trackedAccounts.first(where: {
            $0.id == account.id
        }) else { return false }
        let application = CorporateAccountRefreshApplication(
            status: status,
            account: current
        )
        if let failure = application.failure {
            return store.recordRefreshFailure(
                application.account,
                operationGeneration: generation,
                failure: failure
            )
        } else {
            return store.recordRefreshSuccess(
                application.account,
                operationGeneration: generation
            )
        }
    }

    private func refreshFailure(
        for error: Error,
        attemptKind: TrackedAccountAttemptKind
    ) -> TrackedAccountRefreshFailure {
        if error is CancellationError { return .interrupted }
        switch error as? AIAccountConnectionError {
        case .notAuthenticated:
            return .authenticationRequired
        case .executableMissing:
            return .providerToolUnavailable
        case .loginFailed:
            return .signInFailed
        case .statusUnavailable, nil:
            return attemptKind == .signIn
                ? .signInFailed
                : .statusUnavailable
        }
    }

    private func accounts(for provider: AIProvider) -> [TrackedAIAccount] {
        store.trackedAccounts.filter { $0.provider == provider }
    }

    private func providerCount(_ provider: AIProvider) -> Int {
        accounts(for: provider).count
    }

    private var currentNearLimitCount: Int {
        CorporateAccountUsageAggregation(
            accounts: store.trackedAccounts,
            now: store.currentDate
        )
            .nearLimitAccounts.count
    }

    private var claudeSignInWarning: CorporateSharedIdentityWarning {
        CorporateAccountIsolationPresentation(provider: .claude)
            .sharedIdentityWarning!
    }

    @MainActor
    private func requestAddAndConnect(_ provider: AIProvider) {
        if provider == .claude {
            pendingClaudeSignIn = .newAccount
        } else {
            addAndConnect(provider)
        }
    }

    @MainActor
    private func continueClaudeSignIn() {
        let target = pendingClaudeSignIn
        pendingClaudeSignIn = nil
        switch target {
        case .newAccount:
            addAndConnect(.claude)
        case let .existing(account):
            Task { await connect(account) }
        case nil:
            break
        }
    }

    @MainActor
    private func addAndConnect(_ provider: AIProvider) {
        let account = store.addTrackedAccount(provider: provider)
        Task { await connect(account) }
    }
}

private struct TrackedAccountEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CorporateUsageStore
    let context: AccountEditorContext

    @State private var provider: AIProvider
    @State private var label: String
    @State private var email: String
    @State private var planName: String
    @State private var usagePercent: Int
    @State private var resetsAt: Date

    init(store: CorporateUsageStore, context: AccountEditorContext) {
        self.store = store
        self.context = context
        let draft = TrackedAccountEditorDraft(account: context.account)
        _provider = State(initialValue: draft.provider)
        _label = State(initialValue: draft.label)
        _email = State(initialValue: draft.email)
        _planName = State(initialValue: draft.planName)
        _usagePercent = State(initialValue: draft.usagePercent)
        _resetsAt = State(initialValue: draft.resetsAt)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(context.account == nil ? "Add account" : "Update account")
                    .font(.title2.weight(.semibold))
                Text("Keep a local record of this subscription's current usage.")
                    .foregroundStyle(.secondary)
            }
            .padding(22)

            Divider()

            Form {
                Section("Account") {
                    Picker("Provider", selection: $provider) {
                        ForEach(AIProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    TextField("Label", text: $label)
                    TextField("Email", text: $email)
                    TextField("Plan", text: $planName)
                }

                Section("Fallback usage") {
                    Stepper(value: $usagePercent, in: 0...100, step: 5) {
                        HStack {
                            Text("Used")
                            Spacer()
                            Text("\(usagePercent)%")
                                .font(.title3.monospacedDigit().weight(.semibold))
                        }
                    }
                    ProgressView(value: Double(usagePercent), total: 100)
                        .tint(usagePercent >= 85 ? .orange : .accentColor)
                    DatePicker(
                        "Usage resets",
                        selection: $resetsAt,
                        displayedComponents: [.date]
                    )
                }

                Section {
                    Label(
                        "Provider refreshes replace this fallback percentage when live usage is available.",
                        systemImage: "lock.macwindow"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save account") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(18)
        }
        .frame(width: 520, height: 590)
    }

    private func save() {
        var draft = TrackedAccountEditorDraft(account: context.account)
        draft.provider = provider
        draft.label = label
        draft.email = email
        draft.planName = planName
        draft.usagePercent = usagePercent
        draft.resetsAt = resetsAt
        if context.account != nil {
            guard let current = store.trackedAccounts.first(where: {
                $0.id == context.id
            }) else {
                dismiss()
                return
            }
            store.saveTrackedAccount(draft.merging(into: current))
        } else {
            store.saveTrackedAccount(draft.account(id: context.id))
        }
        dismiss()
    }
}

private struct AccountSummaryCard: View {
    let value: String
    let label: String
    let systemImage: String
    let tone: Color

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                .foregroundStyle(tone)
                .frame(width: 34, height: 34)
                .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .corporateCard()
        .frame(maxWidth: .infinity)
    }
}

private struct AccountStatusPill: View {
    let account: TrackedAIAccount
    let now: Date

    var body: some View {
        Text(presentation.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.1), in: Capsule())
            .accessibilityLabel(presentation.accessibilityLabel)
    }

    private var presentation: CorporateAccountStatusPresentation {
        CorporateAccountStatusPresentation(account: account, now: now)
    }

    private var statusColor: Color {
        switch presentation.tone {
        case .secondary: .secondary
        case .available: .green
        case .attention: .orange
        }
    }
}

private struct AccountTrackingNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.tap")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Secure provider sign-in")
                    .font(.callout.weight(.semibold))
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(
                            CorporateAccountIsolationPresentation(
                                provider: provider
                            ).capabilityDetail
                        )
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct LiveAccountOverviewView: View {
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
                    AccountSummaryCard(
                        value: "\(store.trackedAccounts.count)",
                        label: "Accounts tracked",
                        systemImage: "person.crop.rectangle.stack",
                        tone: .blue
                    )
                    AccountSummaryCard(
                        value: "\(connectedAccounts.count)",
                        label: "Connected",
                        systemImage: "checkmark.shield",
                        tone: .green
                    )
                    AccountSummaryCard(
                        value: "\(availableCodexAccounts.count)",
                        label: "Codex available",
                        systemImage: "gauge.with.dots.needle.33percent",
                        tone: .blue
                    )
                    AccountSummaryCard(
                        value: "\(accountsNearLimit.count)",
                        label: "Near a limit",
                        systemImage: "exclamationmark.triangle",
                        tone: .orange
                    )
                }

                AccountTrackingNotice()

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

private struct LiveAccountPeopleView: View {
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

private struct LiveAccountProvidersView: View {
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
                    "Claude authenticates here, but Anthropic does not expose subscription usage to third-party apps.",
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

private struct LiveAccountActivityView: View {
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
            AccountStatusPill(account: account, now: now)
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

private struct ProviderMark: View {
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
