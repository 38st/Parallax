import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppSpacesView: View {
    @Bindable var model: AppModel
    var appID: UUID
    @State private var addingSpace = false
    @State private var editing: Space?
    @State private var deleting: Space?

    var body: some View {
        if let app = model.app(appID) {
            content(app)
        }
    }

    private func content(_ app: ManagedApp) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(app)
                if app.kind == .codex { codexHistory(app) }
                if app.kind == .claude {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("All Code chats come with you").font(.headline)
                        Text("Open a space to bring over the latest chats and messages from every Claude space. Claude closes before copying, and replaced copies are backed up. Regular Claude chats and claude.ai artifacts stay with their account.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                }
                spaces(app)
            }
            .padding(28)
        }
        .navigationTitle(app.name)
        .sheet(isPresented: $addingSpace) {
            NewSpaceSheet(model: model, app: app)
        }
        .sheet(item: $editing) { space in
            SpaceEditor(model: model, appID: app.id, space: space)
        }
        .confirmationDialog(
            "Delete \(deleting?.name ?? "this space")?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { space in
            Button("Delete and Move Its Data to the Trash", role: .destructive) { delete(space, app: app, trash: true) }
            Button("Delete but Keep Its Data Folder") { delete(space, app: app, trash: false) }
        } message: { space in
            Text("Moving data to the Trash removes this space's sign-ins and local data. You can restore the folder from the Trash.")
        }
    }

    private func header(_ app: ManagedApp) -> some View {
        HStack(spacing: 14) {
            AppIcon(path: app.path).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.largeTitle.weight(.semibold))
                Text(app.kind.label).foregroundStyle(.secondary)
            }
            Spacer()
            Menu {
                Picker("Isolation", selection: Binding(get: { app.kind }, set: { kind in
                    var updated = app
                    updated.kind = kind
                    model.updateApp(updated)
                })) {
                    ForEach(AppKind.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Button("Locate App…") { locate(app) }
                Button("Show Data Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.dataFolder)])
                }
            } label: {
                Label("App Settings", systemImage: "gearshape")
            }
            .fixedSize()
            if !(app.kind == .codex && app.sharedCodexHistory) {
                Button {
                    addingSpace = true
                } label: {
                    Label("New Space", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func codexHistory(_ app: ManagedApp) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { app.sharedCodexHistory }, set: { on in
                var updated = app
                updated.sharedCodexHistory = on
                model.updateApp(updated)
            })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("One chat history for all Codex accounts").font(.headline)
                    Text("Codex opens with its main history in ~/.codex. When an account runs out, switch accounts inside Codex and keep going in the same chat.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            if app.sharedCodexHistory {
                Button {
                    Task { await model.openSharedCodex(app.id) }
                } label: {
                    Label("Open Codex", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    }

    private func spaces(_ app: ManagedApp) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Spaces").font(.title3.weight(.semibold))
            if app.kind == .codex && app.sharedCodexHistory {
                Text("While one shared history is on, these spaces aren't used. Turn it off to open separate Codex instances per account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if app.spaces.isEmpty {
                Text(app.kind == .other
                     ? "This app isn't isolated per space. Choose a different isolation type in App Settings if it supports one."
                     : "Create a space for each account you want to use. Each space keeps its own sign-in and data.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(app.spaces.sorted { ($0.lastOpened ?? .distantPast) > ($1.lastOpened ?? .distantPast) }) { space in
                SpaceRow(
                    model: model, app: app, space: space,
                    edit: { editing = space }, delete: { deleting = space }
                )
                Divider()
            }
        }
    }

    private func delete(_ space: Space, app: ManagedApp, trash: Bool) {
        do {
            try model.deleteSpace(space.id, in: app.id, moveDataToTrash: trash)
        } catch {
            model.notice = error.localizedDescription
        }
    }

    private func locate(_ app: ManagedApp) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = "Use This App"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var updated = app
        updated.path = url.path
        updated.bundleID = Bundle(url: url)?.bundleIdentifier
        model.updateApp(updated)
    }
}

private struct SpaceRow: View {
    var model: AppModel
    var app: ManagedApp
    var space: Space
    var edit: () -> Void
    var delete: () -> Void

    private var isRunning: Bool { model.running[space.id] != nil }
    private var sharedCodex: Bool { app.kind == .codex && app.sharedCodexHistory }

    var body: some View {
        HStack(spacing: 12) {
            RunningDot(running: isRunning)
            VStack(alignment: .leading, spacing: 2) {
                Text(space.name).font(.body.weight(.medium))
                Text(space.email.isEmpty ? "No account email set" : space.email)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let account = model.account(forEmail: space.email, provider: app.kind == .claude ? .claude : app.kind == .codex ? .codex : nil) { UsageBadge(account: account) }
            Spacer()
            if isRunning {
                if app.kind == .claude {
                    Button("Open with All Chats") { Task { await model.open(space.id, in: app.id) } }
                } else {
                    Button("Show") { model.show(space.id) }
                }
                Button("Quit") { model.quit(space.id) }
            } else if !sharedCodex {
                Button("Open") { Task { await model.open(space.id, in: app.id) } }
                    .buttonStyle(.borderedProminent)
            }
            Menu {
                Button("Edit…", action: edit)
                Button("Show Data Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: space.folder)])
                }
                Divider()
                Button("Delete…", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More for \(space.name)")
        }
        .padding(.vertical, 6)
    }
}

private struct NewSpaceSheet: View {
    var model: AppModel
    var app: ManagedApp
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var email = ""
    @State private var codexAccountID: UUID?

    private var codexAccounts: [UsageAccount] { model.accounts.filter { $0.provider == .codex && $0.signedIn } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New \(app.name) Space").font(.title2.weight(.semibold))
            Text("A space opens its own copy of \(app.name) with separate sign-in and data. Sign in inside the app after opening it.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name, for example Work", text: $name).textFieldStyle(.roundedBorder)
            TextField("Account email (optional, shows its usage here)", text: $email).textFieldStyle(.roundedBorder)
            if app.kind == .codex && !codexAccounts.isEmpty {
                Picker("Sign-in", selection: $codexAccountID) {
                    Text("Sign in inside Codex").tag(UUID?.none)
                    ForEach(codexAccounts) { account in
                        Text("Use \(account.label) (\(account.email))").tag(UUID?.some(account.id))
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create and Open") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func create() {
        let account = codexAccounts.first { $0.id == codexAccountID }
        var mail = email.trimmingCharacters(in: .whitespaces)
        if mail.isEmpty, let account { mail = account.email }
        guard let space = model.addSpace(
            to: app.id, name: name.trimmingCharacters(in: .whitespaces), email: mail, codexAccount: account
        ) else { return }
        dismiss()
        Task { await model.open(space.id, in: app.id) }
    }
}
