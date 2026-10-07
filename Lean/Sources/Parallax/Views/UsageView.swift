import SwiftUI

struct UsageView: View {
    @Bindable var model: AppModel
    @State private var addingProvider: Provider?
    @State private var renaming: UsageAccount?
    @State private var removing: UsageAccount?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Usage").font(.largeTitle.weight(.semibold))
                        Text("Read from each account's own Claude or Codex command-line login. Refreshes every 5 minutes.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await model.refreshAllAccounts(onlyIfStale: false) }
                    } label: {
                        Label("Refresh All", systemImage: "arrow.clockwise")
                    }
                    Menu {
                        ForEach(Provider.allCases, id: \.self) { provider in
                            Button("\(provider.label) Account…") { addingProvider = provider }
                        }
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .fixedSize()
                }

                if model.accounts.isEmpty {
                    ContentUnavailableView(
                        "No accounts yet",
                        systemImage: "gauge.medium",
                        description: Text("Add a Claude or Codex account to see how much of its limits you've used.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 300)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                        ForEach(model.accounts) { account in
                            AccountCard(model: model, account: account, rename: { renaming = account }, remove: { removing = account })
                        }
                    }
                }
            }
            .padding(28)
        }
        .navigationTitle("Usage")
        .sheet(item: $addingProvider) { provider in
            AddAccountSheet(model: model, provider: provider)
        }
        .sheet(item: $renaming) { account in
            RenameAccountSheet(model: model, account: account)
        }
        .confirmationDialog(
            "Remove \(removing?.label ?? "this account")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { account in
            Button("Remove", role: .destructive) { model.removeAccount(account.id) }
        } message: { _ in
            Text("Parallax stops tracking it. The account itself isn't changed.")
        }
    }
}

extension Provider: Identifiable {
    var id: String { rawValue }
}

private struct AccountCard: View {
    var model: AppModel
    var account: UsageAccount
    var rename: () -> Void
    var remove: () -> Void

    private var busy: Bool { model.busyAccounts.contains(account.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.label).font(.headline)
                    Text([account.email, account.plan].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(account.provider.label)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                Menu {
                    Button("Rename…", action: rename)
                    Button("Sign In Again") { Task { await model.signIn(account.id) } }
                    Divider()
                    Button("Remove…", role: .destructive, action: remove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("More for \(account.label)")
            }

            if !account.signedIn {
                Button("Sign In") { Task { await model.signIn(account.id) } }
                    .disabled(busy)
            } else if account.windows.isEmpty {
                Text("No usage read yet.").foregroundStyle(.secondary)
            } else {
                ForEach(account.windows, id: \.title) { UsageBar(window: $0) }
            }

            if let error = account.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                if busy {
                    ProgressView().controlSize(.small)
                    Text(account.signedIn ? "Refreshing…" : "Finish signing in in your browser…")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let last = account.lastRefreshed {
                    Text("Updated \(last, format: .relative(presentation: .named))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if account.signedIn {
                    Button {
                        Task { await model.refresh(account.id) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(busy)
                    .help("Refresh \(account.label)")
                }
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AddAccountSheet: View {
    var model: AppModel
    var provider: Provider
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add \(provider.label) Account").font(.title2.weight(.semibold))
            Text(provider == .claude
                 ? "Parallax runs `claude auth login` in a private folder. Sign in with the account whose usage you want to see."
                 : "Parallax opens the Codex sign-in page. Sign in with the account whose usage you want to see.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name, for example Work", text: $label)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Sign In") {
                    let name = label.trimmingCharacters(in: .whitespaces)
                    dismiss()
                    Task { await model.addAccount(provider: provider, label: name) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

private struct RenameAccountSheet: View {
    var model: AppModel
    var account: UsageAccount
    @Environment(\.dismiss) private var dismiss
    @State private var label: String

    init(model: AppModel, account: UsageAccount) {
        self.model = model
        self.account = account
        _label = State(initialValue: account.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Account").font(.title2.weight(.semibold))
            TextField("Name", text: $label).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.renameAccount(account.id, to: label.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
