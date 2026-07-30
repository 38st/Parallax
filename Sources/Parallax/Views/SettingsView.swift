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

                HStack {
                    TextField("New template name", text: $newTemplateName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addTemplate() }

                    Button {
                        addTemplate()
                    } label: {
                        Image(systemName: "plus.circle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(newTemplateName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Add template")
                    .accessibilityLabel(Text("Add template"))
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
    }

    private func addTemplate() {
        let trimmed = newTemplateName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        settings.addProfileTemplate(named: trimmed)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Template name", text: $template.name)
                .textFieldStyle(.roundedBorder)

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
