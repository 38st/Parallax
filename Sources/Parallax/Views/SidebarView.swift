import SwiftUI

struct SidebarView: View {
    @Bindable var store: LibraryStore
    @Bindable var corporateStore: CorporateUsageStore
    @Binding var selection: WorkspaceSidebarSelection?

    var body: some View {
        List(selection: $selection) {
            Label("Home", systemImage: "house")
                .tag(WorkspaceSidebarSelection.localSpaces)
            Section("Apps") {
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
            Section {
                Label("Usage", systemImage: "chart.bar.xaxis")
                    .tag(WorkspaceSidebarSelection.corporate(.accounts))
                Label("Activity", systemImage: "clock.arrow.circlepath")
                    .tag(WorkspaceSidebarSelection.corporate(.activity))
                Label("Settings", systemImage: "gearshape")
                    .tag(WorkspaceSidebarSelection.settings)
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
    }

    private var workspaceFooter: some View {
        HStack {
            Text("Parallax").font(.caption.weight(.semibold))
            Spacer()
            Text(LocalizedCount.applications(store.applications.count)).font(.caption).foregroundStyle(.secondary)
        }.padding(12).background(.bar)
    }
}
