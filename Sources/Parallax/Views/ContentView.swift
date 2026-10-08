import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case usage
    case chats
    case app(UUID)
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarItem? = .usage
    @State private var appPendingRemoval: ManagedApp?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Usage", systemImage: "gauge.medium").tag(SidebarItem.usage)
                Label("Chats", systemImage: "bubble.left.and.bubble.right").tag(SidebarItem.chats)
                Section("Apps") {
                    ForEach(model.apps) { app in
                        HStack(spacing: 10) {
                            AppIcon(path: app.path).frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                Text(spaceCount(app)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .tag(SidebarItem.app(app.id))
                        .contextMenu {
                            Button("Remove from Parallax…", role: .destructive) { appPendingRemoval = app }
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                Button(action: chooseApp) { Label("Add App", systemImage: "plus") }
                    .help("Add an app")
            }
        } detail: {
            switch selection {
            case .usage: UsageView(model: model)
            case .chats: ChatsView(model: model)
            case .app(let id):
                if model.app(id) != nil {
                    AppSpacesView(model: model, appID: id)
                } else {
                    ContentUnavailableView("App removed", systemImage: "square.dashed")
                }
            case nil:
                ContentUnavailableView("Choose an item in the sidebar", systemImage: "sidebar.left")
            }
        }
        .disabled(model.syncingClaudeChats)
        .overlay(alignment: .bottom) {
            if model.syncingClaudeChats {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Carrying over Claude Code chats…")
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
            }
        }
        .confirmationDialog(
            "Open \(model.pendingClaudeSpace?.name ?? "space") with all chats?",
            isPresented: Binding(get: { model.pendingClaudeSpace != nil }, set: { if !$0 { model.pendingClaudeSpace = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingClaudeSpace
        ) { space in
            Button("Quit Claude and Open \(space.name)") {
                Task { await model.openClaudeSpace(space.id, quitRunning: true) }
            }
        } message: { _ in
            Text("Finish any reply in progress first. Parallax will close Claude in all spaces, carry over all available Code chats, then open this account. Replaced copies are backed up.")
        }
        .alert("Parallax", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .confirmationDialog(
            "Remove \(appPendingRemoval?.name ?? "this app") from Parallax?",
            isPresented: Binding(get: { appPendingRemoval != nil }, set: { if !$0 { appPendingRemoval = nil } }),
            presenting: appPendingRemoval
        ) { app in
            Button("Remove", role: .destructive) {
                if selection == .app(app.id) { selection = nil }
                model.removeApp(app.id)
            }
        } message: { _ in
            Text("Its spaces are removed from the list. Their data folders stay on disk.")
        }
        .task {
            if model.importedFromPreviousVersion {
                model.notice = "Your apps, spaces, and usage accounts were brought over from the previous version of Parallax. Its files were left unchanged."
                model.importedFromPreviousVersion = false
            }
        }
    }

    private func spaceCount(_ app: ManagedApp) -> String {
        app.spaces.count == 1 ? "1 space" : "\(app.spaces.count) spaces"
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addApp(at: url)
        if let app = model.apps.last, app.path == url.path { selection = .app(app.id) }
    }
}
