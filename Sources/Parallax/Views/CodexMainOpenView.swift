import SwiftUI

struct CodexMainOpenView: View {
    @Bindable var store: LibraryStore
    let application: ManagedApplication
    var edit: ((LaunchProfile) -> Void)? = nil
    @State private var error: String?

    var body: some View {
        let workspace = try? store.codexSharedWorkspace(application)
        let profile = application.profiles.first { $0.storageID == workspace?.launchProfileStorageID }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Main Codex Workspace").font(.headline)
                    Text("Change accounts inside Codex. This destination keeps the main workspace’s history.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Codex") {
                    if let profile { store.launch(profile, application: application) }
                }.buttonStyle(.borderedProminent).disabled(profile == nil)
            }
            DisclosureGroup("Launch configuration") {
                Picker("Space settings", selection: Binding(
                    get: { workspace?.launchProfileStorageID },
                    set: { id in
                        do { try store.setCodexMainLaunchProfile(id, application: application, expected: workspace) }
                        catch { self.error = error.localizedDescription }
                    })) {
                    Text("Choose a space").tag(nil as UUID?)
                    ForEach(application.profiles) { profile in
                        Text(profile.name).tag(Optional(profile.storageID))
                    }
                }
                if let profile, let edit { Button("Edit Space…") { edit(profile) } }
            }
            if profile == nil { Text("Choose launch settings once to enable Open Codex.").font(.caption) }
            if let error { Text(error).foregroundStyle(.red) }
        }.padding(14)
    }
}
