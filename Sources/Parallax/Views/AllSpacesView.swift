import SwiftUI

/// Home never chooses a default space. Every open has an explicit target.
struct AllSpacesView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Home").font(.largeTitle.bold())
                Spacer()
                Button("Choose an App") { store.beginAddingApplication() }
            }.padding(20)
            SpaceOperationStatusView(store: store).padding(.horizontal, 20)
            List {
                if !recentSpaces.isEmpty {
                    Section("Recent Spaces") {
                        ForEach(recentSpaces, id: \.profile.id) { item in
                            spaceRow(item.profile, application: item.application)
                        }
                    }
                }
                ForEach(store.applications) { application in
                    Section {
                        Button {
                            store.selectedApplicationID = application.id
                        } label: {
                            HStack(spacing: 12) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: application.appPath))
                                    .resizable().frame(width: 28, height: 28)
                                Text(application.displayName).font(.headline)
                                Spacer()
                                Text(LocalizedCount.spaces(application.profiles.count)).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .accessibilityIdentifier("all-spaces.application.\(application.id.uuidString)")
                        if LibraryStore.resolvedPreset(for: application) == .codex,
                           (try? store.codexSharedWorkspace(application)) != nil {
                            CodexMainOpenView(store: store, application: application)
                        } else {
                            ForEach(application.profiles) { profile in spaceRow(profile, application: application) }
                        }
                    }
                }
            }.listStyle(.inset)
        }.accessibilityIdentifier("all-spaces.overview")
    }

    private var recentSpaces: [(application: ManagedApplication, profile: LaunchProfile)] {
        Array(store.applications.flatMap { application in
            let workspace = LibraryStore.resolvedPreset(for: application) == .codex ? try? store.codexSharedWorkspace(application) : nil
            return application.profiles.filter {
                $0.lastLaunchedAt != nil && (workspace == nil || workspace?.launchProfileStorageID == $0.storageID)
            }.map { (application: application, profile: $0) }
        }.sorted { ($0.profile.lastLaunchedAt ?? .distantPast) > ($1.profile.lastLaunchedAt ?? .distantPast) }.prefix(5))
    }

    private func spaceRow(_ profile: LaunchProfile, application: ManagedApplication) -> some View {
        let usesMainHistory = LibraryStore.resolvedPreset(for: application) == .codex
            && (try? store.codexSharedWorkspace(application)) != nil
        return HStack(spacing: 12) {
            Button {
                store.selectedApplicationID = application.id
                store.selectedProfileID = profile.id
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(usesMainHistory ? String(localized: "Main Codex Workspace") : profile.name)
                    if !usesMainHistory, [.claude, .codex].contains(LibraryStore.resolvedPreset(for: application)) {
                        Text(profile.accountLink?.summary ?? String(localized: "Desktop account unknown"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let status = store.launchStatusMessage(for: application, profile: profile) {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
            .accessibilityIdentifier("all-spaces.profile.\(profile.id.uuidString)")
            SpaceOpenButton(store: store, application: application, profile: profile)
        }.padding(.vertical, 4)
    }
}

struct SpaceOpenButton: View {
    @Bindable var store: LibraryStore
    let application: ManagedApplication
    let profile: LaunchProfile

    var body: some View {
        let running = store.runningApplicationInstances(for: application).first {
            $0.profileID == profile.id && $0.isActionable
        }
        Button(running == nil ? String(localized: "Open") : String(localized: "Show")) {
            if let running { _ = store.requestActivate(running, from: application) }
            else { store.launch(profile, application: application) }
        }
        .buttonStyle(.bordered)
        .disabled(running == nil && switchPending)
        .accessibilityLabel(running == nil ? Text("Open \(profile.name)") : Text("Show \(profile.name)"))
    }
    private var switchPending: Bool {
        _ = store.sharedHistoryRevision
        guard LibraryStore.resolvedPreset(for: application) == .claude else { return false }
        return (try? store.conversationLibrary(application: application, profile: profile))?.handoff != nil
    }

}
