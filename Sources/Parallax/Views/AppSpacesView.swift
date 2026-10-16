import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct AppSpacesView: View {
    @Bindable var model: AppModel
    var appID: UUID
    @State private var addingSpace = false
    @State private var editing: Space?
    @State private var deleting: Space?
    @State private var pendingKind: AppKind?
    @State private var quittingOutside: [NSRunningApplication] = []

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
                        Text("Open a space to bring over the latest chats and messages from every Claude space. Claude closes in the destination space, and anywhere using its folders, before copying. Replaced copies are backed up. Regular Claude chats and claude.ai artifacts stay with their account.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
                    if let last = model.lastSync {
                        DisclosureGroup("Last carry-over \(last.date.formatted(.relative(presentation: .named))): \(last.result.transferred) chats carried, \(last.result.issues.count) issues") {
                            ForEach(Array((last.result.notes + last.result.issues).enumerated()), id: \.offset) { _, text in
                                Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    if !model.claudeOutsideSpaces.isEmpty {
                        HStack(spacing: 12) {
                            Text("Claude is also open without a space, so it shows Claude's default account. This happens after Claude updates itself or the Mac restarts. Its chats aren't carried over.")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Button("Show") {
                                if let instance = model.instancesOutsideSpaces(of: app).first { model.hooks.activate(instance) }
                            }
                            Button("Quit It…") { quittingOutside = model.instancesOutsideSpaces(of: app) }
                            .confirmationDialog("Quit Claude that's open without a space?",
                                isPresented: Binding(get: { !quittingOutside.isEmpty }, set: { if !$0 { quittingOutside = [] } }),
                                presenting: quittingOutside) { instances in
                                Button("Quit Claude", role: .destructive) { instances.forEach { model.hooks.terminate($0) } }
                            } message: { _ in
                                Text("It uses Claude's default account. Finish any reply in progress there first.")
                            }
                        }
                        .padding(16)
                        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    }
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
                    guard kind != app.kind else { return }
                    if app.spaces.isEmpty { changeKind(kind, app: app) }
                    else { pendingKind = kind }
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
        .confirmationDialog("Change how \(app.name) is isolated?",
            isPresented: Binding(get: { pendingKind != nil }, set: { if !$0 { pendingKind = nil } }),
            presenting: pendingKind) { kind in
            Button("Use \(kind.label)") { changeKind(kind, app: app) }
        } message: { kind in
            Text(app.kind == .claude
                 ? "Its \(app.spaces.count) spaces will leave the Chats page, stop carrying chats and open without their own Claude Code settings folder until you switch back. Sign-ins and chats stay in their folders."
                 : "Its \(app.spaces.count) spaces will open with \(kind.label) settings. Their data folders stay where they are; switch back to undo.")
        }
    }

    private func changeKind(_ kind: AppKind, app: ManagedApp) {
        var updated = app
        updated.kind = kind
        model.updateApp(updated)
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
                    Text("All your Codex chats stay together in ~/.codex. Switch accounts inside Codex and keep going in the same chat. Turn this off to give each account its own Codex window; chats then stay with the account that started them.")
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
                Text("While one shared history is on, Codex opens with all your chats and these spaces aren't used. Turn it off to open a separate Codex window per account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if app.spaces.isEmpty {
                Text(app.kind == .other
                     ? "This app isn't isolated per space. Choose a different isolation type in App Settings if it supports one."
                     : "Create a space for each account you want to use. Each space keeps its own sign-in and data.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(app.spaces) { space in
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
            model.report(error.localizedDescription)
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
                    Button("Show") { Task { await model.open(space.id, in: app.id) } }
                        .accessibilityLabel("Show \(space.name)")
                } else {
                    Button("Show") { model.show(space.id) }.accessibilityLabel("Show \(space.name)")
                }
                Button("Quit") { model.quit(space.id) }.accessibilityLabel("Quit \(space.name)")
            } else if !sharedCodex {
                if model.launching.contains(space.id) { ProgressView().controlSize(.small) }
                Button("Open") { Task { await model.open(space.id, in: app.id) } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.launching.contains(space.id))
                    .accessibilityLabel("Open \(space.name)")
            }
            Menu {
                Button("Edit…", action: edit).accessibilityLabel("Edit \(space.name)")
                Button("Show Data Folder in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: space.folder)])
                }
                .accessibilityLabel("Show data folder for \(space.name)")
                Divider()
                Button("Delete…", role: .destructive, action: delete).accessibilityLabel("Delete \(space.name)")
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
