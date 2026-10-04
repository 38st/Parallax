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
    var libraryStore: LibraryStore? = nil
    var recreateCodexSpaces: (() -> Void)? = nil
    @State private var editorContext: AccountEditorContext?
    @State private var accountPendingRemoval: TrackedAIAccount?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let message = store.persistenceErrorMessage {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
                if let message = operationCoordinator.admissionMessage {
                    Label(message, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Usage connections")
                            .font(.largeTitle.weight(.semibold))
                        Text(
                            "Connect CLI tools to read usage. Desktop sign-ins stay inside their apps."
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
                        if let recreateCodexSpaces {
                            Button("Recreate Codex Local Spaces", action: recreateCodexSpaces)
                                .disabled(!store.trackedAccounts.contains { $0.provider == .codex && $0.isSignedIn })
                            Divider()
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
                        Label("Add usage connection", systemImage: "plus")
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
        .navigationTitle("Usage connections")
        .task {
            await operationCoordinator.refreshDueAccounts()
        }
        .sheet(item: $editorContext) { context in
            TrackedAccountEditorView(store: store, context: context)
                .safeAreaInset(edge: .bottom) {
                    if let libraryStore { SpaceOperationStatusView(store: libraryStore).padding() }
                }
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

            // A closed browser tab must not hold the sign-in, and the Codex
            // sign-in slot, for the whole provider timeout.
            if activity(for: account) == .signingIn {
                Button("Cancel") {
                    operationCoordinator.cancelOperations(accountID: account.id)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancel sign-in for \(account.label)")
            }

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
