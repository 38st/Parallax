import SwiftUI

struct SidebarView: View {
    @Bindable var store: LibraryStore
    @Bindable var corporateStore: CorporateUsageStore
    @Binding var selection: WorkspaceSidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Section("Control Center") {
                ForEach(CorporateSection.allCases) { section in
                    Label(section.label, systemImage: section.systemImage)
                        .tag(WorkspaceSidebarSelection.corporate(section))
                }
            }

            Section("Local Spaces") {
                Label("All Spaces", systemImage: "macwindow.on.rectangle")
                    .tag(WorkspaceSidebarSelection.localSpaces)

                ForEach(store.applications) { application in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: application.appPath))
                            .resizable()
                            .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(application.displayName)
                                .lineLimit(1)

                            Text(
                                LocalizedCount.spaces(
                                    application.profiles.count
                                )
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(
                        WorkspaceSidebarSelection.application(application.id)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        Text(
                            "\(application.displayName), \(LocalizedCount.spaces(application.profiles.count))"
                        )
                    )
                    .contextMenu {
                        Button("Remove…", role: .destructive) {
                            store.beginApplicationRemoval(application)
                        }
                        .accessibilityLabel(
                            Text(
                                "Remove \(application.displayName)"
                            )
                        )
                        .accessibilityIdentifier(
                            "application.remove.\(application.id.uuidString)"
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Parallax")
        .safeAreaInset(edge: .bottom) {
            workspaceFooter
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    store.beginAddingApplication()
                } label: {
                    Label("Choose an App", systemImage: "plus")
                }
                .help("Choose an App")
            }
        }
        .workspaceSidebarToggle()
    }

    private var workspaceFooter: some View {
        // Signed-in accounts only: an account waiting on provider sign-in is
        // still tracked and connected, but it is not counted here.
        let connectedCount = corporateStore.trackedAccounts.filter(
            \.isSignedIn
        ).count
        return HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.16))
                Image(systemName: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text("Parallax workspace")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(
                    "\(connectedCount) connected · \(store.applications.count) apps"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.bar)
    }
}
