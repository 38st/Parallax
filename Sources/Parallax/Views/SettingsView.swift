import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var settings: AppSettings

    @State private var newTemplateName = ""
    @State private var isConfirmingTemplateReset = false
    @State private var templatePendingDeletion: ProfileTemplate?

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            profilesTab
                .tabItem { Label("Spaces", systemImage: "rectangle.stack") }
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 560, height: 460)
        .alert(
            "Settings Recovery Available",
            isPresented: persistenceIssuePresentation,
            presenting: settings.persistenceIssues.first
        ) { issue in
            if settings.quarantinedSettingsData(for: issue) != nil {
                Button("Export Preserved Copy…") {
                    exportPreservedSettings(for: issue)
                }
                switch issue {
                case .corruptProfileTemplates:
                    Button("Use Defaults", role: .destructive) {
                        settings.profileTemplates =
                            ProfileTemplate.defaults
                        settings.dismissPersistenceIssue(
                            id: issue.id
                        )
                    }
                case .corruptProfileVisualIdentities:
                    Button(
                        "Use Automatic Pictures",
                        role: .destructive
                    ) {
                        settings.resetAllProfileVisualIdentities()
                        settings.dismissPersistenceIssue(
                            id: issue.id
                        )
                    }
                default:
                    EmptyView()
                }
            }
            Button("Dismiss", role: .cancel) {
                settings.dismissPersistenceIssue(id: issue.id)
            }
        } message: { issue in
            Text(issue.localizedDescription)
        }
        .confirmationDialog(
            "Reset Space Templates?",
            isPresented: $isConfirmingTemplateReset,
            titleVisibility: .visible
        ) {
            Button("Reset to Defaults", role: .destructive) {
                settings.resetProfileTemplatesToDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This replaces every space template with the defaults. You can undo the reset until you edit the templates again."
            )
        }
        .confirmationDialog(
            "Delete Space Template?",
            isPresented: Binding(
                get: { templatePendingDeletion != nil },
                set: { isPresented in
                    if !isPresented {
                        templatePendingDeletion = nil
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: templatePendingDeletion
        ) { template in
            Button("Delete \(template.name)", role: .destructive) {
                settings.removeProfileTemplate(id: template.id)
                templatePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                templatePendingDeletion = nil
            }
        } message: { template in
            Text(
                "This removes \(template.name) from new-space choices. Existing spaces are not changed."
            )
        }
    }

    private var generalTab: some View {
        Form {
            Section("Storage") {
                TextField("Default base storage path", text: $settings.defaultBaseStoragePath)
                    .textFieldStyle(.roundedBorder)
                Text("Applied to newly added apps. Leave empty to use the default location in Application Support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Opening") {
                Toggle("Confirm before opening a space", isOn: $settings.confirmBeforeLaunch)
                Toggle(
                    "Automatically reopen after a confirmed crash",
                    isOn:
                        $settings.automaticallyRecoverCrashedApps
                )
                Text(
                    "Parallax retries only when a matching macOS crash report confirms the app crashed. Recovery is rate-limited and stops after repeated failures."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .disabled(!settings.canModifySettings)
    }

    private var profilesTab: some View {
        Form {
            Section("Space Templates") {
                Text("Templates appear when creating a space. Each template can define default advanced settings and notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if settings.profileTemplates.isEmpty {
                    ContentUnavailableView(
                        "No Space Templates",
                        systemImage: "person.crop.circle.badge.minus",
                        description: Text(
                            "Spaces can still be created without a template."
                        )
                    )
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(settings.profileTemplates) { template in
                        HStack(alignment: .top, spacing: 8) {
                            DisclosureGroup(template.name) {
                                ProfileTemplateEditor(
                                    template: binding(
                                        for: template.id,
                                        fallback: template
                                    )
                                )
                            }

                            Button(role: .destructive) {
                                templatePendingDeletion = template
                            } label: {
                                Label(
                                    "Delete",
                                    systemImage: "trash"
                                )
                            }
                            .controlSize(.small)
                            .help("Delete space template")
                            .accessibilityLabel(
                                Text("Delete \(template.name) template")
                            )
                            .accessibilityHint(
                                Text(
                                    "Removes this template without affecting existing spaces."
                                )
                            )
                            .accessibilityIdentifier(
                                "delete-profile-template-\(template.id.uuidString)"
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        TextField(
                            "New template name",
                            text: $newTemplateName
                        )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTemplate() }

                        Button {
                            addTemplate()
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                        .disabled(
                            DisplayNameValidator.normalized(
                                newTemplateName
                            ) == nil
                        )
                        .help("Add template")
                        .accessibilityLabel(Text("Add template"))
                    }
                    if !newTemplateName.isEmpty,
                       let message = DisplayNameValidator.validate(
                        newTemplateName
                       ).issue?.message(for: .template)
                    {
                        Label(
                            message,
                            systemImage: "xmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier(
                            "settings.template.new.validation-error"
                        )
                    }
                }
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    isConfirmingTemplateReset = true
                }
                .disabled(
                    settings.profileTemplates == ProfileTemplate.defaults
                )

                if settings.canUndoProfileTemplateReset {
                    Button("Undo Reset") {
                        settings.undoProfileTemplateReset()
                    }
                    .keyboardShortcut("z", modifiers: .command)
                    .help("Restore the templates from before the reset")
                    .accessibilityHint(
                        Text(
                            "Restores the exact templates that existed before the reset."
                        )
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .disabled(!settings.canModifySettings)
    }

    private var appearanceTab: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .padding()
        .disabled(!settings.canModifySettings)
    }

    private func addTemplate() {
        guard settings.addProfileTemplate(
            named: newTemplateName
        ) != nil else { return }
        newTemplateName = ""
    }

    private func binding(
        for id: ProfileTemplate.ID,
        fallback: ProfileTemplate
    ) -> Binding<ProfileTemplate> {
        Binding(
            get: {
                settings.profileTemplate(id: id) ?? fallback
            },
            set: { updated in
                guard updated.id == id else { return }
                settings.replaceProfileTemplate(updated)
            }
        )
    }

    private var persistenceIssuePresentation: Binding<Bool> {
        Binding(
            get: { !settings.persistenceIssues.isEmpty },
            set: { isPresented in
                guard
                    !isPresented,
                    let issue = settings.persistenceIssues.first
                else { return }
                settings.dismissPersistenceIssue(id: issue.id)
            }
        )
    }

    private func exportPreservedSettings(
        for issue: AppSettingsPersistenceIssue
    ) {
        guard
            let data = settings.quarantinedSettingsData(
                for: issue
            )
        else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = preservedSettingsFilename(
            for: issue
        )
        panel.allowedContentTypes = [.json, .data]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        do {
            try data.write(
                to: url,
                options: [.atomic, .withoutOverwriting]
            )
            settings.dismissPersistenceIssue(id: issue.id)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    private func preservedSettingsFilename(
        for issue: AppSettingsPersistenceIssue
    ) -> String {
        switch issue {
        case .corruptProfileVisualIdentities:
            String(
                localized:
                    "Parallax Profile Pictures (Preserved).json"
            )
        default:
            String(
                localized:
                    "Parallax Profile Templates (Preserved).json"
            )
        }
    }
}

private struct ProfileTemplateEditor: View {
    @Binding var template: ProfileTemplate
    @State private var nameDraft: String

    init(template: Binding<ProfileTemplate>) {
        _template = template
        _nameDraft = State(
            initialValue: template.wrappedValue.name
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Template name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: nameDraft) { _, newValue in
                        guard let normalized =
                            DisplayNameValidator.normalized(newValue)
                        else { return }
                        var updated = template
                        updated.name = normalized
                        template = updated
                    }
                    .onChange(of: template.name) { _, newValue in
                        guard
                            DisplayNameValidator.normalized(
                                nameDraft
                            ) != newValue
                        else { return }
                        nameDraft = newValue
                    }
                if let message = DisplayNameValidator.validate(
                    nameDraft
                ).issue?.message(for: .template) {
                    Label(
                        message,
                        systemImage: "xmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(
                        "settings.template.name.validation-error"
                    )
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Default Arguments")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $template.argumentsText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(Text("Default Arguments"))
                    .accessibilityIdentifier(
                        "settings.template.arguments.\(template.id.uuidString.lowercased())"
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Default Environment")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $template.environmentText)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(Text("Default Environment"))
                    .accessibilityIdentifier(
                        "settings.template.environment.\(template.id.uuidString.lowercased())"
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Default Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $template.notes)
                    .frame(minHeight: 50)
                    .scrollContentBackground(.hidden)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(Text("Default Notes"))
                    .accessibilityIdentifier(
                        "settings.template.notes.\(template.id.uuidString.lowercased())"
                    )
            }
        }
        .padding(.vertical, 4)
    }
}
