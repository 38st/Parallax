import SwiftUI
import UniformTypeIdentifiers

struct ProfileEditorView: View {
    @Bindable var store: LibraryStore
    var application: ManagedApplication
    var profile: LaunchProfile

    @State private var draft: LaunchProfile
    @State private var baseline: LaunchProfile
    @State private var baselineVersion: LibraryVersionToken
    @State private var isImportingCodexHome = false
    @State private var isRevealingSensitiveLiterals = false
    @State private var isAddingKeychainSecret = false
    @State private var keychainEnvironmentKey = ""
    @State private var keychainSecretValue = ""
    @State private var isSavingKeychainSecret = false
    @State private var stagedKeychainReferences:
        Set<EnvironmentSecretReference> = []
    @State private var pendingKeychainDeletionReferences:
        Set<EnvironmentSecretReference> = []
    @State private var isEditorActive = false
    @State private var isAdvancedSettingsExpanded: Bool

    init(store: LibraryStore, application: ManagedApplication, profile: LaunchProfile) {
        self.store = store
        self.application = application
        self.profile = profile
        let pending = store.pendingProfileEditingDraft(
            applicationID: application.id,
            profileID: profile.id
        )
        let initialDraft = pending?.draft ?? profile
        _draft = State(initialValue: initialDraft)
        _baseline = State(initialValue: pending?.baseline ?? profile)
        _baselineVersion = State(
            initialValue:
                pending?.baselineVersion
                ?? store.currentLibraryVersion ?? .missing
        )
        _stagedKeychainReferences = State(
            initialValue: pending?.stagedKeychainReferences ?? []
        )
        _pendingKeychainDeletionReferences = State(
            initialValue:
                pending?.pendingKeychainDeletionReferences ?? []
        )
        _isAdvancedSettingsExpanded = State(
            initialValue:
                LaunchArgumentParser.parse(
                    initialDraft.argumentsText
                ).hasErrors
                || LaunchEnvironmentParser.parse(
                    initialDraft.environmentText
                ).hasErrors
                || initialDraft.launchConfigurationTrust
                    == .importedPendingReview
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Form {
                    Section {
                        TextField("Space name", text: $draft.name)
                            .accessibilityIdentifier(
                                "space-editor.name.\(profile.id.uuidString.lowercased())"
                            )

                        LabeledContent("Separation") {
                            Text(separationSummary.detail)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }

                        LabeledContent("Notes") {
                            TextEditor(text: $draft.notes)
                                .frame(minHeight: 64)
                                .scrollContentBackground(.hidden)
                                .accessibilityLabel(Text("Space notes"))
                                .accessibilityIdentifier(
                                    "profile-editor.notes.\(profile.id.uuidString.lowercased())"
                                )
                        }
                    }

                    let warnings = store.warnings(for: application, profile: draft)
                    if !warnings.isEmpty {
                        Section("Compatibility") {
                            ForEach(warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }

                            Button {
                                if let updated =
                                    store
                                        .profileDraftApplyingRecommendedSettings(
                                            draft,
                                            for: application
                                        )
                                {
                                    draft = updated
                                }
                            } label: {
                                Label("Apply Recommended Settings", systemImage: "wand.and.stars")
                            }
                        }
                    }

                    DisclosureGroup(
                        isExpanded: $isAdvancedSettingsExpanded
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            advancedSettingsCard(
                                title: "Launch Arguments",
                                systemImage: "terminal",
                                description:
                                    "Pass options to the app when this space opens."
                            ) {
                                configurationEditor(
                                    text: $draft.argumentsText,
                                    accessibilityLabel: "Launch arguments",
                                    accessibilityIdentifier:
                                        "profile-editor.arguments.\(profile.id.uuidString.lowercased())"
                                )

                                Text("Separate arguments with spaces. Use quotes or backslashes to keep text together.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                parsingDiagnostics(
                                    argumentParseResult.diagnostics
                                )
                            }

                            advancedSettingsCard(
                                title: "Environment",
                                systemImage: "curlybraces",
                                description:
                                    "Set variables for this space, one per line."
                            ) {
                                configurationEditor(
                                    text: $draft.environmentText,
                                    accessibilityLabel:
                                        "Environment configuration",
                                    accessibilityIdentifier:
                                        "profile-editor.environment.\(profile.id.uuidString.lowercased())"
                                )

                                Text("Use KEY=value or unset KEY. Later entries with the same name take precedence.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                parsingDiagnostics(
                                    environmentParseResult.diagnostics
                                )

                                Label(
                                    "Literal values are saved in plaintext. Store secrets in Keychain.",
                                    systemImage: "exclamationmark.shield"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)

                                environmentSecurityControls
                            }

                            advancedSettingsCard(
                                title: "Environment Inheritance",
                                systemImage: "arrow.triangle.branch",
                                description:
                                    "Choose how much of Parallax’s environment reaches the app."
                            ) {
                                Toggle(
                                    "Inherit all process variables",
                                    isOn: inheritsProcessEnvironment
                                )

                                if draft.childEnvironmentPolicy
                                    == .inheritProcessEnvironment {
                                    Label(
                                        "May include API keys, tokens, and SSH agent sockets. Space-specific values still take precedence.",
                                        systemImage:
                                            "exclamationmark.triangle.fill"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                } else {
                                    Label(
                                        "Recommended: only trusted identity, path, locale, and temporary-directory values are inherited.",
                                        systemImage: "checkmark.shield"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                            }

                            if draft.launchConfigurationTrust
                                == .importedPendingReview {
                                Label(
                                    "Review every argument and environment operation before opening this imported space.",
                                    systemImage:
                                        "shield.lefthalf.filled.badge.checkmark"
                                )
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 4)
                            }

                            advancedSettingsCard(
                                title: "Browsing & App Data",
                                systemImage: "externaldrive",
                                description:
                                    "Inspect this space’s storage and isolation health."
                            ) {
                                profileDataSummary
                            }

                            advancedSettingsCard(
                                title: "Launch Preview",
                                systemImage: "play.square",
                                description:
                                    "Review the effective configuration before opening."
                            ) {
                                launchPreview
                            }
                        }
                        .padding(.top, 12)
                    } label: {
                        Label(
                            "Advanced Settings",
                            systemImage: "gearshape.2"
                        )
                        .accessibilityHint(
                            Text(
                                "Show launch arguments, environment variables, data actions, health checks, and preview"
                            )
                        )
                    }
                }
                .formStyle(.grouped)

                ViewThatFits(in: .horizontal) {
                    footerControls(axis: .horizontal)
                    footerControls(axis: .vertical)
                }
                .padding(.horizontal, 20)
            }
            .padding(.vertical, 20)
        }
        .onChange(of: profile) { _, newValue in
            if newValue.id != baseline.id
                || newValue.storageID != baseline.storageID
                || draft == baseline
            {
                let abandonedReferences = stagedKeychainReferences
                stagedKeychainReferences = []
                pendingKeychainDeletionReferences = []
                draft = newValue
                baseline = newValue
                baselineVersion =
                    store.currentLibraryVersion ?? baselineVersion
                discardKeychainReferences(abandonedReferences)
            }
        }
        .onChange(of: profile.id) { _, _ in
            isRevealingSensitiveLiterals = false
        }
        .onChange(of: draft) { _, newValue in
            rememberDraft()
            if LaunchArgumentParser.parse(
                newValue.argumentsText
            ).hasErrors
                || LaunchEnvironmentParser.parse(
                    newValue.environmentText
                ).hasErrors
                || newValue.launchConfigurationTrust
                    == .importedPendingReview
            {
                isAdvancedSettingsExpanded = true
            }
        }
        .fileImporter(
            isPresented: $isImportingCodexHome,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    store.errorMessage = String(
                        localized:
                            "The file provider returned no folder."
                    )
                    return
                }
                draft = store.profileDraftUsingCodexHome(
                    url,
                    profile: draft
                )
            case .failure(let error):
                if let message =
                    FileImporterFailure.userFacingMessage(
                        for: error
                    )
                {
                    store.errorMessage = message
                }
            }
        }
        .sheet(isPresented: $isAddingKeychainSecret) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add Keychain Secret")
                    .font(.title2.bold())
                TextField(
                    "Environment variable name",
                    text: $keychainEnvironmentKey
                )
                SecureField(
                    "Secret value",
                    text: $keychainSecretValue
                )
                Text(
                    "The secret value is stored in the macOS Keychain. The Parallax library stores only an opaque reference."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        keychainSecretValue = ""
                        isAddingKeychainSecret = false
                    }
                    Button("Save to Keychain") {
                        let key = keychainEnvironmentKey
                        let secret = keychainSecretValue
                        let sourceDraft = draft
                        keychainSecretValue = ""
                        isSavingKeychainSecret = true
                        Task {
                            let staged = await store.stageKeychainSecret(
                                secret,
                                environmentKey: key,
                                in: sourceDraft
                            )
                            isSavingKeychainSecret = false
                            if let staged {
                                if isEditorActive, draft == sourceDraft {
                                    draft = staged.profile
                                    stagedKeychainReferences.insert(
                                        staged.reference
                                    )
                                    rememberDraft()
                                    keychainEnvironmentKey = ""
                                    isAddingKeychainSecret = false
                                } else {
                                    _ = await store
                                        .discardKeychainSecret(
                                            staged.reference
                                        )
                                }
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        isSavingKeychainSecret
                            || keychainEnvironmentKey.isEmpty
                            || keychainSecretValue.isEmpty
                    )
                }
            }
            .padding(24)
            .frame(width: 440)
        }
        .onAppear {
            isEditorActive = true
        }
        .onDisappear {
            isEditorActive = false
            rememberDraft()
        }
    }

    private func advancedSettingsCard<Content: View>(
        title: LocalizedStringKey,
        systemImage: String,
        description: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 22, height: 22)
                    .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                content()
            }
            .padding(.leading, 32)
        }
        .padding(14)
        .background(
            Color.secondary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
    }

    private func configurationEditor(
        text: Binding<String>,
        accessibilityLabel: LocalizedStringKey,
        accessibilityIdentifier: String
    ) -> some View {
        TextEditor(text: text)
            .font(.system(.callout, design: .monospaced))
            .frame(minHeight: 82)
            .padding(6)
            .scrollContentBackground(.hidden)
            .background(
                Color(nsColor: .textBackgroundColor),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            }
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private var environmentSecurityControls: some View {
        HStack(spacing: 10) {
            if !environmentSensitivityOptions.isEmpty {
                Menu {
                    ForEach(
                        environmentSensitivityOptions,
                        id: \.key
                    ) { option in
                        if option.isKeychainReference {
                            Toggle(
                                String(
                                    localized:
                                        "\(option.key) (Keychain reference)"
                                ),
                                isOn: .constant(true)
                            )
                            .disabled(true)
                        } else if option.isAutomaticallySensitive {
                            Toggle(
                                String(
                                    localized:
                                        "\(option.key) (Automatically detected)"
                                ),
                                isOn: .constant(true)
                            )
                            .disabled(true)
                        } else {
                            Toggle(
                                option.key,
                                isOn: sensitiveKeyBinding(for: option.key)
                            )
                        }
                    }
                } label: {
                    Label("Redaction", systemImage: "eye.slash")
                }
                .help(
                    "Choose environment values to redact in previews and exports"
                )
            }

            Button {
                keychainEnvironmentKey = ""
                keychainSecretValue = ""
                isAddingKeychainSecret = true
            } label: {
                Label("Add Secret", systemImage: "key")
            }
        }
        .buttonStyle(.bordered)

        ForEach(
            environmentSensitivityOptions.filter(\.isKeychainReference),
            id: \.key
        ) { option in
            HStack {
                Label(option.key, systemImage: "key.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(role: .destructive) {
                    removeKeychainSecret(for: option.key)
                } label: {
                    Label("Remove", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help("Remove \(option.key) from Keychain")
            }
        }
    }

    private func removeKeychainSecret(for key: String) {
        guard
            let removal = store.profileDraftRemovingKeychainSecret(
                environmentKey: key,
                from: draft
            )
        else { return }

        draft = removal.profile
        if stagedKeychainReferences.remove(removal.reference) != nil {
            discardKeychainReferences([removal.reference])
        } else {
            pendingKeychainDeletionReferences.insert(removal.reference)
        }
        rememberDraft()
    }

    private var profileDataSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        store.profileFolderDisplayPath(
                            for: application,
                            profile: draft
                        )
                    )
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)

                    Text(healthSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                profileDataMenu
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(store.healthItems(for: application, profile: draft), id: \.label) { item in
                    GridRow {
                        Image(systemName: item.isHealthy ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(item.isHealthy ? .green : .secondary)
                            .accessibilityHidden(true)
                        Text(item.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        Text(
                            item.isHealthy
                                ? String(
                                    localized:
                                        "\(item.label): passing"
                                )
                                : String(
                                    localized:
                                        "\(item.label): not passing"
                                )
                        )
                    )
                }
            }
        }
    }

    private var profileDataMenu: some View {
        Menu {
            Button {
                store.revealProfileFolder(for: application, profile: draft)
            } label: {
                Label("Reveal Space Folder", systemImage: "folder")
            }

            if store.shouldShowCodexHomeActions(
                for: application,
                profile: draft
            ) {
                Button {
                    store.revealCodexHome(for: application, profile: draft)
                } label: {
                    Label("Reveal Codex Home", systemImage: "house")
                }

                Button {
                    isImportingCodexHome = true
                } label: {
                    Label("Use Existing Codex Home", systemImage: "square.and.arrow.down")
                }
            }

            if store.shouldShowUserDataActions(
                for: application,
                profile: draft
            ) {
                Button {
                    store.revealUserData(for: application, profile: draft)
                } label: {
                    Label("Reveal User Data", systemImage: "globe")
                }
            }

            Divider()

            Button(role: .destructive) {
                store.requestClearProfileData(
                    for: application,
                    profile: profile
                )
            } label: {
                Label("Clear Data", systemImage: "trash")
            }
        } label: {
            Label(
                "Browsing and App Data",
                systemImage: "ellipsis.circle"
            )
        }
        .menuStyle(.borderlessButton)
        .help("Browsing and App Data Actions")
    }

    private var launchPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Arguments") {
                Text(argumentSummary)
                    .foregroundStyle(.secondary)
            }

            LabeledContent("Environment") {
                Text(environmentSummary)
                    .foregroundStyle(.secondary)
            }

            if environmentPreviewLines.contains(where: \.isRevealable) {
                Button {
                    isRevealingSensitiveLiterals.toggle()
                } label: {
                    Label(
                        isRevealingSensitiveLiterals
                            ? String(
                                localized: "Hide Sensitive Literals"
                            )
                            : String(
                                localized: "Reveal Sensitive Literals"
                            ),
                        systemImage: isRevealingSensitiveLiterals
                            ? "eye.slash"
                            : "eye"
                    )
                }
                .buttonStyle(.link)
                .help(
                    isRevealingSensitiveLiterals
                        ? String(
                            localized:
                                "Hide sensitive literal values in this preview"
                        )
                        : String(
                            localized:
                                "Temporarily reveal sensitive literal values in this window"
                        )
                )
            }

            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(
                        Array(argumentPreviewLines.enumerated()),
                        id: \.offset
                    ) { _, argument in
                        Text(argument)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    ForEach(
                        Array(environmentPreviewLines.enumerated()),
                        id: \.offset
                    ) { _, item in
                        Text(item.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(
                                item.isSensitive ? .secondary : .primary
                            )
                            .textSelection(.enabled)
                    }

                    if argumentPreviewLines.isEmpty
                        && environmentPreviewLines.isEmpty {
                        Text("No launch configuration")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text("Keychain references remain redacted and are resolved only when a launch is prepared.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
    }

    private var healthSummary: String {
        let items = store.healthItems(for: application, profile: draft)
        let healthyCount = items.filter(\.isHealthy).count
        return String(
            localized:
                "\(healthyCount) of \(items.count) checks passing"
        )
    }

    private var separationSummary: SpaceSeparationSummary {
        SpaceSeparationSummary(
            application: application,
            profile: draft
        )
    }

    private var actionPresentation:
        SpaceEditorActionPresentation
    {
        SpaceEditorActionPresentation(
            draft: draft,
            baseline: baseline
        )
    }

    private var argumentSummary: String {
        let count = argumentParseResult.tokens.count
        return count == 0
            ? String(localized: "None")
            : LocalizedCount.launchArguments(count)
    }

    private var environmentSummary: String {
        let count = environmentParseResult.entries.count
        return count == 0
            ? String(localized: "None")
            : LocalizedCount.environmentOperations(count)
    }

    private var argumentParseResult: LaunchArgumentParseResult {
        LaunchArgumentParser.parse(draft.argumentsText)
    }

    private var environmentParseResult: LaunchEnvironmentParseResult {
        LaunchEnvironmentParser.parse(draft.environmentText)
    }

    private var argumentPreviewLines: [String] {
        ProfileEditorSecurityPresentation.argumentPreview(
            for: draft.argumentsText
        )
    }

    private var environmentPreviewLines: [ProfileEditorEnvironmentPreviewLine] {
        ProfileEditorSecurityPresentation.environmentPreview(
            for: draft.environmentText,
            explicitSensitiveKeys: Set(draft.sensitiveEnvironmentKeys),
            revealSensitiveLiterals: isRevealingSensitiveLiterals,
            childEnvironmentPolicy: draft.childEnvironmentPolicy,
            identity: .current,
            processEnvironment: ProcessInfo.processInfo.environment
        )
    }

    private var environmentSensitivityOptions: [ProfileEditorEnvironmentSensitivityOption] {
        ProfileEditorSecurityPresentation.environmentSensitivityOptions(
            for: draft.environmentText
        )
    }

    private var inheritsProcessEnvironment: Binding<Bool> {
        Binding(
            get: {
                draft.childEnvironmentPolicy == .inheritProcessEnvironment
            },
            set: { shouldInherit in
                draft.childEnvironmentPolicy = shouldInherit
                    ? .inheritProcessEnvironment
                    : .safeDefault
            }
        )
    }

    private func sensitiveKeyBinding(for key: String) -> Binding<Bool> {
        Binding(
            get: {
                Set(draft.sensitiveEnvironmentKeys.map { $0.uppercased() })
                    .contains(key.uppercased())
            },
            set: { isSensitive in
                draft.sensitiveEnvironmentKeys =
                    ProfileEditorSecurityPresentation.updatingSensitiveKeys(
                        draft.sensitiveEnvironmentKeys,
                        key: key,
                        isSensitive: isSensitive
                    )
            }
        )
    }

    @ViewBuilder
    private func parsingDiagnostics(
        _ diagnostics: [LaunchParsingDiagnostic]
    ) -> some View {
        ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    diagnostic.message,
                    systemImage: diagnostic.severity == .error
                        ? "xmark.circle.fill"
                        : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(
                    diagnostic.severity == .error ? .red : .orange
                )

                Text(
                    ProfileEditorSecurityPresentation.locationDescription(
                        diagnostic.range
                    )
                )
                .foregroundStyle(.secondary)

                if let relatedRange = diagnostic.relatedRange {
                    Text(
                        String(
                            localized: "Related entry: \(ProfileEditorSecurityPresentation.locationDescription(relatedRange))"
                        )
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func footerControls(axis: Axis) -> some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))

        layout {
            Button("Discard Changes") {
                revertDraft()
            }
            .disabled(draft == baseline || isSavingKeychainSecret)
            .keyboardShortcut(.cancelAction)

            if axis == .horizontal {
                Spacer()
            }

            if let validationMessage =
                actionPresentation.validationMessage,
               actionPresentation.isDirty
            {
                Label(
                    validationMessage,
                    systemImage: "xmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityIdentifier(
                    UIAutomationContract.editorValidationError
                )
            }

            if actionPresentation.showsSave {
                Button("Save") {
                    applyDraft()
                }
                .disabled(isSavingKeychainSecret)
                .keyboardShortcut("s", modifiers: .command)
                .accessibilityIdentifier(
                    UIAutomationContract.editorSave
                )
            }

            Button {
                saveAndOpen()
            } label: {
                Label(
                    actionPresentation.primaryTitle,
                    systemImage: "arrow.up.forward.app"
                )
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(
                !actionPresentation.canOpen
                    || isSavingKeychainSecret
            )
            .accessibilityIdentifier(
                UIAutomationContract.editorSaveAndOpen
            )
            .accessibilityHint(
                Text(
                    actionPresentation.isDirty
                        ? "Save these changes, then open this exact space"
                        : "Open this space in the selected app"
                )
            )

            if let launchStatusMessage =
                store.launchStatusMessage(
                    for: application,
                    profile: profile
                )
            {
                Text(launchStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @discardableResult
    private func applyDraft() -> LaunchProfile? {
        guard store.applyProfileEdit(
            draft: draft,
            baseline: baseline,
            applicationID: application.id,
            baselineVersion: baselineVersion
        ) else {
            return nil
        }
        guard
            let persistedApplication =
                store.applications.first(where: {
                    $0.id == application.id
                }),
            let persisted = persistedApplication.profiles.first(where: {
                $0.id == profile.id
            })
        else {
            return nil
        }
        draft = persisted
        baseline = persisted
        baselineVersion =
            store.currentLibraryVersion ?? baselineVersion
        let retainedReferences = keychainReferences(in: persisted)
        let obsoleteStaged =
            stagedKeychainReferences.subtracting(retainedReferences)
        let referencesToDelete =
            pendingKeychainDeletionReferences.union(obsoleteStaged)
        stagedKeychainReferences = []
        pendingKeychainDeletionReferences = []
        store.forgetProfileEditingDraft(profileID: persisted.id)
        discardKeychainReferences(referencesToDelete)
        return persisted
    }

    private func saveAndOpen() {
        SpaceEditorWorkflow.saveAndOpen(
            draft: draft,
            baseline: baseline,
            save: applyDraft,
            open: store.launch
        )
    }

    private func revertDraft() {
        let staged = stagedKeychainReferences
        stagedKeychainReferences = []
        pendingKeychainDeletionReferences = []
        draft = baseline
        store.forgetProfileEditingDraft(profileID: profile.id)
        discardKeychainReferences(staged)
    }

    private func rememberDraft() {
        store.rememberProfileEditingDraft(
            applicationID: application.id,
            draft: draft,
            baseline: baseline,
            baselineVersion: baselineVersion,
            stagedKeychainReferences: stagedKeychainReferences,
            pendingKeychainDeletionReferences:
                pendingKeychainDeletionReferences
        )
    }

    private func discardKeychainReferences(
        _ references: Set<EnvironmentSecretReference>
    ) {
        guard !references.isEmpty else { return }
        Task {
            for reference in references {
                _ = await store.discardKeychainSecret(reference)
            }
        }
    }

    private func keychainReferences(
        in profile: LaunchProfile
    ) -> Set<EnvironmentSecretReference> {
        Set(
            LaunchEnvironmentParser.parse(profile.environmentText)
                .effectiveValues.values.compactMap {
                    EnvironmentSecretReference(token: $0)
                }
        )
    }
}

struct ProfileEditorEnvironmentPreviewLine: Equatable {
    let text: String
    let isSensitive: Bool
    let isRevealable: Bool
}

struct ProfileEditorEnvironmentSensitivityOption: Equatable {
    let key: String
    let isKeychainReference: Bool
    let isAutomaticallySensitive: Bool
}

enum ProfileEditorSecurityPresentation {
    static func argumentPreview(for text: String) -> [String] {
        let tokens = LaunchArgumentParser.parse(text).tokens
        let redacted = SensitiveLaunchArgumentPolicy().redactedWords(
            in: tokens
        )
        return redacted.enumerated().map { index, value in
            if EnvironmentSecretReference(
                token: tokens[index].value
            ) != nil {
                return String(
                    localized: "<redacted Keychain reference>"
                )
            }
            return value
        }
    }

    static func environmentPreview(
        for text: String,
        explicitSensitiveKeys: Set<String>,
        revealSensitiveLiterals: Bool,
        childEnvironmentPolicy: ChildEnvironmentPolicy? = nil,
        identity: ChildEnvironmentIdentity = .current,
        processEnvironment: [String: String] =
            ProcessInfo.processInfo.environment
    ) -> [ProfileEditorEnvironmentPreviewLine] {
        let parsed = LaunchEnvironmentParser.parse(text)
        let policy = EnvironmentDisclosurePolicy(
            explicitSensitiveKeys: explicitSensitiveKeys
        )

        if let childEnvironmentPolicy {
            var effective = childEnvironmentPolicy.baseEnvironment(
                processEnvironment: processEnvironment,
                identity: identity
            ).mapValues { StoredEnvironmentValue.literal($0) }
            let expander = PathSpecificTildeExpander(
                homeDirectory: identity.homeDirectory
            )
            for entry in parsed.entries {
                switch entry.operation {
                case .set(let storedText):
                    effective[entry.name] = StoredEnvironmentValue(
                        storedText: expander.environmentValue(
                            storedText,
                            forKey: entry.name
                        )
                    )
                case .unset:
                    effective.removeValue(forKey: entry.name)
                }
            }
            return effective.keys.sorted().compactMap { key in
                guard let storedValue = effective[key] else { return nil }
                return previewLine(
                    key: key,
                    storedValue: storedValue,
                    policy: policy,
                    revealSensitiveLiterals: revealSensitiveLiterals
                )
            }
        }

        return parsed.entries.map { entry in
            switch entry.operation {
            case .unset:
                return ProfileEditorEnvironmentPreviewLine(
                    text: "unset \(entry.name)",
                    isSensitive: false,
                    isRevealable: false
                )

            case .set(let storedText):
                let storedValue = StoredEnvironmentValue(
                    storedText: storedText
                )
                return previewLine(
                    key: entry.name,
                    storedValue: storedValue,
                    policy: policy,
                    revealSensitiveLiterals: revealSensitiveLiterals
                )
            }
        }
    }

    private static func previewLine(
        key: String,
        storedValue: StoredEnvironmentValue,
        policy: EnvironmentDisclosurePolicy,
        revealSensitiveLiterals: Bool
    ) -> ProfileEditorEnvironmentPreviewLine {
        let assignment = StoredEnvironmentAssignment(
            key: key,
            value: storedValue
        )
        guard let preview = policy.preview(
            [assignment],
            revealSensitiveLiterals: revealSensitiveLiterals
        ).first else {
            return ProfileEditorEnvironmentPreviewLine(
                text: "\(key)=<redacted>",
                isSensitive: true,
                isRevealable: false
            )
        }
        let displayValue: String
        switch preview.displayValue {
        case .plain(let value):
            displayValue = value
        case .redacted:
            displayValue = String(localized: "<redacted>")
        }
        let isKeychainReference: Bool
        if case .secretReference = storedValue {
            isKeychainReference = true
        } else {
            isKeychainReference = false
        }
        return ProfileEditorEnvironmentPreviewLine(
            text: "\(key)=\(displayValue)",
            isSensitive: preview.isSensitive,
            isRevealable: preview.isSensitive && !isKeychainReference
        )
    }

    static func environmentSensitivityOptions(
        for text: String
    ) -> [ProfileEditorEnvironmentSensitivityOption] {
        let parsed = LaunchEnvironmentParser.parse(text)
        var effectiveValues: [String: StoredEnvironmentValue] = [:]
        for entry in parsed.entries {
            switch entry.operation {
            case .set(let storedText):
                effectiveValues[entry.name] = StoredEnvironmentValue(
                    storedText: storedText
                )
            case .unset:
                effectiveValues.removeValue(forKey: entry.name)
            }
        }
        let automaticClassifier = SensitiveEnvironmentKeyClassifier()
        return effectiveValues.keys.sorted().compactMap { key in
            guard let value = effectiveValues[key] else { return nil }
            let isKeychainReference: Bool
            if case .secretReference = value {
                isKeychainReference = true
            } else {
                isKeychainReference = false
            }
            return ProfileEditorEnvironmentSensitivityOption(
                key: key,
                isKeychainReference: isKeychainReference,
                isAutomaticallySensitive: isKeychainReference
                    || automaticClassifier.isSensitive(key)
            )
        }
    }

    static func updatingSensitiveKeys(
        _ current: [String],
        key: String,
        isSensitive: Bool
    ) -> [String] {
        var result = Set(current.map { $0.uppercased() })
        let normalizedKey = key.uppercased()
        if isSensitive {
            result.insert(normalizedKey)
        } else {
            result.remove(normalizedKey)
        }
        return result.sorted()
    }

    static func locationDescription(_ range: LaunchSourceRange) -> String {
        let finalColumn = max(range.start.column, range.end.column - 1)
        if range.start.line == range.end.line {
            return String(
                localized: "Line \(range.start.line), columns \(range.start.column)–\(finalColumn)"
            )
        }
        return String(
            localized: "Line \(range.start.line), column \(range.start.column) through line \(range.end.line), column \(finalColumn)"
        )
    }
}
