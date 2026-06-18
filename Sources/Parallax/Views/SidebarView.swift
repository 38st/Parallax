import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        List(selection: $store.selectedApplicationID) {
            Section("Applications") {
                ForEach(store.applications) { application in
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: application.appPath))
                            .resizable()
                            .frame(width: 28, height: 28)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(application.displayName)
                                .lineLimit(1)

                            Text("\(application.profiles.count) profile\(application.profiles.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .tag(application.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(Text("\(application.displayName), \(application.profiles.count) profile\(application.profiles.count == 1 ? "" : "s")"))
                    .contextMenu {
                        Button("Remove") {
                            store.selectedApplicationID = application.id
                            store.removeSelectedApplication()
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Parallax")
        .toolbar {
            ToolbarItem {
                Button {
                    store.beginAddingApplication()
                } label: {
                    Label("Add Application", systemImage: "plus")
                }
                .help("Add Application")
            }
        }
    }
}
