import SwiftUI

struct CodexSharedWorkspaceView: View {
    @Bindable var store: LibraryStore
    let application: ManagedApplication
    @State private var workspace: CodexSharedWorkspace?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Use one chat history for all Codex accounts", isOn: Binding(
                get: { workspace != nil },
                set: { enabled in
                    do {
                        try store.setCodexSharedWorkspace(enabled, application: application, expected: workspace)
                        reload()
                    } catch { self.error = error.localizedDescription }
                }
            ))
            .disabled(store.isProfileDataOperationRunning)
            .accessibilityIdentifier("codex-shared-workspace.all-accounts")
            Text("All current and future spaces open the main Codex workspace on this Mac. Change accounts inside Codex; chats, projects, and attachments stay in that workspace. Space names do not choose the signed-in account.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Other spaces’ existing histories stay in their folders. Turn this off to open those separate histories again.")
                .font(.caption).foregroundStyle(.secondary)
            if let workspace {
                Text(workspace.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
        .padding(10)
        .task(id: "\(application.storageID)-\(store.sharedHistoryRevision)") { reload() }
    }

    private func reload() {
        do { workspace = try store.codexSharedWorkspace(application); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
