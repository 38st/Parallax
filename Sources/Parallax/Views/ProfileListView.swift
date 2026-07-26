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
            item.launchAccessibility,
            item.rowAccessibility,
        ]
    }

    static let removalActions = [
        ProfileListAccessibilityPresentation(
            role: .destructiveAction,
            identifier: ProfileListActionIdentifier.removeOnly,
            label: String(localized: "Remove Profile Only"),
            hint: String(
                localized: "Remove the profile configuration and keep its data"
            )
        ),
        ProfileListAccessibilityPresentation(
            role: .destructiveAction,
            identifier:
                ProfileListActionIdentifier.removeAndArchiveData,
            label: String(localized: "Remove and Archive Data"),
            hint: String(
                localized: "Archive managed profile data before removal"
            )
        ),
        ProfileListAccessibilityPresentation(
            role: .destructiveAction,
            identifier:
                ProfileListActionIdentifier.removeAndDeleteData,
            label: String(localized: "Remove and Delete Data"),
            hint: String(
                localized: "Permanently delete managed profile data before removal"
            )
        ),
        ProfileListAccessibilityPresentation(
            role: .cancelAction,
            identifier: ProfileListActionIdentifier.cancelRemoval,
            label: String(localized: "Cancel"),
            hint: String(localized: "Cancel profile removal")
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
    let argumentCount: Int

    init(profile: LaunchProfile) {
        id = profile.id
        name = profile.name
        argumentCount = profile.arguments.count
    }

    var argumentSummary: String {
        switch argumentCount {
        case 0:
            String(localized: "No launch arguments")
        case 1:
            String(localized: "1 argument")
        default:
            String(localized: "\(argumentCount) arguments")
        }
    }

    var rowAccessibility: ProfileListAccessibilityPresentation {
        ProfileListAccessibilityPresentation(
            role: .profileSelection,
            identifier: ProfileListActionIdentifier.row(id),
            label: String(localized: "\(name), \(argumentSummary)"),
            hint: String(localized: "Select \(name)")
        )
    }

    var launchAccessibility: ProfileListAccessibilityPresentation {
        ProfileListAccessibilityPresentation(
            role: .launchAction,
            identifier: ProfileListActionIdentifier.launch(id),
            label: String(localized: "Launch \(name)"),
            hint: String(
                localized: "Open \(name) in a new application instance"
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
    @State private var profilePendingRemoval: LaunchProfile?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $store.selectedProfileID) {
                ForEach(application.profiles) { profile in
                    let presentation = ProfileListItemPresentation(
                        profile: profile
                    )

                    HStack(spacing: 8) {
                        Button {
                            store.launch(profile)
                        } label: {
                            Label("Launch", systemImage: "play.fill")
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Launch \(profile.name)")
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

                        Button {
                            store.selectedProfileID = profile.id
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(profile.name)
                                    .lineLimit(1)

                                HStack(spacing: 5) {
                                    if store.hasCodexHomeConfigured(in: profile) {
                                        badge("Codex")
                                    } else if store.hasUserDataDirectoryConfigured(in: profile) {
                                        badge("Data Dir")
                                    }

                                    if let lastLaunchedAt = profile.lastLaunchedAt {
                                        Text("Last \(lastLaunchedAt.formatted(date: .omitted, time: .shortened))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Text(presentation.argumentSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                    }
                    .tag(profile.id)
                    .accessibilityElement(children: .contain)
                    .contextMenu {
                        Button("Duplicate") {
                            store.requestProfileDuplication(
                                for: application,
                                profile: profile
                            )
                        }
                        .accessibilityLabel(
                            Text("Duplicate \(profile.name)")
                        )
                        .accessibilityIdentifier(
                            ProfileListActionIdentifier.duplicate(
                                profile.id
                            )
                        )

                        Button("Remove", role: .destructive) {
                            store.selectedProfileID = profile.id
                            profilePendingRemoval = profile
                        }
                        .accessibilityLabel(
                            Text("Remove \(profile.name)")
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

            HStack {
                Button {
                    store.addProfile()
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add Smart Profile")
                .accessibilityLabel(Text("Add Profile"))
                .accessibilityIdentifier(
                    ProfileListActionIdentifier.addProfile
                )

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
                                store.addProfile(templateID: template.id)
                            }
                            .accessibilityIdentifier(
                                presentation.accessibilityIdentifier
                            )
                        }
                    } label: {
                        Label(
                            "Templates",
                            systemImage: "person.2.badge.gearshape"
                        )
                    }
                    .menuStyle(.borderlessButton)
                    .help("Add From Template")
                    .accessibilityLabel(Text("Add From Template"))
                    .accessibilityIdentifier(
                        ProfileListActionIdentifier.addFromTemplate
                    )
                }

                Button {
                    if let profile = store.selectedProfile {
                        store.requestProfileDuplication(
                            for: application,
                            profile: profile
                        )
                    }
                } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                .disabled(store.selectedProfile == nil)
                .accessibilityLabel(Text("Duplicate Selected Profile"))
                .accessibilityIdentifier(
                    ProfileListActionIdentifier.duplicateSelected
                )

                Spacer()
            }
            .labelStyle(.iconOnly)
            .padding(8)
        }
        .confirmationDialog(
            "Remove \(profilePendingRemoval?.name ?? "Profile")?",
            isPresented: Binding(
                get: { profilePendingRemoval != nil },
                set: { if !$0 { profilePendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let profilePendingRemoval {
                Button("Remove Profile Only", role: .destructive) {
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
            Text("Choose what to do with the profile's stored data folder.")
        }
    }

    private func badge(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.tertiary, in: Capsule())
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
