import SwiftUI

struct ConversationLibraryView: View {
    @Bindable var store: LibraryStore
    let application: ManagedApplication
    let source: LaunchProfile
    var openAccount: ((LaunchProfile) -> Void)? = nil
    var reviewAccount: ((LaunchProfile) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var library: ConversationLibrary?
    @State private var group: SharedHistoryGroup?
    @State private var candidates: [UUID: [ConversationAccountCandidate]] = [:]
    @State private var namespaces: [UUID: String] = [:]
    @State private var selectedConversation: String?
    @State private var targetProfile: UUID?
    @State private var message: String?
    @State private var busy = false
    @State private var confirmedAccounts = false
    @State private var artifactCount: Int?
    @State private var unreviewedCount = 0
    @State private var reviewing: LibraryConversation?
    @State private var reconnecting = false
    @State private var previewText: String?
    @State private var allAccounts = false
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("History")
                .font(.title2.bold())
            SpaceOperationStatusView(store: store)
            if let message { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let library, !reconnecting { libraryControls(library) }
                    else { enrollmentControls }
                }
            }
            HStack {
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 620, height: 680)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .task { await reload() }
        .onChange(of: store.sharedHistoryRevision) { _, _ in Task { await reload() } }
        .onChange(of: namespaces) { _, _ in artifactCount = nil; confirmedAccounts = false }
        .task(id: namespaces) { await reviewArtifacts() }
        .sheet(item: $reviewing) { conversation in revisionReview(conversation) }
    }

    private var enrollmentControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keep one library of local Code conversations and choose which account continues them. Sign-ins and permissions stay separate.")
            Text("Confirm the signed-in account in each Claude space, then quit Claude and select its history below. Account labels are your saved space names, not verified provider identities.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Open each space to check its account. Account review opens its existing history without sharing or importing conversations. Quit Claude before reconnecting.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(application.profiles) { profile in
                      HStack {
                        Picker(profile.name, selection: Binding(get: { namespaces[profile.storageID] ?? "" },
                            set: { value in namespaces[profile.storageID] = value.isEmpty ? nil : value })) {
                            if library?.bindings[profile.storageID.uuidString] == nil {
                                Text("Not linked").tag("")
                            }
                            ForEach(candidates[profile.storageID] ?? []) { candidate in
                                Text(candidate.label)
                                    .tag(candidate.id)
                            }
                        }
                        Button("Open to Review") {
                            if let reviewAccount { reviewAccount(profile) }
                            else { Task { await store.openConversationAccountForReview(application: application, profile: profile) } }
                        }
                        .accessibilityLabel(Text("Open \(profile.name) for Account Review"))
                      }
                    }
                }
            }.frame(maxHeight: 220)
            Text("Original histories and recovery copies are retained. Conflicting versions will be listed for review. Earlier Parallax versions cannot switch migrated groups.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("I confirmed which account belongs to each selected history.", isOn: $confirmedAccounts)
                .disabled(artifactCount == nil)
            if artifactCount == nil, !namespaces.isEmpty, message == nil {
                ProgressView("Checking saved histories…").controlSize(.small)
            }
            if let artifactCount, artifactCount > 0 {
                Text(ClaudeArtifactReview.sharedHistoryWarning(count: artifactCount)).font(.callout)
            }
            if unreviewedCount > 0 {
                Text("\(unreviewedCount) conversations could not be checked for artifact references. Review their original histories separately.").font(.caption)
            }
            Text("Only the selected spaces will share history. Adding another space requires another review.")
                .font(.caption).foregroundStyle(.secondary)
            Button(reconnecting ? String(localized: "Reconnect Accounts") : String(localized: "Share Selected Histories")) {
                Task { await enroll() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(namespaces.count < (allAccounts ? 1 : 2) || namespaces[source.storageID] == nil || !confirmedAccounts || artifactCount == nil)
            if reconnecting {
                Button("Cancel") { reconnecting = false; namespaces = [:] }
            }
        }
    }

    private func libraryControls(_ library: ConversationLibrary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open an account with its shared history. Selecting a particular conversation is optional.")
                .font(.callout)
            TextField("Search conversations or projects", text: $search).textFieldStyle(.roundedBorder)
            List(selection: $selectedConversation) {
                ForEach(ConversationSearch.results(in: library, query: search)) { conversation in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(conversation.title)
                        if let revision = conversation.revisions[conversation.head] {
                            HStack {
                                Text(URL(fileURLWithPath: revision.workingDirectory).lastPathComponent)
                                Spacer()
                                Text(Date(timeIntervalSince1970: revision.lastActivityAt / 1000), style: .date)
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }.tag(conversation.id)
                }
            }.frame(height: 160)
            if let selectedConversation, let selected = library.conversations[selectedConversation] {
                HStack {
                    Text(selected.title).lineLimit(1)
                    Spacer()
                    Button("Clear Selection") { self.selectedConversation = nil }
                }.font(.caption)
            } else {
                Text("Open without selecting a conversation").font(.caption).foregroundStyle(.secondary)
            }
            Picker("Account", selection: $targetProfile) {
                Text("Choose an account").tag(nil as UUID?)
                ForEach(application.profiles.filter { library.bindings[$0.storageID.uuidString] != nil }) { profile in
                    Text(profile.name).tag(Optional(profile.storageID))
                }
            }
            Text("Claude may require import review. The configured account label does not confirm the live login; Parallax does not copy credentials or send a message for you.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Switch Account") { switchAccount() }
                    .buttonStyle(.borderedProminent)
                    .disabled(targetProfile == nil || library.handoff != nil)
                    .accessibilityIdentifier("conversation-library.switch")
                if library.handoff != nil {
                    Button("Retry Switch") {
                        guard let pending = library.handoff else { return }
                        Task {
                            busy = true
                            defer { busy = false }
                            do {
                                let target = try await store.recoverConversationSwitch(application: application, source: source, pending: pending)
                                message = nil
                                if let openAccount { openAccount(target) } else { store.launch(target) }
                            } catch { message = error.localizedDescription }
                        }
                    }
                        .disabled(library.handoff.map { store.launchPreparationTasks[$0.id] != nil } ?? true)
                    Button("Cancel Switch") { Task { await cancelSwitch() } }
                }
            }
            let problems = library.conversations.values.filter { !$0.problems.isEmpty }.sorted { $0.title < $1.title }
            if !problems.isEmpty {
                Text("Conversations to Review").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(problems) { conversation in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading) {
                                    Text(conversation.title)
                                    ForEach(conversation.problems.keys.sorted(), id: \.self) { key in
                                        if let problem = conversation.problems[key] {
                                            let accountLabel: String = library.bindings[key]?.label ?? key
                                            Text("\(accountLabel): \(problem.message)").font(.caption)
                                        }
                                    }
                                }
                                Spacer()
                                Button("Review Versions") { reviewing = conversation }
                            }
                        }
                    }
                }.frame(maxHeight: 180)
            }
            let unreadable = library.unavailableRecords.values.reduce(0) { $0 + $1.count }
            if unreadable > 0 { Text("\(unreadable) native session records could not be imported. Their original files are retained.").font(.caption) }
            Divider()
            Button("Reconnect Accounts…") { reconnecting = true; Task { await reload() } }
                .disabled(library.handoff != nil)
            Button("Use Separate Histories") { Task { await disconnect() } }
                .disabled(library.handoff != nil)
            Text("The shared library and all copied conversations remain saved.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func revisionReview(_ conversation: LibraryConversation) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(conversation.title).font(.headline)
            SpaceOperationStatusView(store: store)
            Text("Choose the saved version to continue. Other versions remain in the library. Selecting an account also restores a conversation removed or archived there.")
            ScrollView {
              VStack(alignment: .leading, spacing: 12) {
              ForEach(conversation.revisions.keys.sorted {
                  let left = conversation.revisions[$0]?.lastActivityAt ?? 0
                  let right = conversation.revisions[$1]?.lastActivityAt ?? 0
                  return left == right ? $0 < $1 : left > right
              }, id: \.self) { digest in
                if let revision = conversation.revisions[digest] {
                  HStack {
                    VStack(alignment: .leading) {
                        Text(library?.bindings[revision.sourceProfileID.uuidString]?.label ?? String(localized: "Saved version"))
                        Text(Date(timeIntervalSince1970: revision.lastActivityAt / 1000), style: .date)
                        Text(Date(timeIntervalSince1970: revision.lastActivityAt / 1000), style: .time)
                        DisclosureGroup("Version Details") {
                            Text(digest).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    Spacer()
                    Button("Preview") { Task { await preview(revision) } }
                    Button("Use This Version") {
                        // Only a removal or archive in the chosen account is restored there.
                        let restoring = targetProfile.flatMap { profile -> UUID? in
                            let problem = conversation.problems[profile.uuidString]
                            return problem == .missing || problem == .archived ? profile : nil
                        }
                        change { try ConversationLibraryService.chooseRevision(store: $0, conversationID: conversation.id,
                            revisionID: digest, restoringTo: restoring) }
                        reviewing = nil
                    }
                  }
                }
              }
              if let previewText { Text(previewText).font(.callout).textSelection(.enabled) }
              }
            }
            .frame(maxHeight: 400)
            Button("Close") { reviewing = nil }
        }.padding(24).frame(width: 500)
        .onDisappear { previewText = nil }
    }

    private func preview(_ revision: ConversationRevision) async {
        do {
            guard let group else { throw ConversationLibraryError.changed }
            let canonical = try store.conversationLibraryStore(group)
            previewText = try await Task.detached {
                try ConversationLibraryService.messagePreview(canonical.blob(revision.digest))
            }.value
        } catch { previewText = error.localizedDescription }
    }

    private func reload() async {
        do {
            allAccounts = try store.usesAllAccountHistory(application)
            group = try store.sharedHistoryGroup(application: application, profile: source)
            if group == nil { group = try store.allAccountHistoryGroup(application) }
            library = try store.conversationLibrary(application: application, profile: source)
            if library == nil, let group, group.conversationLibraryID != nil {
                library = try store.conversationLibraryStore(group).read()
            }
            if let library, !reconnecting {
                if selectedConversation != library.selectedConversationID { selectedConversation = library.selectedConversationID }
                if targetProfile == nil { targetProfile = library.activeProfileID }
            } else {
                var found: [UUID: [ConversationAccountCandidate]] = [:]
                for profile in application.profiles {
                    do {
                        let service = try store.claudeConversationService(application: application, profile: profile)
                        found[profile.storageID] = try await Task.detached {
                            try ConversationLibraryClaudeAdapter.candidates(service.files)
                        }.value
                    } catch { found[profile.storageID] = [] }
                }
                candidates = found
                if let library {
                    for binding in library.bindings.values where namespaces[binding.profileStorageID] == nil {
                        namespaces[binding.profileStorageID] = binding.namespace.joined(separator: "/")
                    }
                }
            }
        } catch { message = error.localizedDescription }
    }

    private func reviewArtifacts() async {
        let selection = namespaces
        guard !selection.isEmpty else { return }
        do {
            let inputs = try application.profiles.compactMap { profile -> (SecureManagedFileSystem, [String])? in
                guard let namespace = selection[profile.storageID] else { return nil }
                return (try store.claudeConversationService(application: application, profile: profile).files,
                    namespace.components(separatedBy: "/"))
            }
            let result = try await Task.detached {
                var urls = Set<String>()
                var unavailable = 0
                for (files, namespace) in inputs {
                    let review = try ConversationLibraryClaudeAdapter.artifactReview(files: files, namespace: namespace)
                    urls.formUnion(review.0); unavailable += review.1
                }
                return (urls.count, unavailable)
            }.value
            guard !Task.isCancelled, namespaces == selection else { return }
            artifactCount = result.0; unreviewedCount = result.1
        } catch {
            guard !Task.isCancelled, namespaces == selection else { return }
            message = error.localizedDescription
        }
    }

    private func enroll() async {
        busy = true; message = nil
        defer { busy = false }
        do {
            try await store.enrollConversationLibrary(application: application, source: source,
                namespaces: namespaces.mapValues { $0.components(separatedBy: "/") }, expected: group)
            reconnecting = false
            await reload()
        } catch { message = error.localizedDescription }
    }

    private func switchAccount() {
        do {
            guard let targetProfile, let profile = application.profiles.first(where: { $0.storageID == targetProfile }),
                  let group, group.conversationLibraryID != nil, store.canMutateLibrary() else { throw ConversationLibraryError.changed }
            try store.conversationLibraryStore(group).transaction { document in
                guard var value = document, value.handoff == nil else { throw ConversationLibraryError.busy }
                guard value.bindings[targetProfile.uuidString] != nil else { throw ConversationLibraryError.changed }
                guard selectedConversation == nil || value.conversations[selectedConversation ?? ""] != nil else { throw ConversationLibraryError.changed }
                value.selectedConversationID = selectedConversation
                document = value
            }
            store.selectedProfileID = profile.id
            message = nil
            if let openAccount { openAccount(profile) } else { store.launch(profile) }
        } catch { message = error.localizedDescription }
    }

    private func change(_ operation: @escaping (ConversationLibraryStore) throws -> Void) {
        Task {
            busy = true
            defer { busy = false }
            do { try await store.updateConversationLibrary(application: application, profile: source, operation); message = nil }
            catch { message = error.localizedDescription }
        }
    }

    private func cancelSwitch() async {
        guard let pending = library?.handoff else { return }
        busy = true
        defer { busy = false }
        if let task = store.launchPreparationTasks[pending.id] {
            task.cancel()
            await task.value
        }
        do {
            guard let group else { throw ConversationLibraryError.changed }
            let canonical = try store.conversationLibraryStore(group)
            guard let current = try canonical.read()?.handoff else {
                store.sharedHistoryRevision &+= 1
                if store.conversationSwitchRequestID == pending.id {
                    store.conversationSwitchMessage = nil
                }
                return
            }
            guard current.id == pending.id else { throw ConversationLibraryError.busy }
            // The same inactive-storage reservation as Retry rejects uncertain
            // writers; a cancelled task alone never proves that storage is idle.
            _ = try await store.recoverConversationSwitch(application: application, source: source, pending: current)
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func disconnect() async {
        busy = true; message = nil
        defer { busy = false }
        do {
            try await store.setSharedHistory(application: application, source: source, members: [], expected: group)
            dismiss()
        } catch { message = error.localizedDescription }
    }
}
