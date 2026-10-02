import SwiftUI

/// The routine action is choosing an account. Setup and recovery stay in the
/// library sheet; no conversation is implicitly selected from the first row.
struct ConversationAccountPicker: View {
    @Bindable var store: LibraryStore
    let application: ManagedApplication
    let manage: (LaunchProfile) -> Void
    @State private var library: ConversationLibrary?
    @State private var error: String?
    @State private var allAccounts = false
    @State private var savingSetting = false

    private var source: LaunchProfile? {
        application.profiles.first { $0.id == store.selectedProfileID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Use one chat history for all Claude accounts", isOn: Binding(
                get: { allAccounts },
                set: { enabled in
                    guard enabled != allAccounts, !savingSetting else { return }
                    Task { await saveSetting(enabled) }
                }
            ))
            .disabled(savingSetting || store.isProfileDataOperationRunning)
            .accessibilityIdentifier("conversation-library.all-accounts")
            Text("Share local Code chats with current and future spaces. Sign in and open Code once in a new space; it joins on its next open. Existing links stay when this setting is off.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if let library {
                    Menu {
                        ForEach(application.profiles.filter { allAccounts || library.bindings[$0.storageID.uuidString] != nil }) { profile in
                            Button(profile.name) {
                                store.selectedProfileID = profile.id
                                store.launch(profile)
                            }
                        }
                    } label: {
                        Label(library.activeProfileID.flatMap { library.bindings[$0.uuidString]?.label }
                            ?? String(localized: "Choose an account"), systemImage: "person.crop.circle")
                    }
                    .disabled(library.handoff != nil)
                    .accessibilityLabel(Text("Switch account with shared conversations"))
                }
                Button("Shared Conversations…") { if let source { manage(source) } }
                    .disabled(source == nil)
                Spacer()
            }
            if savingSetting { ProgressView().controlSize(.small) }
            if let message = store.conversationSwitchMessage, library != nil || allAccounts { Text(message).font(.caption) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(10)
        .task(id: "\(application.storageID)-\(store.selectedProfileID?.uuidString ?? "")-\(store.sharedHistoryRevision)") {
            reload()
        }
    }

    private func reload(clearError: Bool = true) {
        if clearError && !savingSetting { error = nil }
        do {
            allAccounts = try store.usesAllAccountHistory(application)
            library = try source.flatMap { try store.conversationLibrary(application: application, profile: $0) }
            if library == nil, let group = try store.allAccountHistoryGroup(application), group.conversationLibraryID != nil {
                library = try store.conversationLibraryStore(group).read()
            }
        } catch { library = nil; self.error = error.localizedDescription }
    }

    private func saveSetting(_ enabled: Bool) async {
        savingSetting = true; error = nil
        defer { savingSetting = false; reload(clearError: false) }
        do { try await store.setAllAccountHistory(enabled, application: application, expected: allAccounts) }
        catch { self.error = error.localizedDescription }
    }
}
