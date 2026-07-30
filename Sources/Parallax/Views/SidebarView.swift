import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        List(selection: $store.selectedApplicationID) {
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
                    .tag(application.id)
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
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    store.beginAddingApplication()
                } label: {
                    Label("Choose an App", systemImage: "plus")
                }
                .help("Choose an App")

                Button {
                    NSApp.sendAction(
                        #selector(
                            NSSplitViewController.toggleSidebar(_:)
                        ),
                        to: nil,
                        from: nil
                    )
                } label: {
                    Label(
                        "Toggle Sidebar",
                        systemImage: "sidebar.left"
                    )
                }
                .help("Toggle Sidebar")
                .keyboardShortcut(
                    "s",
                    modifiers: [.control, .command]
                )
            }
        }
        .toolbar(removing: .sidebarToggle)
    }
}
