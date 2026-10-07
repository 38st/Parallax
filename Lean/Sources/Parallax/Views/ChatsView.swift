import SwiftUI

struct ChatsView: View {
    @Bindable var model: AppModel
    @State private var selectedChatID: String?
    @State private var search = ""
    @State private var pending: ChatTransfer?
    @State private var working = false

    private var spaces: [(app: ManagedApp, space: Space)] { model.claudeSpaces }

    private var filtered: [Chat] {
        let terms = search.lowercased().split(separator: " ")
        guard !terms.isEmpty else { return model.chats }
        return model.chats.filter { chat in
            let text = (chat.title + " " + chat.newest.cwd).lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
    }

    var body: some View {
        Group {
            if spaces.count < 2 {
                ContentUnavailableView(
                    "Continue Claude chats across accounts",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Add the Claude app and create a space for each Claude account. Your Claude Code chats from every account then appear here, and you can continue any of them in another account.")
                )
            } else {
                HStack(spacing: 0) {
                    list.frame(width: 380).frame(maxHeight: .infinity)
                    Divider()
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .navigationTitle("Chats")
        .searchable(text: $search, placement: .toolbar, prompt: "Search chats")
        .toolbar {
            Button {
                Task { await model.reloadChats() }
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
        }
        .task { await model.reloadChats() }
        .sheet(item: $pending) { transfer in
            ContinueSheet(model: model, transfer: transfer)
        }
    }

    private var list: some View {
        List(filtered, selection: $selectedChatID) { chat in
            VStack(alignment: .leading, spacing: 3) {
                Text(chat.title).lineLimit(2)
                Text("\(chat.project) · \(chat.lastActivity, format: .relative(presentation: .named))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .tag(chat.id)
        }
        .overlay {
            if model.loadingChats && model.chats.isEmpty { ProgressView() }
            else if !model.loadingChats && filtered.isEmpty { Text("No chats found").foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let chat = model.chats.first(where: { $0.id == selectedChatID }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(chat.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    LabeledContent("Project") { Text(chat.newest.cwd).textSelection(.enabled) }
                    LabeledContent("Last message") { Text(chat.lastActivity, format: .dateTime) }
                    LabeledContent("Latest in") { Text(spaceName(chat.newest.spaceID)) }
                    Divider()
                    Text("Continue in").font(.headline)
                    ForEach(spaces, id: \.space.id) { pair in
                        HStack {
                            RunningDot(running: model.running[pair.space.id] != nil)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(pair.space.name)
                                Text(status(chat, in: pair.space.id)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let account = model.account(forEmail: pair.space.email) { UsageBadge(account: account) }
                            Spacer()
                            Button("Continue Here") { start(chat, in: pair.space.id) }
                                .disabled(working)
                        }
                        .padding(.vertical, 4)
                    }
                    Text("Messages, the project folder, and the chat title carry over. Sign-ins, permissions, and claude.ai artifacts stay with each account.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(24)
            }
        } else {
            ContentUnavailableView("Select a chat", systemImage: "bubble.left")
        }
    }

    private func spaceName(_ id: UUID) -> String {
        spaces.first { $0.space.id == id }?.space.name ?? "Unknown space"
    }

    private func status(_ chat: Chat, in spaceID: UUID) -> String {
        if chat.newest.spaceID == spaceID { return "Has the latest messages" }
        return chat.copies.contains { $0.spaceID == spaceID } ? "Has an older copy" : "Doesn't have this chat yet"
    }

    private func start(_ chat: Chat, in spaceID: UUID) {
        working = true
        Task {
            defer { working = false }
            do {
                let transfer = try await model.prepareContinue(chat, in: spaceID)
                if transfer.kind == .upToDate, model.running[spaceID] != nil {
                    model.show(spaceID)
                } else {
                    pending = transfer
                }
            } catch {
                model.notice = error.localizedDescription
            }
        }
    }
}

extension ChatTransfer: Identifiable {
    var id: String { "\(chatID)-\(targetSpaceID)" }
}

private struct ContinueSheet: View {
    var model: AppModel
    @State var transfer: ChatTransfer
    @Environment(\.dismiss) private var dismiss
    @State private var working = false

    private var target: Space? { model.claudeSpaces.first { $0.space.id == transfer.targetSpaceID }?.space }
    private var sourceName: String { model.claudeSpaces.first { $0.space.id == transfer.source.spaceID }?.space.name ?? "the other space" }
    private var blocking: [Space] {
        model.instancesBlocking(transfer).compactMap { id in model.claudeSpaces.first { $0.space.id == id }?.space }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Continue in \(target?.name ?? "space")").font(.title2.weight(.semibold))
            Text(explanation).fixedSize(horizontal: false, vertical: true)
            if !blocking.isEmpty {
                Label("Claude will be quit in \(blocking.map(\.name).joined(separator: " and ")) so its files can be updated safely. Finish any reply in progress first.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button(blocking.isEmpty ? "Continue" : "Quit Claude and Continue") { run() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var explanation: String {
        let name = target?.name ?? "this space"
        return switch transfer.kind {
        case .upToDate: "\(name) already has the latest messages. Claude opens with this chat."
        case .add: "The chat is copied from \(sourceName) into \(name), then Claude opens with it. Claude may ask you to confirm the import."
        case .update: "\(name) has an older copy. It's updated with the newer messages from \(sourceName), then Claude opens with it."
        case .replaceDiverged:
            "This chat was continued separately in both spaces. \(name)'s copy is replaced with the more recent one from \(sourceName). The replaced copy is saved in Parallax/ChatBackups."
        }
    }

    private func run() {
        working = true
        Task {
            defer { working = false }
            let blockingIDs = model.instancesBlocking(transfer)
            if !blockingIDs.isEmpty {
                guard await model.quitAndWait(blockingIDs) else {
                    model.notice = "Claude didn't quit. Quit it yourself, then try again."
                    dismiss()
                    return
                }
                // Re-read after quitting: Claude may have saved more messages on the way out.
                await model.reloadChats()
                guard let chat = model.chats.first(where: { $0.id == transfer.chatID }) else { dismiss(); return }
                do {
                    let fresh = try await model.prepareContinue(chat, in: transfer.targetSpaceID)
                    if fresh.kind == .replaceDiverged && transfer.kind != .replaceDiverged {
                        transfer = fresh
                        return
                    }
                    transfer = fresh
                } catch {
                    model.notice = error.localizedDescription
                    dismiss()
                    return
                }
            }
            await model.continueChat(transfer)
            dismiss()
        }
    }
}
