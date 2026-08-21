import Foundation

struct SpaceSeparationSummary: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case browsingData
        case codexData
        case custom
    }

    let kind: Kind
    let detail: String
    let listLabel: String

    init(
        application: ManagedApplication,
        profile: LaunchProfile
    ) {
        let preset = application.preset == .automatic
            ? AppPreset.detected(
                displayName: application.displayName,
                bundleIdentifier: application.bundleIdentifier
            )
            : application.preset
        let arguments = LaunchArgumentParser.parse(
            profile.argumentsText
        )
        let environment = LaunchEnvironmentParser.parse(
            profile.environmentText
        )
        let hasUserDataDirectory =
            UserDataDirectoryOptionResolver.resolve(
                in: arguments.tokens
            ).resolvedValue != nil
        let hasCodexHome =
            environment.effectiveValues["CODEX_HOME"]?
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty == false

        if preset.needsCodexHome,
           hasCodexHome,
           hasUserDataDirectory,
           !arguments.hasErrors,
           !environment.hasErrors
        {
            kind = .codexData
            detail = String(
                localized:
                    "Uses separate Codex settings and data for this space."
            )
            listLabel = String(localized: "Separate Codex data")
        } else if preset.supportsUserDataDir,
                  hasUserDataDirectory,
                  !arguments.hasErrors
        {
            kind = .browsingData
            detail = String(
                localized:
                    "Uses separate browsing data for this space."
            )
            listLabel = String(localized: "Separate browsing data")
        } else {
            kind = .custom
            detail = String(
                localized:
                    "Review Advanced Settings to confirm what this space keeps separate."
            )
            listLabel = String(localized: "Custom setup")
        }
    }
}

struct SpaceEditorActionPresentation: Equatable, Sendable {
    let isDirty: Bool
    let normalizedName: String?
    let hasParsingErrors: Bool
    let validationMessage: String?
    let nameValidationMessage: String?

    init(draft: LaunchProfile, baseline: LaunchProfile) {
        isDirty = draft != baseline
        let nameValidation = DisplayNameValidator.validate(
            draft.name
        )
        normalizedName = nameValidation.normalized
        nameValidationMessage = isDirty
            ? nameValidation.issue?.message(for: .space)
            : nil
        let arguments = LaunchArgumentParser.parse(
            draft.argumentsText
        )
        let environment = LaunchEnvironmentParser.parse(
            draft.environmentText
        )
        hasParsingErrors =
            arguments.hasErrors || environment.hasErrors
        validationMessage = (
            arguments.diagnostics + environment.diagnostics
        ).first(where: { $0.severity == .error })?.message
    }

    var showsSave: Bool {
        isDirty
    }

    var primaryTitle: String {
        isDirty
            ? String(localized: "Save & Open")
            : String(localized: "Open Space")
    }

    var canSave: Bool {
        isDirty && normalizedName != nil
    }

    var canOpen: Bool {
        !isDirty || (
            normalizedName != nil && !hasParsingErrors
        )
    }
}

enum SpaceEditorWorkflow {
    @discardableResult
    static func saveAndOpen(
        draft: LaunchProfile,
        baseline: LaunchProfile,
        save: () -> LaunchProfile?,
        open: (LaunchProfile) -> Void
    ) -> Bool {
        if draft != baseline {
            guard let persisted = save() else {
                return false
            }
            open(persisted)
        } else {
            open(draft)
        }
        return true
    }
}

struct NewSpaceChoice:
    Identifiable,
    Hashable,
    Sendable
{
    enum Kind: Hashable, Sendable {
        case blank
        case template(ProfileTemplate.ID)
    }

    let kind: Kind
    let title: String

    var id: String {
        switch kind {
        case .blank:
            "blank"
        case .template(let id):
            "template-\(id.uuidString.lowercased())"
        }
    }

    var templateID: ProfileTemplate.ID? {
        if case .template(let id) = kind {
            id
        } else {
            nil
        }
    }

    static func available(
        templates: [ProfileTemplate]
    ) -> [NewSpaceChoice] {
        templates.map {
            NewSpaceChoice(
                kind: .template($0.id),
                title: $0.name
            )
        } + [
            NewSpaceChoice(
                kind: .blank,
                title: String(localized: "Blank")
            )
        ]
    }
}

struct NewSpaceDraft: Equatable, Sendable {
    var name: String
    var choice: NewSpaceChoice

    init(
        choices: [NewSpaceChoice],
        preferredTemplateID: ProfileTemplate.ID? = nil
    ) {
        precondition(!choices.isEmpty)
        let preferred = choices.first {
            $0.templateID == preferredTemplateID
        }
        let work = choices.first {
            $0.title.compare(
                String(localized: "Work"),
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }
        choice = preferred ?? work ?? choices[0]
        name = choice.title
    }

    mutating func select(_ newChoice: NewSpaceChoice) {
        let priorSuggestedName = choice.title
        let shouldUpdateName =
            DisplayNameValidator.normalized(name) == nil
            || name == priorSuggestedName
        choice = newChoice
        if shouldUpdateName {
            name = newChoice.title
        }
    }

    var canCreate: Bool {
        DisplayNameValidator.normalized(name) != nil
    }

    var nameValidationMessage: String? {
        DisplayNameValidator.validate(name)
            .issue?.message(for: .space)
    }

    func separationSummary(
        for application: ManagedApplication
    ) -> String {
        let preset = application.preset == .automatic
            ? AppPreset.detected(
                displayName: application.displayName,
                bundleIdentifier: application.bundleIdentifier
            )
            : application.preset
        if preset.needsCodexHome {
            return String(
                localized:
                    "Parallax will set up separate Codex settings and app data for this space."
            )
        }
        if preset.supportsUserDataDir {
            return String(
                localized:
                    "Parallax will set up separate browsing data for this space."
            )
        }
        return String(
            localized:
                "You can configure what this space keeps separate in Advanced Settings."
        )
    }
}
