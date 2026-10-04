import SwiftUI

/// One history control. Membership is always reviewed in the history panel.
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
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("History").font(.headline)
                if let library {
                    Text(library.bindings.values.map(\.label).sorted().joined(separator: ", "))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Separate histories").font(.caption).foregroundStyle(.secondary)
                }
                if source == nil {
                    Text("Select a space to review its history.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            Button("History…") { if let source { manage(source) } }
                .disabled(source == nil)
                .accessibilityIdentifier("conversation-library.manage")
        }
        .padding(12)
        .task(id: "\(application.storageID)-\(store.selectedProfileID?.uuidString ?? "")-\(store.sharedHistoryRevision)") {
            do {
                library = try source.flatMap { try store.conversationLibrary(application: application, profile: $0) }
                error = nil
            } catch { library = nil; self.error = error.localizedDescription }
        }
    }
}
