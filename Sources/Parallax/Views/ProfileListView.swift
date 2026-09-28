import SwiftUI

struct ProfileListView: View {
    @Bindable var store: LibraryStore
    var application: ManagedApplication
    let requestNewSpace: (ProfileTemplate.ID?) -> Void
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

                                Text(presentation.separationLabel)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            Text(presentation.rowAccessibility.label)
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

                        ViewThatFits(in: .horizontal) {
                            Button("Open") {
                                store.launch(profile)
                            }

                            Button {
                                store.launch(profile)
                            } label: {
                                Image(
                                    systemName:
                                        "arrow.up.forward.app"
                                )
                            }
                            .accessibilityLabel(Text("Open"))
                        }
                        .buttonStyle(.bordered)
                        .help("Open \(profile.name)")
                        .accessibilityLabel(
                            Text(
                                presentation.launchAccessibility.label
                            )
                        )
                        .accessibilityHint(
                            Text(
                                presentation.launchAccessibility.hint
                            )
                        )
                        .accessibilityIdentifier(
                            presentation.launchAccessibility.identifier
                        )
                    }
                    .tag(profile.id)
                    .accessibilityElement(children: .contain)
                    .contextMenu {
                        if [.claude, .codex].contains(LibraryStore.resolvedPreset(for: application)) {
                            Button("Shared History…") { sharedHistorySource = profile }
                        }
                        if LibraryStore.resolvedPreset(for: application) == .claude {
                            Button("Copy Claude Conversation…") { conversationCopySource = profile }
                        }
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
                }
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack {
                    newSpaceButton
                    templateMenu
                    selectedSpaceActions
                    Spacer()
                }

                VStack(alignment: .leading, spacing: 8) {
                    newSpaceButton
                    HStack {
                        templateMenu
                        selectedSpaceActions
                    }
                }
            }
            .padding(8)
        }
        .sheet(item: $conversationCopySource) { source in
            ClaudeConversationCopyView(store: store, application: application, source: source)
        }
        .sheet(item: $sharedHistorySource) { source in
            SharedHistoryView(store: store, application: application, source: source)
        }
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

    private var newSpaceButton: some View {
        Button {
            requestNewSpace(nil)
        } label: {
            Label("New Space", systemImage: "plus")
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
            if [.claude, .codex].contains(LibraryStore.resolvedPreset(for: application)) {
                Button("Shared History…") {
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
