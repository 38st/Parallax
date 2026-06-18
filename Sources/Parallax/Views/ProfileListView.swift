import SwiftUI

struct ProfileListView: View {
    @Bindable var store: LibraryStore
    var application: ManagedApplication
    @State private var profilePendingRemoval: LaunchProfile?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedProfileID) {
                ForEach(application.profiles) { profile in
                    HStack(spacing: 8) {
                        Button {
                            store.launch(profile)
                        } label: {
                            Label("Launch", systemImage: "play.fill")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Launch \(profile.name)")

                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .lineLimit(1)

                            HStack(spacing: 5) {
                                if profile.environment["CODEX_HOME"] != nil {
                                    badge("Codex")
                                } else if profile.arguments.contains(where: { $0.hasPrefix("--user-data-dir=") }) {
                                    badge("Data Dir")
                                }

                                if let lastLaunchedAt = profile.lastLaunchedAt {
                                    Text("Last \(lastLaunchedAt.formatted(date: .omitted, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Text(profile.arguments.isEmpty ? "No launch arguments" : "\(profile.arguments.count) argument\(profile.arguments.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(profile.id)
                    .contextMenu {
                        Button("Duplicate") {
                            store.selectedProfileID = profile.id
                            store.duplicateSelectedProfile()
                        }

                        Button("Remove", role: .destructive) {
                            store.selectedProfileID = profile.id
                            profilePendingRemoval = profile
                        }
                    }
                }
            }

            Divider()

            HStack {
                Button {
                    store.addProfile()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add Smart Profile")

                Menu {
                    ForEach(store.profileTemplateNames, id: \.self) { templateName in
                        Button(templateName) {
                            store.addProfile(named: templateName)
                        }
                    }
                } label: {
                    Label("Templates", systemImage: "person.2.badge.gearshape")
                }
                .menuStyle(.borderlessButton)
                .help("Add From Template")

                Button {
                    store.duplicateSelectedProfile()
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(store.selectedProfile == nil)

                Spacer()
            }
            .labelStyle(.iconOnly)
            .padding(8)
        }
        .confirmationDialog(
            "Remove \(profilePendingRemoval?.name ?? "Profile")?",
            isPresented: Binding(
                get: { profilePendingRemoval != nil },
                set: { if !$0 { profilePendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let profilePendingRemoval {
                Button("Remove Profile Only") {
                    store.remove(profile: profilePendingRemoval, dataRemoval: .keep)
                    self.profilePendingRemoval = nil
                }
                Button("Remove and Archive Data") {
                    store.remove(profile: profilePendingRemoval, dataRemoval: .archive)
                    self.profilePendingRemoval = nil
                }
                Button("Remove and Delete Data", role: .destructive) {
                    store.remove(profile: profilePendingRemoval, dataRemoval: .delete)
                    self.profilePendingRemoval = nil
                }
            }
            Button("Cancel", role: .cancel) {
                profilePendingRemoval = nil
            }
        } message: {
            Text("Choose what to do with the profile's stored data folder.")
        }
    }

    private func badge(_ title: String) -> some View {
        Text(title)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.tertiary, in: Capsule())
    }
}
