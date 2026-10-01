import SwiftUI

/// The routine action is choosing an account. Setup and recovery stay in the
/// library sheet; no conversation is implicitly selected from the first row.
struct ConversationAccountPicker: View {
    @Bindable var store: LibraryStore
    let application: ManagedApplication
    let manage: (LaunchProfile) -> Void
    @State private var library: ConversationLibrary?
    @State private var error: String?

    private var source: LaunchProfile? {
        application.profiles.first { $0.id == store.selectedProfileID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let library {
                    Menu {
                        ForEach(application.profiles.filter { library.bindings[$0.storageID.uuidString] != nil }) { profile in
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
            if let message = store.conversationSwitchMessage, library != nil { Text(message).font(.caption) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(10)
        .task(id: "\(store.selectedProfileID?.uuidString ?? "")-\(store.sharedHistoryRevision)") {
            do {
                library = try source.flatMap { try store.conversationLibrary(application: application, profile: $0) }
                error = nil
            } catch { library = nil; self.error = error.localizedDescription }
        }
    }
}
