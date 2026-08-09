import SwiftUI

enum ProfileListAccessibilityRole: Sendable, Equatable {
    case profileSelection
    case launchAction
    case destructiveAction
    case cancelAction
}

struct ProfileListAccessibilityPresentation: Sendable, Equatable {
    let role: ProfileListAccessibilityRole
    let identifier: String
    let label: String
    let hint: String
}

enum ProfileListAccessibilityContract {
    static func traversal(
        for profile: LaunchProfile
    ) -> [ProfileListAccessibilityPresentation] {
        let item = ProfileListItemPresentation(profile: profile)
        return [
            item.rowAccessibility,
            item.launchAccessibility,
        ]
    }

    static let removalActions = [
        ProfileListAccessibilityPresentation(
            role: .destructiveAction,
            identifier: ProfileListActionIdentifier.removeOnly,
            label: String(localized: "Remove Space Only"),
            hint: String(
                localized: "Remove the space configuration and keep its data"
            )
        ),
        ProfileListAccessibilityPresentation(
            role: .destructiveAction,
            identifier:
                ProfileListActionIdentifier.removeAndArchiveData,
            label: String(localized: "Remove and Archive Data"),
            hint: String(
                localized: "Archive managed space data before removal"
            )
        ),
        ProfileListAccessibilityPresentation(
            role: .destructiveAction,
            identifier:
                ProfileListActionIdentifier.removeAndDeleteData,
            label: String(localized: "Remove and Delete Data"),
            hint: String(
                localized: "Permanently delete managed space data before removal"
            )
        ),
        ProfileListAccessibilityPresentation(
            role: .cancelAction,
            identifier: ProfileListActionIdentifier.cancelRemoval,
            label: String(localized: "Cancel"),
            hint: String(localized: "Cancel space removal")
        ),
    ]
}

enum ProfileListActionIdentifier {
    static let addProfile = "profile-list.add-profile"
    static let addFromTemplate = "profile-list.add-from-template"
    static let duplicateSelected = "profile-list.duplicate-selected"
    static let removeOnly = "profile-list.remove.keep-data"
    static let removeAndArchiveData =
        "profile-list.remove.archive-data"
    static let removeAndDeleteData =
        "profile-list.remove.delete-data"
    static let cancelRemoval = "profile-list.remove.cancel"

    static func row(_ profileID: UUID) -> String {
        scoped("row", id: profileID)
    }

    static func launch(_ profileID: UUID) -> String {
        scoped("launch", id: profileID)
    }

    static func duplicate(_ profileID: UUID) -> String {
        scoped("duplicate", id: profileID)
    }

    static func remove(_ profileID: UUID) -> String {
        scoped("remove", id: profileID)
    }

    static func template(_ templateID: UUID) -> String {
        scoped("template", id: templateID)
    }

    private static func scoped(_ action: String, id: UUID) -> String {
        "profile-list.\(action).\(id.uuidString.lowercased())"
    }
}

struct ProfileListItemPresentation: Identifiable, Sendable, Equatable {
    let id: LaunchProfile.ID
    let name: String
    let statusSummary: String
    let separationLabel: String

    init(
        profile: LaunchProfile,
        application: ManagedApplication? = nil,
        isRunning: Bool = false,
        launchStatus: SpaceLaunchStatusPresentation? = nil,
        now: Date = Date(),
        locale: Locale = .current
    ) {
        id = profile.id
        name = profile.name
        if let summary = launchStatus?.listSummary {
            statusSummary = summary
        } else if isRunning {
            statusSummary = String(localized: "Running now")
        } else if let lastOpened = profile.lastLaunchedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.dateTimeStyle = .named
            formatter.unitsStyle = .full
            let relative = formatter.localizedString(
                for: lastOpened,
                relativeTo: now
            )
            statusSummary = String(
                localized: "Last opened \(relative)"
            )
        } else {
            statusSummary = String(localized: "Never opened")
        }
        separationLabel = application.map {
            SpaceSeparationSummary(
                application: $0,
                profile: profile
            ).listLabel
        } ?? String(localized: "Custom setup")
    }

    var rowAccessibility: ProfileListAccessibilityPresentation {
        ProfileListAccessibilityPresentation(
            role: .profileSelection,
            identifier: ProfileListActionIdentifier.row(id),
            label: String(
                localized:
                    "\(name), \(statusSummary), \(separationLabel)"
            ),
            hint: String(localized: "Select the \(name) space")
        )
    }

    var launchAccessibility: ProfileListAccessibilityPresentation {
        ProfileListAccessibilityPresentation(
            role: .launchAction,
            identifier: ProfileListActionIdentifier.launch(id),
            label: String(localized: "Open \(name)"),
            hint: String(
                localized: "Open the \(name) space in this app"
            )
        )
    }
}

struct ProfileListTemplatePresentation: Identifiable, Sendable, Equatable {
    let id: ProfileTemplate.ID
    let title: String
    let accessibilityIdentifier: String

    init(
        template: ProfileTemplate,
        duplicateNameCount: Int = 1
    ) {
        id = template.id
        let identityPrefix = String(template.id.uuidString.prefix(8))
        title = duplicateNameCount > 1
            ? String(
                localized:
                    "\(template.name) — \(identityPrefix)"
            )
            : template.name
        accessibilityIdentifier = ProfileListActionIdentifier.template(
            template.id
        )
    }
}

struct ProfileListView: View {
    @Bindable var store: LibraryStore
    var application: ManagedApplication
    let requestNewSpace: (ProfileTemplate.ID?) -> Void
    @State private var profilePendingRemoval: LaunchProfile?

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
            Text("Duplicate or remove the selected space")
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
