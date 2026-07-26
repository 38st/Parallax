import SwiftUI
import UniformTypeIdentifiers

struct ProfileEditorView: View {
    @Bindable var store: LibraryStore
    var application: ManagedApplication
    var profile: LaunchProfile

    @State private var draft: LaunchProfile
    @State private var baseline: LaunchProfile
    @State private var baselineVersion: LibraryVersionToken
    @State private var isConfirmingRemoveProfile = false
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

    init(store: LibraryStore, application: ManagedApplication, profile: LaunchProfile) {
        self.store = store
        self.application = application
        self.profile = profile
        _draft = State(initialValue: profile)
        _baseline = State(initialValue: profile)
        _baselineVersion = State(
            initialValue: store.currentLibraryVersion ?? .missing
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Form {
                    TextField("Profile name", text: $draft.name)

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

                    Section("Launch Arguments") {
                        TextEditor(text: $draft.argumentsText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 86)
                            .scrollContentBackground(.hidden)
                            .accessibilityLabel(Text("Launch arguments"))
                            .accessibilityIdentifier(
                                "profile-editor.arguments.\(profile.id.uuidString.lowercased())"
                            )

                        Text("Parallax uses a compatibility grammar, not a shell: whitespace separates arguments, while single or double quotes and backslash escapes group literal text.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        parsingDiagnostics(argumentParseResult.diagnostics)
                    }

                    Section("Environment") {
                        TextEditor(text: $draft.environmentText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 86)
                            .scrollContentBackground(.hidden)
                            .accessibilityLabel(Text("Environment configuration"))
                            .accessibilityIdentifier(
                                "profile-editor.environment.\(profile.id.uuidString.lowercased())"
                            )

                        Text("Use KEY=value or unset KEY, one per line. Order is preserved, and the last repeated name takes effect. Whitespace after = is part of the value, including an empty value.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Label(
                            "Literal environment values are stored as plaintext in the library and its backups. Use Keychain references for secrets.",
                            systemImage: "exclamationmark.shield"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)

                        parsingDiagnostics(environmentParseResult.diagnostics)

                        if !environmentSensitivityOptions.isEmpty {
                            HStack(alignment: .firstTextBaseline) {
                                Menu {
                                    ForEach(
                                        environmentSensitivityOptions,
                                        id: \.key
                                    ) { option in
                                        if option.isKeychainReference {
                                            Toggle(
                                                String(
                                                    localized: "\(option.key) (Keychain reference)"
                                                ),
                                                isOn: .constant(true)
                                            )
                                            .disabled(true)
                                        } else if option.isAutomaticallySensitive {
                                            Toggle(
                                                String(
                                                    localized: "\(option.key) (Automatically detected)"
                                                ),
                                                isOn: .constant(true)
                                            )
                                            .disabled(true)
                                        } else {
                                            Toggle(
                                                option.key,
                                                isOn: sensitiveKeyBinding(
                                                    for: option.key
                                                )
                                            )
                                        }
                                    }
                                } label: {
                                    Label(
                                        "Sensitive Values",
                                        systemImage: "eye.slash"
                                    )
                                }
                                .menuStyle(.borderlessButton)
                                .help("Choose environment values to redact in previews and exports")

                                Text("Mark additional keys whose literal values should remain redacted.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Button {
                            keychainEnvironmentKey = ""
                            keychainSecretValue = ""
                            isAddingKeychainSecret = true
                        } label: {
                            Label(
                                "Add Keychain Secret",
                                systemImage: "key"
                            )
                        }

                        ForEach(
                            environmentSensitivityOptions.filter(
                                \.isKeychainReference
                            ),
                            id: \.key
                        ) { option in
                            Button(role: .destructive) {
                                guard
                                    let removal =
                                        store
                                            .profileDraftRemovingKeychainSecret(
                                        environmentKey: option.key,
                                        from: draft
                                    )
                                else { return }
                                draft = removal.profile
                                if stagedKeychainReferences.remove(
                                    removal.reference
                                ) != nil {
                                    discardKeychainReferences(
                                        [removal.reference]
                                    )
                                } else {
                                    pendingKeychainDeletionReferences.insert(
                                        removal.reference
                                    )
                                }
                            } label: {
                                Label(
                                    "Remove \(option.key) Keychain Secret",
                                    systemImage: "key.slash"
                                )
                            }
                        }
                    }

                    Section("Environment Inheritance") {
                        Toggle(
                            "Inherit additional Parallax process variables (Advanced)",
                            isOn: inheritsProcessEnvironment
                        )

                        if draft.childEnvironmentPolicy == .inheritProcessEnvironment {
                            Label(
                                "This can forward API keys, tokens, SSH agent sockets, and other unrelated values from Parallax. Profile assignments and unset operations still apply afterward.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        } else {
                            Text("The safe default passes only trusted identity, temporary-directory, path, and locale values before applying this profile.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if draft.launchConfigurationTrust == .importedPendingReview {
                        Section("Imported Configuration") {
                            Label(
                                "Review every argument and environment operation before launching this imported profile.",
                                systemImage: "shield.lefthalf.filled.badge.checkmark"
                            )
                            .font(.caption)
                            .foregroundStyle(.orange)
                        }
                    }

                    Section("Profile Data") {
                        profileDataSummary
                    }

                    Section("Launch Preview") {
                        launchPreview
                    }

                    Section("Notes") {
                        TextEditor(text: $draft.notes)
                            .frame(minHeight: 74)
                            .scrollContentBackground(.hidden)
                            .accessibilityLabel(Text("Profile notes"))
                            .accessibilityIdentifier(
                                "profile-editor.notes.\(profile.id.uuidString.lowercased())"
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
        .confirmationDialog(
            "Remove \(profile.name)?",
            isPresented: $isConfirmingRemoveProfile,
            titleVisibility: .visible
        ) {
            Button("Remove Profile Only") {
                store.requestProfileRemoval(
                    for: application,
                    profile: profile,
                    dataRemoval: .keep
                )
            }
            Button("Remove and Archive Data") {
                store.requestProfileRemoval(
                    for: application,
                    profile: profile,
                    dataRemoval: .archive
                )
            }
            Button("Remove and Delete Data", role: .destructive) {
                store.requestProfileRemoval(
                    for: application,
                    profile: profile,
                    dataRemoval: .delete
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The profile entry will be removed from Parallax. Choose what to do with its stored data folder.")
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
            discardKeychainReferences(stagedKeychainReferences)
        }
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
                Label("Reveal Profile Folder", systemImage: "folder")
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
            Label("Profile Data", systemImage: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .help("Profile Data Actions")
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
            Button("Apply") {
                applyDraft()
            }
            .buttonStyle(.borderedProminent)
            .disabled(draft == baseline || isSavingKeychainSecret)

            Button("Revert") {
                revertDraft()
            }
            .disabled(draft == baseline || isSavingKeychainSecret)

            Button {
                store.launch(draft)
            } label: {
                Label("Launch Profile", systemImage: "play.fill")
            }
            .disabled(draft != baseline)
            .help(
                draft == baseline
                    ? String(localized: "Launch Profile")
                    : String(
                        localized:
                            "Apply or revert changes before launching"
                    )
            )

            Button(role: .destructive) {
                isConfirmingRemoveProfile = true
            } label: {
                Label("Remove Profile", systemImage: "trash")
            }

            Button {
                store.revealProfileFolder(for: application, profile: draft)
            } label: {
                Label("Reveal Folder", systemImage: "folder")
            }

            if axis == .horizontal {
                Spacer()
            }

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

    private func applyDraft() {
        guard store.applyProfileEdit(
            draft: draft,
            baseline: baseline,
            applicationID: application.id,
            baselineVersion: baselineVersion
        ) else {
            return
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
            return
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
        discardKeychainReferences(referencesToDelete)
    }

    private func revertDraft() {
        let staged = stagedKeychainReferences
        stagedKeychainReferences = []
        pendingKeychainDeletionReferences = []
        draft = baseline
        discardKeychainReferences(staged)
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
        LaunchArgumentParser.parse(text).tokens.map { token in
            if EnvironmentSecretReference(token: token.value) != nil {
                return String(
                    localized: "<redacted Keychain reference>"
                )
            }
            return token.value
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
