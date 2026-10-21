import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarItem: Hashable {
    case usage
    case chats
    case storage
    case app(UUID)
}

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var selection: SidebarItem? = .usage
    @State private var appPendingRemoval: ManagedApp?
    @State private var recoveredNotice: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("Usage", systemImage: "gauge.medium").tag(SidebarItem.usage)
                Label("Chats", systemImage: "bubble.left.and.bubble.right").tag(SidebarItem.chats)
                Label("Storage", systemImage: "internaldrive").tag(SidebarItem.storage)
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
                            Button(app.spaces.isEmpty ? "Remove from Parallax…" : "Delete Its Spaces Before Removing", role: .destructive) { appPendingRemoval = app }
                                .disabled(!app.spaces.isEmpty)
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
            case .storage: StorageView(model: model)
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
            if model.waitingForQuit || model.syncProgress != nil {
                HStack {
                    if model.waitingForQuit {
                        ProgressView().controlSize(.small)
                        Text(AppModel.quitWaitingText)
                        Button("Stop Waiting") { model.stopWaitingForQuit() }
                    } else if let progress = model.syncProgress {
                        ProgressView(value: Double(progress.done), total: Double(max(1, progress.total))).frame(width: 100)
                        Text("Carrying over chats… \(progress.done) of \(progress.total)")
                        Button("Stop") { model.stopSync() }
                            .help("Stop after the current chat and open the space")
                    }
                }
                .padding()
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding()
            }
        }
        .confirmationDialog(
            "Open \(model.pendingClaudeOpen?.space.name ?? "space")?",
            isPresented: Binding(get: { model.pendingClaudeOpen != nil }, set: { if !$0 { model.pendingClaudeOpen = nil } }),
            titleVisibility: .visible,
            presenting: model.pendingClaudeOpen
        ) { pending in
            Button(pending.firstSignIn ? "Quit Other Claude Windows and Open" : "Quit Claude and Open") {
                Task { await model.openClaudeSpace(pending.id, choice: .quit(pending.pids)) }
            }
            Button(pending.firstSignIn ? "Open Without Quitting" : pending.targetRunning ? "Show Without Updating" : "Open Without Updating") {
                Task { await model.openClaudeSpace(pending.id, choice: .withoutQuitting) }
            }
        } message: { pending in
            if pending.firstSignIn {
                Text("\(pending.space.name) isn't signed in. While another Claude window is open, the sign-in link opens there instead, so Claude will close in \(pending.quitting.joined(separator: ", ")) first."
                     + (pending.pending.map { $0 > 0 && !pending.targetRunning ? " \($0) chats changed in your other spaces are carried over before it opens." : "" } ?? ""))
            } else {
                Text((pending.pending.map { $0 > 0 ? "\($0) chats changed in your other spaces. " : "The sidebar layout changed in your other spaces. " } ?? "") + "Claude will be closed in \(pending.quitting.joined(separator: ", ")) so their files can be updated safely. Finish any reply in progress first. Replaced copies are backed up.")
            }
        }
        .alert("Parallax", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil; recoveredNotice = nil }
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
            Text("Parallax stops managing this app. Nothing on disk changes.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)) { _ in
            guard let text = model.notice, text != recoveredNotice else { return }
            recoveredNotice = text
            model.notice = nil
            Task { @MainActor in model.report(text) }
        }
        .task {
            if model.importedFromPreviousVersion {
                model.report("Your apps, spaces, and usage accounts were brought over from the previous version of Parallax. Its files were left unchanged.")
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
