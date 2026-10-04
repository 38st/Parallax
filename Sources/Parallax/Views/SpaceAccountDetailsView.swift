import SwiftUI

struct SpaceAccountDetailsView: View {
    @Bindable var store: LibraryStore
    var corporateStore: CorporateUsageStore?
    let application: ManagedApplication
    let profile: LaunchProfile
    @Environment(\.dismiss) private var dismiss
    @State private var link: SpaceAccountLink
    @State private var baseline: SpaceAccountLink?
    @State private var error: String?

    init(store: LibraryStore, corporateStore: CorporateUsageStore?, application: ManagedApplication, profile: LaunchProfile) {
        self.store = store
        self.corporateStore = corporateStore
        self.application = application
        self.profile = profile
        _link = State(initialValue: profile.accountLink ?? SpaceAccountLink())
        _baseline = State(initialValue: profile.accountLink)
    }

    private var accounts: [TrackedAIAccount] {
        let provider: AIProvider = LibraryStore.resolvedPreset(for: application) == .claude ? .claude : .codex
        return corporateStore?.trackedAccounts.filter { $0.provider == provider } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Account & Usage").font(.title2.bold())
            Text(profile.name).font(.headline)
            Form {
                Section("Desktop login") {
                    TextField("Expected email", text: $link.expectedEmail)
                    Text("Open the space, sign in inside the app, and check its account menu. Parallax cannot read the live Desktop login.")
                        .font(.callout).foregroundStyle(.secondary)
                    if let confirmation = link.desktopConfirmation {
                        Text("Last confirmed by you: \(confirmation.email)")
                        Text(confirmation.confirmedAt, style: .date)
                        Text("This is a saved confirmation, not a live identity check.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Desktop account unknown").foregroundStyle(.secondary)
                    }
                    Button("I checked this email in the Desktop app") {
                        link.confirmDesktopLogin(at: Date())
                    }.disabled(link.expectedIdentity == nil)
                }
                Section("Usage connection") {
                    Picker("Linked tracking record", selection: $link.trackingAccountID) {
                        Text("Not linked").tag(nil as UUID?)
                        ForEach(accounts) { account in
                            Text(account.email.isEmpty ? account.label : account.email).tag(Optional(account.id))
                        }
                        if let id = link.trackingAccountID, !accounts.contains(where: { $0.id == id }) {
                            Text("Tracking record unavailable").tag(Optional(id))
                        }
                    }
                    Text("Usage comes from a separate CLI connection. Linking a record does not sign in to Desktop or copy credentials.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let account = accounts.first(where: { $0.id == link.trackingAccountID }) {
                        SpaceUsageSummary(account: account, expectedEmail: link.expectedIdentity)
                    }
                }
            }.formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            SpaceOperationStatusView(store: store)
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    if store.saveAccountLink(link, applicationID: application.id, profileID: profile.id, expected: baseline) {
                        dismiss()
                    } else { error = store.errorMessage }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560, height: 620)
    }
}

struct SpaceUsageSummary: View {
    let account: TrackedAIAccount
    var expectedEmail: String? = nil

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let metadata = CorporateAccountMetadataPresentation(account: account, now: context.date)
            VStack(alignment: .leading, spacing: 4) {
                if let expectedEmail {
                    if account.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Usage identity unknown").font(.caption).foregroundStyle(.secondary)
                    } else if expectedEmail.caseInsensitiveCompare(account.email.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame {
                        Text("The linked usage record lists a different email.").font(.caption).foregroundStyle(.orange)
                    }
                }
                if metadata.hasCurrentUsage {
                    Text("Usage: \(account.normalizedUsagePercent) percent")
                    if let resets = metadata.resetsAt {
                        Text(String(format: String(localized: "Resets %@"), resets.formatted(.relative(presentation: .named))))
                    }
                } else {
                    Text("Usage unavailable").foregroundStyle(.secondary)
                    if let retainedUsagePercent = metadata.retainedUsagePercent {
                        let retained: Int = retainedUsagePercent
                        Text("Last reported usage: \(retained)% (not current)").font(.caption)
                    }
                }
                if let checked = account.lastSuccessfulRefreshAt {
                    HStack { Text("Last checked"); Text(checked, style: .relative) }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
