import SwiftUI

struct ClaudeConversationCopyView: View {
    @Bindable var store: LibraryStore
    let application: ManagedApplication
    let source: LaunchProfile
    @Environment(\.dismiss) private var dismiss
    @State private var catalog = ClaudeConversationCatalog()
    @State private var selectedConversationID: String?
    @State private var destinationID: UUID?
    @State private var plan: ClaudeConversationCopyPlan?
    @State private var errorMessage: String?
    @State private var isBusy = false
    @State private var copied = false

    private var conversation: ClaudeConversation? {
        catalog.conversations.first { $0.id == selectedConversationID }
    }
    private var destination: LaunchProfile? {
        application.profiles.first { $0.id == destinationID && $0.id != source.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Copy Claude Conversation").font(.title2.bold())
                Spacer()
                Text("Preview").font(.caption).foregroundStyle(.secondary)
            }
            if copied {
                Label("Conversation copied", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("Open the destination space and choose the copied conversation in Claude’s Code tab. Claude may ask you to review the imported conversation before continuing.")
            } else {
                Text("Copy a local Code conversation to another Claude space to continue with the account signed in there.")
                    .foregroundStyle(.secondary)
                LabeledContent("From", value: source.name)
                List(selection: $selectedConversationID) {
                    ForEach(catalog.conversations) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: item.title).lineLimit(1)
                            Text(verbatim: item.workingDirectory)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        .tag(item.id)
                    }
                }
                .frame(minHeight: 160, idealHeight: 240, maxHeight: 300)
                .disabled(isBusy)
                .accessibilityLabel(Text("Claude conversations"))
                .overlay {
                    if catalog.conversations.isEmpty && !isBusy {
                        Text("No supported local Code conversations found.")
                            .foregroundStyle(.secondary).allowsHitTesting(false)
                    }
                }
                if catalog.unavailableCount > 0 {
                    Text("Some conversations could not be listed because their session format is unsupported.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Copy to", selection: $destinationID) {
                    Text("Choose a space").tag(nil as UUID?)
                    ForEach(application.profiles.filter { $0.id != source.id }) { profile in
                        Text(verbatim: profile.name).tag(Optional(profile.id))
                    }
                }
                .disabled(isBusy)
                if let plan {
                    GroupBox("Review Conversation Copy") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: plan.conversation.title).font(.headline)
                            Text("The original conversation stays in its space. The copy includes messages and tool results, which may contain private information. Continuing sends that context using the destination account.")
                            Text("Both conversations use the same project files. Login credentials, app settings, and previous permission approvals are not copied.")
                            Text("Quit all Claude windows before copying. Open the destination space after the copy completes.")
                        }
                        .font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            if let errorMessage {
                Text(verbatim: errorMessage).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if isBusy { ProgressView().controlSize(.small) }
                if !copied {
                    Button("Refresh") { Task { await refresh() } }.disabled(isBusy)
                }
                Spacer()
                Button(copied ? String(localized: "Done") : String(localized: "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(isBusy)
                if copied, let destination {
                    Button("Open Destination Space") {
                        dismiss()
                        store.launch(destination)
                    }.buttonStyle(.borderedProminent)
                } else {
                    Button(plan == nil ? String(localized: "Review Copy") : String(localized: "Copy Conversation")) {
                        Task { await reviewOrCopy() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || conversation == nil || destination == nil)
                }
            }
        }
        .padding(24)
        .frame(width: 600)
        .interactiveDismissDisabled(isBusy)
        .task { await refresh() }
        .onChange(of: selectedConversationID) { _, _ in plan = nil; errorMessage = nil }
        .onChange(of: destinationID) { _, _ in plan = nil; errorMessage = nil }
    }

    private func refresh() async {
        isBusy = true
        defer { isBusy = false }
        plan = nil
        selectedConversationID = nil
        errorMessage = nil
        do { catalog = try await store.claudeConversations(application: application, profile: source) }
        catch { catalog = .init(); errorMessage = error.localizedDescription }
    }

    private func reviewOrCopy() async {
        guard let conversation, let destination else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        do {
            if let plan {
                _ = try await store.copyClaudeConversation(plan, application: application, source: source, destination: destination)
                copied = true
            } else {
                plan = try await store.prepareClaudeConversationCopy(conversation, application: application, source: source, destination: destination)
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
