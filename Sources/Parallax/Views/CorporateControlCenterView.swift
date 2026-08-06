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

private struct TransferDraft: Identifiable {
    let id = UUID()
    var provider: AIProvider
    var sourceMemberID: UUID?
    var destinationMemberID: UUID?
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

private enum AccountConnectionActivity: Equatable {
    case idle
    case refreshing
    case signingIn
    case failed(String)

    var isWorking: Bool {
        self == .refreshing || self == .signingIn
    }
}

private struct CorporateAccountTrackerView: View {
    @Bindable var store: CorporateUsageStore
    @State private var editorContext: AccountEditorContext?
    @State private var accountPendingRemoval: TrackedAIAccount?
    @State private var connectionActivity:
        [UUID: AccountConnectionActivity] = [:]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("AI accounts")
                            .font(.largeTitle.weight(.semibold))
                        Text("Track every subscription and know which account has room.")
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
                        value: "\(store.trackedAccounts.filter(\.needsAttention).count)",
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
        VStack(alignment: .leading, spacing: 14) {
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
                AccountStatusPill(account: account)
            }

            accountUsage(account)

            HStack {
                Label(account.planName, systemImage: "creditcard")
                Spacer()
                Label(
                    "Resets \(account.resetsAt, format: .dateTime.month(.abbreviated).day())",
                    systemImage: "calendar"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)

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
        if account.isConnected != true {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Sign in to load usage")
                        .font(.callout.weight(.medium))
                    Text("Parallax keeps a separate login for this account.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .frame(minHeight: 38)
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

    private func accountActions(_ account: TrackedAIAccount) -> some View {
        HStack {
            if let lastCheckedAt = account.lastCheckedAt {
                Text("Synced \(lastCheckedAt, format: .relative(presentation: .named))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("Not connected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            Button {
                Task {
                    if account.isConnected == true {
                        await refresh(account)
                    } else {
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
        connectionActivity[account.id] ?? .idle
    }

    @MainActor
    private func connect(_ account: TrackedAIAccount) async {
        connectionActivity[account.id] = .signingIn
        do {
            let status = try await AIAccountConnectionService.login(
                provider: account.provider,
                accountID: account.id
            )
            apply(status, to: account)
            connectionActivity[account.id] = .idle
        } catch {
            connectionActivity[account.id] = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func refresh(_ account: TrackedAIAccount) async {
        connectionActivity[account.id] = .refreshing
        do {
            let status = try await AIAccountConnectionService.refresh(
                provider: account.provider,
                accountID: account.id
            )
            apply(status, to: account)
            connectionActivity[account.id] = .idle
        } catch AIAccountConnectionError.notAuthenticated {
            var updated = account
            updated.isConnected = false
            store.saveTrackedAccount(updated)
            connectionActivity[account.id] = .idle
        } catch {
            connectionActivity[account.id] = .failed(error.localizedDescription)
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
        to account: TrackedAIAccount
    ) {
        var updated = account
        updated.isConnected = true
        if let email = status.email, !email.isEmpty {
            updated.email = email
        }
        if let planName = status.planName, !planName.isEmpty {
            updated.planName = planName.capitalized
        }
        if let usagePercent = status.usagePercent {
            updated.usagePercent = usagePercent
        }
        if let resetsAt = status.resetsAt {
            updated.resetsAt = resetsAt
        }
        updated.lifetimeTokens = status.lifetimeTokens
        updated.lastCheckedAt = Date()
        store.saveTrackedAccount(updated)
    }

    private func accounts(for provider: AIProvider) -> [TrackedAIAccount] {
        store.trackedAccounts.filter { $0.provider == provider }
    }

    private func providerCount(_ provider: AIProvider) -> Int {
        accounts(for: provider).count
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
        let account = context.account
        _provider = State(initialValue: account?.provider ?? .codex)
        _label = State(initialValue: account?.label ?? "")
        _email = State(initialValue: account?.email ?? "")
        _planName = State(initialValue: account?.planName ?? "Subscription")
        _usagePercent = State(initialValue: account?.normalizedUsagePercent ?? 0)
        _resetsAt = State(
            initialValue: account?.resetsAt
                ?? Calendar.current.date(byAdding: .month, value: 1, to: Date())
                ?? Date()
        )
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
        store.saveTrackedAccount(
            TrackedAIAccount(
                id: context.id,
                provider: provider,
                label: label.trimmingCharacters(in: .whitespacesAndNewlines),
                email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                planName: planName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Subscription"
                    : planName.trimmingCharacters(in: .whitespacesAndNewlines),
                usagePercent: usagePercent,
                resetsAt: resetsAt,
                lastCheckedAt: context.account?.lastCheckedAt,
                isConnected: context.account?.isConnected ?? false,
                lifetimeTokens: context.account?.lifetimeTokens
            )
        )
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

    var body: some View {
        Text(statusLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.1), in: Capsule())
    }

    private var statusLabel: String {
        if account.isConnected != true { return "Not connected" }
        if account.provider == .claude { return "Connected" }
        if account.normalizedUsagePercent >= 100 { return "Limit reached" }
        if account.needsAttention { return "Running low" }
        if account.lastCheckedAt == nil { return "Set usage" }
        return "Available"
    }

    private var statusColor: Color {
        if account.isConnected != true { return .secondary }
        return account.needsAttention ? .orange : .green
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
                Text("Codex uses its official local app-server for ChatGPT login and live limits. Claude uses the installed Claude Code login; Anthropic does not expose plan usage through a supported third-party endpoint.")
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
        connectedAccounts.filter {
            $0.provider == .codex && !$0.needsAttention
        }
    }

    private var accountsNearLimit: [TrackedAIAccount] {
        connectedAccounts
            .filter(\.needsAttention)
            .sorted { $0.normalizedUsagePercent > $1.normalizedUsagePercent }
    }

    private var recentlySyncedAccounts: [TrackedAIAccount] {
        store.trackedAccounts
            .filter { $0.lastCheckedAt != nil }
            .sorted {
                ($0.lastCheckedAt ?? .distantPast)
                    > ($1.lastCheckedAt ?? .distantPast)
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
                    LiveAccountRow(account: account)
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
                "Recent syncs",
                subtitle: "Latest provider data loaded by Parallax"
            )
            .padding(18)
            Divider()

            if recentlySyncedAccounts.isEmpty {
                ContentUnavailableView(
                    "Nothing synced yet",
                    systemImage: "arrow.clockwise",
                    description: Text("Sign in to an account to load provider data.")
                )
                .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                ForEach(Array(recentlySyncedAccounts.prefix(4).enumerated()), id: \.element.id) { index, account in
                    LiveAccountRow(account: account, showsSyncTime: true)
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
                        LiveAccountRow(account: account, showsPlan: true)
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
        let nearLimit = connected.filter(\.needsAttention)
        let averageUsage = connected.isEmpty || provider == .claude
            ? nil
            : connected.reduce(0) { $0 + $1.normalizedUsagePercent }
                / connected.count

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
                ProviderStat(value: "\(nearLimit.count)", label: "Near limit")
                ProviderStat(
                    value: averageUsage.map { "\($0)%" } ?? "—",
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
                LiveAccountRow(account: account, showsPlan: true)
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
                Text("Provider syncs recorded from tracked accounts.")
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
                                    Text("Usage synced for \(account.label)")
                                        .font(.callout.weight(.medium))
                                    Text(account.email.isEmpty ? account.provider.displayName : account.email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if let checkedAt = account.lastCheckedAt {
                                    Text(checkedAt, format: .relative(presentation: .named))
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
            .filter { $0.lastCheckedAt != nil }
            .sorted {
                ($0.lastCheckedAt ?? .distantPast)
                    > ($1.lastCheckedAt ?? .distantPast)
            }
    }
}

private struct LiveAccountRow: View {
    let account: TrackedAIAccount
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
            if account.provider == .codex, account.isConnected == true {
                Text("\(account.normalizedUsagePercent)%")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(account.needsAttention ? Color.orange : Color.secondary)
            }
            AccountStatusPill(account: account)
        }
    }

    private var detail: String {
        if showsSyncTime, let checkedAt = account.lastCheckedAt {
            return "\(account.provider.displayName) · Synced \(checkedAt.formatted(.relative(presentation: .named)))"
        }
        if showsPlan {
            return "\(account.label) · \(account.provider.displayName) · \(account.planName)"
        }
        return "\(account.provider.displayName) · \(account.label)"
    }
}

private struct CorporateOverviewView: View {
    @Bindable var store: CorporateUsageStore
    let beginTransfer: (TransferDraft) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                overviewHeader
                ProviderCapabilityNotice()
                summaryGrid

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeading(
                        "Provider pools",
                        subtitle: "Purchased seats and current organization-wide usage"
                    )
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(store.providerPools) { pool in
                            ProviderPoolCard(
                                store: store,
                                pool: pool,
                                beginTransfer: beginTransfer
                            )
                        }
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        attentionCard
                        recentActivityCard
                    }
                    VStack(spacing: 14) {
                        attentionCard
                        recentActivityCard
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 1180, alignment: .leading)
        }
        .navigationTitle("Control Center")
    }

    private var overviewHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Good morning")
                    .font(.largeTitle.weight(.semibold))
                Text("Balance AI access before your team reaches a limit.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("CURRENT CYCLE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("Ends \(store.cycleEndsAt, format: .dateTime.month(.abbreviated).day())")
                    .font(.callout.weight(.medium))
            }
            .padding(.top, 6)
        }
    }

    private var summaryGrid: some View {
        HStack(spacing: 12) {
            SummaryMetricCard(
                title: "Members at risk",
                value: "\(store.membersAtRiskCount)",
                detail: "Likely to hit a limit",
                systemImage: "bolt.trianglebadge.exclamationmark",
                tone: .orange
            )
            SummaryMetricCard(
                title: "Reclaimable",
                value: "\(store.totalReclaimableCapacity) pts",
                detail: "Available from light users",
                systemImage: "arrow.left.arrow.right",
                tone: .blue
            )
            SummaryMetricCard(
                title: "Reserve seats",
                value: "\(store.providerPools.reduce(0) { $0 + $1.reserveSeats })",
                detail: "Across both providers",
                systemImage: "person.badge.plus",
                tone: .green
            )
        }
    }

    private var attentionCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading(
                "Needs attention",
                subtitle: "Heavy users with reclaimable capacity available"
            )
            .padding(18)

            Divider()

            let risks = riskRows
            if risks.isEmpty {
                ContentUnavailableView(
                    "Everyone is covered",
                    systemImage: "checkmark.circle",
                    description: Text("No one is close to a managed limit.")
                )
                .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                ForEach(Array(risks.prefix(4).enumerated()), id: \.offset) { index, risk in
                    Button {
                        let source = store.reclaimableMembers(for: risk.provider).first
                        beginTransfer(
                            TransferDraft(
                                provider: risk.provider,
                                sourceMemberID: source?.id,
                                destinationMemberID: risk.member.id
                            )
                        )
                    } label: {
                        HStack(spacing: 12) {
                            MemberAvatar(name: risk.member.name)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(risk.member.name)
                                    .foregroundStyle(.primary)
                                    .fontWeight(.medium)
                                Text("\(risk.provider.displayName) · \(risk.member.team)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            UsagePill(usage: risk.usage)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if index < min(risks.count, 4) - 1 {
                        Divider().padding(.leading, 62)
                    }
                }
            }
        }
        .corporateCard()
        .frame(maxWidth: .infinity)
    }

    private var recentActivityCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeading(
                "Recent changes",
                subtitle: "Every capacity move is recorded"
            )
            .padding(18)
            Divider()

            if store.transfers.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("No transfers yet")
                        .font(.headline)
                    Text("Your first reallocation will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 190)
            } else {
                ForEach(Array(store.transfers.prefix(4).enumerated()), id: \.element.id) { index, transfer in
                    TransferActivityRow(transfer: transfer)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                    if index < min(store.transfers.count, 4) - 1 {
                        Divider().padding(.leading, 52)
                    }
                }
            }
        }
        .corporateCard()
        .frame(maxWidth: .infinity)
    }

    private var riskRows: [(member: CorporateMember, provider: AIProvider, usage: CorporateSeatUsage)] {
        AIProvider.allCases.flatMap { provider in
            store.atRiskMembers(for: provider).map { member in
                (member, provider, member.usage(for: provider))
            }
        }
        .sorted { $0.usage.utilization > $1.usage.utilization }
    }
}

private struct CorporatePeopleView: View {
    @Bindable var store: CorporateUsageStore
    let beginTransfer: (TransferDraft) -> Void
    @State private var searchText = ""
    @State private var teamFilter = "All teams"

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("People")
                        .font(.largeTitle.weight(.semibold))
                    Text("See who has room and who needs more capacity.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    beginTransfer(
                        TransferDraft(
                            provider: .claude,
                            sourceMemberID: nil,
                            destinationMemberID: nil
                        )
                    )
                } label: {
                    Label("Transfer capacity", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(28)

            HStack(spacing: 12) {
                TextField("Search people", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 320)
                Picker("Team", selection: $teamFilter) {
                    Text("All teams").tag("All teams")
                    ForEach(teams, id: \.self) { Text($0).tag($0) }
                }
                .frame(width: 190)
                Spacer()
                Text("\(filteredMembers.count) people")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 14)

            ScrollView {
                LazyVStack(spacing: 0) {
                    peopleTableHeader
                    ForEach(filteredMembers) { member in
                        Divider()
                        memberRow(member)
                    }
                }
                .corporateCard()
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("People")
    }

    private var peopleTableHeader: some View {
        HStack(spacing: 14) {
            Text("PERSON").frame(maxWidth: .infinity, alignment: .leading)
            Text("CLAUDE").frame(width: 180, alignment: .leading)
            Text("CODEX").frame(width: 180, alignment: .leading)
            Color.clear.frame(width: 28)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func memberRow(_ member: CorporateMember) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 10) {
                MemberAvatar(name: member.name)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.name).fontWeight(.medium)
                    Text("\(member.role) · \(member.team)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            MemberUsageCell(usage: member.claude)
                .frame(width: 180)
            MemberUsageCell(usage: member.codex)
                .frame(width: 180)

            Menu {
                ForEach(AIProvider.allCases) { provider in
                    Button("Move \(provider.displayName) capacity…") {
                        beginTransfer(
                            TransferDraft(
                                provider: provider,
                                sourceMemberID: nil,
                                destinationMemberID: member.id
                            )
                        )
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Actions for \(member.name)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var teams: [String] {
        Array(Set(store.members.map(\.team))).sorted()
    }

    private var filteredMembers: [CorporateMember] {
        store.members.filter { member in
            let matchesTeam = teamFilter == "All teams" || member.team == teamFilter
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            let matchesSearch = query.isEmpty
                || member.name.localizedCaseInsensitiveContains(query)
                || member.email.localizedCaseInsensitiveContains(query)
                || member.team.localizedCaseInsensitiveContains(query)
            return matchesTeam && matchesSearch
        }
    }
}

private struct CorporateProvidersView: View {
    @Bindable var store: CorporateUsageStore
    let beginTransfer: (TransferDraft) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Providers")
                        .font(.largeTitle.weight(.semibold))
                    Text("Keep purchased seats productive without sharing accounts.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                ProviderCapabilityNotice()

                ForEach(store.providerPools) { pool in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            ProviderMark(provider: pool.provider)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pool.provider.displayName)
                                    .font(.title2.weight(.semibold))
                                Text(pool.provider.shortDescription)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Rebalance…") {
                                let source = store.reclaimableMembers(for: pool.provider).first
                                let destination = store.atRiskMembers(for: pool.provider).first
                                beginTransfer(
                                    TransferDraft(
                                        provider: pool.provider,
                                        sourceMemberID: source?.id,
                                        destinationMemberID: destination?.id
                                    )
                                )
                            }
                            .buttonStyle(.borderedProminent)
                        }

                        HStack(spacing: 24) {
                            ProviderStat(value: "\(pool.purchasedSeats)", label: "Purchased")
                            ProviderStat(value: "\(pool.assignedSeats)", label: "Assigned")
                            ProviderStat(value: "\(pool.reserveSeats)", label: "Reserve")
                            ProviderStat(value: "\(pool.capacityUsedPercent)%", label: "Capacity used")
                            Spacer()
                        }

                        Divider()

                        HStack(alignment: .top, spacing: 24) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Likely to hit limit")
                                    .font(.headline)
                                ForEach(store.atRiskMembers(for: pool.provider).prefix(3)) { member in
                                    HStack {
                                        MemberAvatar(name: member.name, size: 28)
                                        Text(member.name)
                                        Spacer()
                                        UsagePill(usage: member.usage(for: pool.provider))
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)

                            VStack(alignment: .leading, spacing: 8) {
                                Text("Capacity available")
                                    .font(.headline)
                                ForEach(store.reclaimableMembers(for: pool.provider).prefix(3)) { member in
                                    HStack {
                                        MemberAvatar(name: member.name, size: 28)
                                        Text(member.name)
                                        Spacer()
                                        Text("\(member.usage(for: pool.provider).reclaimableCapacity) pts")
                                            .font(.caption.weight(.medium))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(20)
                    .corporateCard()
                }

                autoRebalanceCard
            }
            .padding(28)
            .frame(maxWidth: 1050, alignment: .leading)
        }
        .navigationTitle("Providers")
    }

    private var autoRebalanceCard: some View {
        HStack(spacing: 16) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text("Automatic recommendations")
                    .font(.headline)
                Text("Flag capacity that has been idle and prepare a reviewable rebalancing plan. Changes still require admin approval.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "Automatic recommendations",
                isOn: Binding(
                    get: { store.autoRebalanceEnabled },
                    set: { store.setAutoRebalanceEnabled($0) }
                )
            )
            .labelsHidden()
        }
        .padding(18)
        .corporateCard()
    }
}

private struct CorporateActivityView: View {
    @Bindable var store: CorporateUsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Activity")
                    .font(.largeTitle.weight(.semibold))
                Text("An audit trail of every approved capacity change.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .padding(28)

            if store.transfers.isEmpty {
                ContentUnavailableView(
                    "No capacity transfers",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Approved changes will be recorded here with their source and destination.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(store.transfers.enumerated()), id: \.element.id) { index, transfer in
                            TransferActivityRow(transfer: transfer)
                                .padding(16)
                            if index < store.transfers.count - 1 { Divider() }
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
}

private struct CapacityTransferView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var store: CorporateUsageStore
    let draft: TransferDraft

    @State private var provider: AIProvider
    @State private var sourceMemberID: UUID?
    @State private var destinationMemberID: UUID?
    @State private var capacity = 10
    @State private var errorMessage: String?

    init(store: CorporateUsageStore, draft: TransferDraft) {
        self.store = store
        self.draft = draft
        _provider = State(initialValue: draft.provider)
        _sourceMemberID = State(initialValue: draft.sourceMemberID)
        _destinationMemberID = State(initialValue: draft.destinationMemberID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transfer capacity")
                        .font(.title2.weight(.semibold))
                    Text("Move unused internal capacity to someone who needs it.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .padding(22)

            Divider()

            Form {
                Section("Provider") {
                    Picker("Provider", selection: $provider) {
                        ForEach(AIProvider.allCases) { provider in
                            Label(provider.displayName, systemImage: provider.systemImage)
                                .tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: provider) {
                        sourceMemberID = store.reclaimableMembers(for: provider).first?.id
                        destinationMemberID = store.atRiskMembers(for: provider).first?.id
                        capacity = 10
                    }
                }

                Section("From") {
                    Picker("Light user", selection: $sourceMemberID) {
                        Text("Choose a person").tag(nil as UUID?)
                        ForEach(store.reclaimableMembers(for: provider)) { member in
                            Text("\(member.name) · \(member.usage(for: provider).reclaimableCapacity) available")
                                .tag(member.id as UUID?)
                        }
                    }
                }

                Section("To") {
                    Picker("Heavy user", selection: $destinationMemberID) {
                        Text("Choose a person").tag(nil as UUID?)
                        ForEach(store.members.filter { $0.id != sourceMemberID }) { member in
                            Text("\(member.name) · \(Int(member.usage(for: provider).utilization * 100))% used")
                                .tag(member.id as UUID?)
                        }
                    }
                }

                Section("Amount") {
                    Stepper(value: $capacity, in: 5...maxTransfer, step: 5) {
                        HStack {
                            Text("Capacity points")
                            Spacer()
                            Text("\(capacity)")
                                .font(.title3.monospacedDigit().weight(.semibold))
                        }
                    }
                    ProgressView(
                        value: Double(capacity),
                        total: Double(max(maxTransfer, 5))
                    )
                    Text("The source keeps a 10-point safety buffer above current usage.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Label(
                        "This changes Parallax's managed allocation. Provider-side enforcement requires a supported enterprise connection.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Approve transfer") { approveTransfer() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(sourceMemberID == nil || destinationMemberID == nil)
            }
            .padding(18)
        }
        .frame(width: 560, height: 620)
    }

    private var maxTransfer: Int {
        guard
            let sourceMemberID,
            let usage = store.usage(for: sourceMemberID, provider: provider)
        else { return 5 }
        return max(usage.reclaimableCapacity, 5)
    }

    private func approveTransfer() {
        guard let sourceMemberID, let destinationMemberID else { return }
        do {
            try store.transferCapacity(
                provider: provider,
                from: sourceMemberID,
                to: destinationMemberID,
                capacity: capacity
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ProviderCapabilityNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("Built for managed identities")
                    .font(.callout.weight(.semibold))
                Text("Parallax reallocates your internal budgets and eligible seats. It does not share logins or claim to override provider limits.")
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

private struct ProviderPoolCard: View {
    @Bindable var store: CorporateUsageStore
    let pool: CorporateProviderPool
    let beginTransfer: (TransferDraft) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                ProviderMark(provider: pool.provider)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pool.provider.displayName)
                        .font(.headline)
                    Text("\(pool.assignedSeats) of \(pool.purchasedSeats) seats assigned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(pool.capacityUsedPercent)%")
                    .font(.title2.monospacedDigit().weight(.semibold))
            }

            ProgressView(value: Double(pool.capacityUsedPercent), total: 100)
                .tint(pool.capacityUsedPercent >= 85 ? .orange : .accentColor)

            HStack {
                Label("\(pool.reserveSeats) reserve", systemImage: "person.badge.plus")
                Spacer()
                Label(
                    "\(store.reclaimableMembers(for: pool.provider).reduce(0) { $0 + $1.usage(for: pool.provider).reclaimableCapacity }) pts free",
                    systemImage: "arrow.down.right"
                )
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button {
                beginTransfer(
                    TransferDraft(
                        provider: pool.provider,
                        sourceMemberID: store.reclaimableMembers(for: pool.provider).first?.id,
                        destinationMemberID: store.atRiskMembers(for: pool.provider).first?.id
                    )
                )
            } label: {
                Label("Rebalance capacity", systemImage: "arrow.left.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding(18)
        .corporateCard()
        .frame(maxWidth: .infinity)
    }
}

private struct SummaryMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let systemImage: String
    let tone: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tone)
                .frame(width: 38, height: 38)
                .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .corporateCard()
        .frame(maxWidth: .infinity)
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

private struct MemberAvatar: View {
    let name: String
    var size: CGFloat = 34

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.34, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .background(Color.accentColor.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }

    private var initials: String {
        name.split(separator: " ")
            .prefix(2)
            .compactMap(\.first)
            .map(String.init)
            .joined()
    }
}

private struct UsagePill: View {
    let usage: CorporateSeatUsage

    var body: some View {
        Text("\(Int(usage.utilization * 100))%")
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(usage.isAtRisk ? Color.orange : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                (usage.isAtRisk ? Color.orange : Color.secondary).opacity(0.1),
                in: Capsule()
            )
    }
}

private struct MemberUsageCell: View {
    let usage: CorporateSeatUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(usage.consumedCapacity) / \(usage.allocatedCapacity)")
                    .font(.caption.monospacedDigit().weight(.medium))
                Spacer()
                Text("\(Int(usage.utilization * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(usage.isAtRisk ? Color.orange : Color.secondary)
            }
            ProgressView(
                value: Double(min(usage.consumedCapacity, usage.allocatedCapacity)),
                total: Double(max(usage.allocatedCapacity, 1))
            )
            .tint(usage.isAtRisk ? .orange : .accentColor)
        }
    }
}

private struct TransferActivityRow: View {
    let transfer: CapacityTransfer

    var body: some View {
        HStack(spacing: 11) {
            ProviderMark(provider: transfer.provider)
                .scaleEffect(0.86)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(transfer.capacity) points moved to \(transfer.destinationName)")
                    .font(.callout.weight(.medium))
                Text("From \(transfer.sourceName) · \(transfer.createdAt, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
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
