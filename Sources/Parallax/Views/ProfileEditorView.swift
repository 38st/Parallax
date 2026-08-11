import SwiftUI
import UniformTypeIdentifiers

struct ProfileEditorView: View {
    @Bindable var store: LibraryStore
    var application: ManagedApplication
    var profile: LaunchProfile

    @State var session: ProfileEditorSession

    var draft: LaunchProfile {
        get { session.draft }
        nonmutating set { session.draft = newValue }
    }

    var baseline: LaunchProfile {
        session.baseline
    }

    var isImportingCodexHome: Bool {
        get { session.isImportingCodexHome }
        nonmutating set { session.isImportingCodexHome = newValue }
    }

    var isRevealingSensitiveLiterals: Bool {
        get { session.isRevealingSensitiveLiterals }
        nonmutating set {
            session.isRevealingSensitiveLiterals = newValue
        }
    }

    var isSavingKeychainSecret: Bool {
        session.isSavingKeychainSecret
    }

    init(store: LibraryStore, application: ManagedApplication, profile: LaunchProfile) {
        self.store = store
        self.application = application
        self.profile = profile
        _session = State(
            initialValue: ProfileEditorSession(
                client: store,
                application: application,
                profile: profile
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Form {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(
                                "Space name",
                                text: $session.draft.name
                            )
                                .accessibilityHint(
                                    Text(
                                        actionPresentation
                                            .nameValidationMessage ?? ""
                                    )
                                )
                                .accessibilityIdentifier(
                                    "space-editor.name.\(profile.id.uuidString.lowercased())"
                                )
                            if let message = actionPresentation
                                .nameValidationMessage
                            {
                                Label(
                                    message,
                                    systemImage: "xmark.circle.fill"
                                )
                                .font(.caption)
                                .foregroundStyle(.red)
                                .accessibilityIdentifier(
                                    "space-editor.name.validation-error"
                                )
                            }
                        }

                        LabeledContent("Separation") {
                            Text(separationSummary.detail)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.trailing)
                        }

                        LabeledContent("Notes") {
                            TextEditor(text: $session.draft.notes)
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
                        isExpanded:
                            $session.isAdvancedSettingsExpanded
                    ) {
                        VStack(alignment: .leading, spacing: 12) {
                            advancedSettingsCard(
                                title: "Launch Arguments",
                                systemImage: "terminal",
                                description:
                                    "Pass options to the app when this space opens."
                            ) {
                                configurationEditor(
                                    text: $session.draft.argumentsText,
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
                                    text: $session.draft.environmentText,
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
            session.synchronize(
                application: application,
                profile: newValue
            )
        }
        .onChange(of: session.draft) { _, _ in
            session.draftDidChange()
        }
        .fileImporter(
            isPresented: $session.isImportingCodexHome,
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
        .sheet(isPresented: $session.isSecretSheetPresented) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Add Keychain Secret")
                    .font(.title2.bold())
                TextField(
                    "Environment variable name",
                    text: $session.keychainEnvironmentKey
                )
                SecureField(
                    "Secret value",
                    text: $session.keychainSecretValue
                )
                Text(
                    "The secret value is stored in the macOS Keychain. The Parallax library stores only an opaque reference."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) {
                        session.cancelAddingKeychainSecret()
                    }
                    Button("Save to Keychain") {
                        session.saveKeychainSecret()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        session.isSavingKeychainSecret
                            || session.keychainEnvironmentKey.isEmpty
                            || session.keychainSecretValue.isEmpty
                    )
                }
            }
            .padding(24)
            .frame(width: 440)
        }
        .onAppear {
            session.activate()
        }
        .onDisappear {
            session.deactivate()
        }
    }

}
