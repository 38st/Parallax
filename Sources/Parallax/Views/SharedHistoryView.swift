import SwiftUI

struct SharedHistoryView: View {
    @Bindable var store: LibraryStore
    let application: ManagedApplication
    let source: LaunchProfile
    @Environment(\.dismiss) private var dismiss
    @State private var members: Set<UUID> = []
    @State private var existing: SharedHistoryGroup?
    @State private var message: String?
    @State private var busy = false
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shared History (Preview)").font(.title2.bold())
            Text("Switch accounts when credits run out and continue the same saved chats. Choose the spaces that should share history; other spaces stay separate.")
            Text("Quit the app before switching. Parallax updates active local Code chats when you open a linked space. Sign-ins stay separate. Messages and tool results will be visible to every linked account.")
                .font(.callout).foregroundStyle(.secondary)
            if LibraryStore.resolvedPreset(for: application) == .claude {
                Text("Claude Desktop 2.9939.2 only. Claude may ask you to review an imported chat before continuing. Chat-tab and remote conversations are not included.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Local Codex rollout preview for 0.153.2 and 0.158.0-alpha.2.1. Updated messages appear when the chat resumes. Cloud chats and ChatGPT chat history are not included.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(application.profiles) { profile in
                        Toggle(profile.name, isOn: Binding(
                            get: { members.contains(profile.storageID) },
                            set: { value in
                                if value { members.insert(profile.storageID) }
                                else { members.remove(profile.storageID) }
                            }))
                            .disabled(profile.storageID == source.storageID)
                    }
                }.padding(4)
            }.frame(maxHeight: 220)
            Text("Archives, deletions, and conflicting edits are not merged. If a shared chat is missing or changed in both accounts, sharing stops and preserves the saved versions. Turning sharing off keeps the chats already copied.")
                .font(.caption).foregroundStyle(.secondary)
            if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if existing != nil {
                    Button("Turn Off Sharing") { save([]) }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Share History") { save(members) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!loaded || members.count < 2 || members.count > 8)
            }
        }
        .padding(24)
        .frame(width: 560)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .task { reload() }
    }

    private func reload() {
        do {
            existing = try store.sharedHistoryGroup(application: application, profile: source)
            members = Set(existing?.profileStorageIDs ?? [source.storageID])
            loaded = true
        } catch { message = error.localizedDescription }
    }

    private func save(_ selection: Set<UUID>) {
        busy = true
        message = nil
        Task { @MainActor in
            defer { busy = false }
            do {
                try await store.setSharedHistory(application: application, source: source, members: selection, expected: existing)
                dismiss()
            } catch {
                message = error.localizedDescription
                reload()
            }
        }
    }
}
