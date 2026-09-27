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
