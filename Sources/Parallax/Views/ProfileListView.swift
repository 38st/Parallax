import SwiftUI

struct ProfileListView: View {
    @Bindable var store: LibraryStore
    var application: ManagedApplication
    let requestNewSpace: (ProfileTemplate.ID?) -> Void
    var corporateStore: CorporateUsageStore? = nil
    @State private var pendingLaunch: LaunchProfile?
    @State private var editingProfile: LaunchProfile?
    @State private var accountProfile: LaunchProfile?
    @State private var terminalReview = SpaceTerminalReviewCoordinator()
    @State private var profilePendingRemoval: LaunchProfile?
    @State private var pendingStuckLaunchRecovery: StuckLaunchRecoveryRequest?
    @State private var conversationCopySource: LaunchProfile?
    @State private var sharedHistorySource: LaunchProfile?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Your Spaces")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            if LibraryStore.resolvedPreset(for: application) == .claude {
                ConversationAccountPicker(store: store, application: application) { sharedHistorySource = $0 }
            } else if LibraryStore.resolvedPreset(for: application) == .codex {
                CodexSharedWorkspaceView(store: store, application: application)
            }

            if usesMainCodexHistory {
                CodexMainOpenView(store: store, application: application, edit: { profile in
                    store.selectedProfileID = profile.id; editingProfile = profile
                })
                Spacer()
            } else {
            List(selection: $store.selectedProfileID) {
                ForEach(application.profiles) { profile in
                    let presentation = ProfileListItemPresentation(
                        profile: profile,
                        application: application,
                        isRunning: store.isSpaceRunning(
                            application: application,
                            profile: profile
                        ),
                        launchStatus: store.launchStatusPresentation(
                            for: application,
                            profile: profile
                        )
                    )

                    HStack(spacing: 8) {
                        Button {
                            store.selectedProfileID = profile.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .lineLimit(1)

                                Text(presentation.statusSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)

                                Text([.claude, .codex].contains(LibraryStore.resolvedPreset(for: application))
                                    ? profile.accountLink?.summary ?? String(localized: "Desktop account unknown")
                                    : presentation.separationLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            Text(presentation.rowAccessibility.label + " " + (profile.accountLink?.summary ?? ""))
                        )
                        .accessibilityHint(
                            Text(presentation.rowAccessibility.hint)
                        )
                        .accessibilityIdentifier(
                            presentation.rowAccessibility.identifier
                        )
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(
                            store.selectedProfileID == profile.id
                                ? .isSelected
                                : []
                        )

                        if let linkedID = profile.accountLink?.trackingAccountID,
                           let account = corporateStore?.trackedAccounts.first(where: { $0.id == linkedID }) {
                            SpaceUsageSummary(account: account, expectedEmail: profile.accountLink?.expectedIdentity).font(.caption)
                        }
                        SpaceOpenButton(store: store, application: application, profile: profile)
                            .accessibilityIdentifier(presentation.launchAccessibility.identifier)
                        Menu { rowActions(for: profile) } label: {
                            Image(systemName: "ellipsis.circle")
                        }.menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel(Text("Actions for \(profile.name)"))

                    }
                    .tag(profile.id)
                    .accessibilityElement(children: .contain)
                    .contextMenu { rowActions(for: profile) }
                }
            }

            }
            Divider()

            ViewThatFits(in: .horizontal) {
                HStack {
                    newSpaceButton
                    templateMenu
                    if !usesMainCodexHistory { selectedSpaceActions }
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    newSpaceButton
                    HStack {
                        templateMenu
                        if !usesMainCodexHistory { selectedSpaceActions }
                    }
                }
            }
            .padding(8)
        }
        .sheet(item: $editingProfile, onDismiss: launchPending) { profile in
            VStack(spacing: 0) {
                HStack {
                    Text("Edit Space").font(.headline)
                    Spacer()
                    Button("Done") { editingProfile = nil }
                        .disabled(hasUnsavedChanges(profile))
                }.padding()
                if hasUnsavedChanges(profile) {
                    Text("Save or discard your changes before closing.").font(.caption).foregroundStyle(.secondary)
                }
                if let current = store.applications.first(where: { $0.id == application.id }),
                   let saved = current.profiles.first(where: { $0.id == profile.id }) {
                    ProfileEditorView(store: store, application: current, profile: saved, openAfterSave: { profile in
                        pendingLaunch = profile; editingProfile = nil
                    })
                }
                SpaceOperationStatusView(store: store).padding()
            }.frame(width: 650, height: 680).interactiveDismissDisabled()
        }
        .sheet(item: $accountProfile) { profile in
            SpaceAccountDetailsView(store: store, corporateStore: corporateStore, application: application, profile: profile)
        }
        .sheet(item: $conversationCopySource) { source in
            ClaudeConversationCopyView(store: store, application: application, source: source)
                .safeAreaInset(edge: .bottom) { SpaceOperationStatusView(store: store).padding() }
        }
        .sheet(item: $sharedHistorySource, onDismiss: launchPending) { source in
            if LibraryStore.resolvedPreset(for: application) == .claude {
                ConversationLibraryView(store: store, application: application, source: source, openAccount: { profile in
                    pendingLaunch = profile; sharedHistorySource = nil
                })
            } else {
                SharedHistoryView(store: store, application: application, source: source)
                    .safeAreaInset(edge: .bottom) { SpaceOperationStatusView(store: store).padding() }
            }
        }
        .modifier(SpaceTerminalReviewPresentation(coordinator: terminalReview))
        .confirmationDialog(
            pendingStuckLaunchRecovery?.confirmationTitle ?? String(localized: "Clear Stuck Launch Record?"),
            isPresented: Binding(
                get: { pendingStuckLaunchRecovery != nil },
                set: { if !$0 { pendingStuckLaunchRecovery = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Clear Launch Record", role: .destructive) {
                if let request = pendingStuckLaunchRecovery {
                    store.confirmClearStuckLaunchRecord(request)
                }
                pendingStuckLaunchRecovery = nil
            }
            Button("Cancel", role: .cancel) {
                pendingStuckLaunchRecovery = nil
            }
        } message: {
            Text("Parallax cannot prove whether the earlier launch finished. Clearing its record may allow this space to open twice and corrupt its data if an unrecognized process is still using it. Space data will not be deleted.")
        }
        .confirmationDialog(
            "Remove \(profilePendingRemoval?.name ?? String(localized: "Space"))?",
            isPresented: Binding(
                get: { profilePendingRemoval != nil },
                set: { if !$0 { profilePendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let profilePendingRemoval {
                Button("Remove Space Only", role: .destructive) {
                    store.requestProfileRemoval(
                        for: application,
                        profile: profilePendingRemoval,
                        dataRemoval: .keep
                    )
                    self.profilePendingRemoval = nil
                }
                .accessibilityIdentifier(
                    ProfileListActionIdentifier.removeOnly
                )
                Button("Remove and Archive Data", role: .destructive) {
                    store.requestProfileRemoval(
                        for: application,
                        profile: profilePendingRemoval,
                        dataRemoval: .archive
                    )
                    self.profilePendingRemoval = nil
                }
                .accessibilityIdentifier(
                    ProfileListActionIdentifier.removeAndArchiveData
                )
                Button("Remove and Delete Data", role: .destructive) {
                    store.requestProfileRemoval(
                        for: application,
                        profile: profilePendingRemoval,
                        dataRemoval: .delete
                    )
                    self.profilePendingRemoval = nil
                }
                .accessibilityIdentifier(
                    ProfileListActionIdentifier.removeAndDeleteData
                )
            }
            Button("Cancel", role: .cancel) {
                profilePendingRemoval = nil
            }
            .accessibilityIdentifier(
                ProfileListActionIdentifier.cancelRemoval
            )
        } message: {
            Text(
                "Choose what to do with this space’s stored data folder."
            )
        }
    }

    private func launchPending() {
        guard let profile = pendingLaunch else { return }
        pendingLaunch = nil
        store.launch(profile)
    }

    private func hasUnsavedChanges(_ profile: LaunchProfile) -> Bool {
        guard let pending = store.pendingProfileEditingDraft(applicationID: application.id, profileID: profile.id) else { return false }
        return pending.draft != pending.baseline
    }

    @ViewBuilder
    private func rowActions(for profile: LaunchProfile) -> some View {

        Button("Edit Space…") { store.selectedProfileID = profile.id; editingProfile = profile }
        if [.claude, .codex].contains(LibraryStore.resolvedPreset(for: application)) {
            Button("Account & Usage…") { accountProfile = profile }
        }
        Divider()

        if !usesMainCodexHistory, [.claude, .codex].contains(LibraryStore.resolvedPreset(for: application)) {
            Button("History…") { sharedHistorySource = profile }
        }
        if LibraryStore.resolvedPreset(for: application) == .claude {
            Button("Copy Claude Conversation…") { conversationCopySource = profile }
        }
        terminalAndLinkActions(for: profile)

        if store.canRequestStuckLaunchRecovery(for: application, profile: profile) {
            Button("Clear Stuck Launch Record…") {
                pendingStuckLaunchRecovery = store.stuckLaunchRecoveryRequest(for: application, profile: profile)
            }
        }

        Button("Duplicate Space") {
            store.requestProfileDuplication(
                for: application,
                profile: profile
            )
        }
        .accessibilityLabel(
            Text("Duplicate the \(profile.name) space")
        )
        .accessibilityIdentifier(
            ProfileListActionIdentifier.duplicate(
                profile.id
            )
        )

        Button("Remove Space…", role: .destructive) {
            store.selectedProfileID = profile.id
            profilePendingRemoval = profile
        }
        .accessibilityLabel(
            Text("Remove the \(profile.name) space")
        )
        .accessibilityIdentifier(
            ProfileListActionIdentifier.remove(
                profile.id
            )
        )
        }

    private var usesMainCodexHistory: Bool {
        _ = store.sharedHistoryRevision
        return LibraryStore.resolvedPreset(for: application) == .codex
            && (try? store.codexSharedWorkspace(application)) != nil
    }

    private var newSpaceButton: some View {
        Button {
            requestNewSpace(nil)
        } label: {
            Label(LibraryStore.resolvedPreset(for: application) == .claude ? String(localized: "Add account") : String(localized: "New Space"), systemImage: "plus")
        }
        .buttonStyle(.borderedProminent)
        .help("Create a new space")
        .accessibilityHint(
            Text("Name a space and choose a starting point")
        )
        .accessibilityIdentifier(
            ProfileListActionIdentifier.addProfile
        )
    }

    @ViewBuilder
    private var templateMenu: some View {
        if !store.profileTemplates.isEmpty {
            Menu {
                ForEach(store.profileTemplates) { template in
                    let presentation =
                        ProfileListTemplatePresentation(
                            template: template,
                            duplicateNameCount:
                                store.profileTemplates.filter {
                                    normalizedTemplateName($0.name)
                                        == normalizedTemplateName(
                                            template.name
                                        )
                                }.count
                        )
                    Button(presentation.title) {
                        requestNewSpace(template.id)
                    }
                    .accessibilityIdentifier(
                        presentation.accessibilityIdentifier
                    )
                }
            } label: {
                Label(
                    "Templates",
                    systemImage: "square.grid.2x2"
                )
            }
            .help("Start From a Template")
            .accessibilityLabel(Text("Start From a Template"))
            .accessibilityIdentifier(
                ProfileListActionIdentifier.addFromTemplate
            )
        }
    }

    private var selectedSpaceActions: some View {
        Menu {
            if let selectedSpace {
                Button("Edit Space…") { editingProfile = selectedSpace }
                if [.claude, .codex].contains(LibraryStore.resolvedPreset(for: application)) {
                    Button("Account & Usage…") { accountProfile = selectedSpace }
                }
            }
            if [.claude, .codex].contains(LibraryStore.resolvedPreset(for: application)) {
                Button("History…") {
                    guard let selectedSpace else { return }
                    sharedHistorySource = selectedSpace
                }
            }
            if LibraryStore.resolvedPreset(for: application) == .claude {
                Button("Copy Claude Conversation…") {
                    guard let selectedSpace else { return }
                    conversationCopySource = selectedSpace
                }
            }
            if let selectedSpace {
                terminalAndLinkActions(for: selectedSpace)
            }

            Button("Duplicate Space") {
                guard let selectedSpace else { return }
                store.requestProfileDuplication(
                    for: application,
                    profile: selectedSpace
                )
            }

            Divider()

            Button("Remove Space…", role: .destructive) {
                guard let selectedSpace else { return }
                profilePendingRemoval = selectedSpace
            }
        } label: {
            Label("Space Actions", systemImage: "ellipsis.circle")
        }
        .disabled(selectedSpace == nil)
        .accessibilityHint(
            Text("Actions for the selected space")
        )
        .accessibilityIdentifier(
            ProfileListActionIdentifier.duplicateSelected
        )
    }

    @ViewBuilder
    private func terminalAndLinkActions(for profile: LaunchProfile) -> some View {
        if store.canOpenTerminalInSpace(for: application) {
            Button("Open Terminal in This Space") {
                Task { await store.openTerminalInSpace(for: application, profile: profile,
                    reviewImportedConfiguration: { await terminalReview.request($0) }) }
            }
        }
        Button("Copy Link to Space") {
            store.copyLinkToSpace(profile)
        }
        Divider()
    }

    private var selectedSpace: LaunchProfile? {
        guard let selectedProfileID = store.selectedProfileID else {
            return nil
        }
        return application.profiles.first {
            $0.id == selectedProfileID
        }
    }

    private func normalizedTemplateName(_ value: String) -> String {
        value.precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
