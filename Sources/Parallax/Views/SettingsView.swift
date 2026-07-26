import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Bindable var settings: AppSettings

    @State private var newTemplateName = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            profilesTab
                .tabItem { Label("Profiles", systemImage: "person.2.badge.gearshape") }
            appearanceTab
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 560, height: 460)
        .alert(
            "Settings Recovery Available",
            isPresented: persistenceIssuePresentation,
            presenting: settings.persistenceIssues.first
        ) { issue in
            if settings.quarantinedProfileTemplateData(for: issue) != nil {
                Button("Export Preserved Copy…") {
                    exportPreservedSettings(for: issue)
                }
                Button("Use Defaults", role: .destructive) {
                    settings.profileTemplates = ProfileTemplate.defaults
                    settings.dismissPersistenceIssue(id: issue.id)
                }
            }
            Button("Dismiss", role: .cancel) {
                settings.dismissPersistenceIssue(id: issue.id)
            }
        } message: { issue in
            Text(issue.localizedDescription)
        }
    }

    private var generalTab: some View {
        Form {
            Section("Storage") {
                TextField("Default base storage path", text: $settings.defaultBaseStoragePath)
                    .textFieldStyle(.roundedBorder)
                Text("Applied to newly added applications. Leave empty to use the default location in Application Support.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Launching") {
                Toggle("Confirm before launching a profile", isOn: $settings.confirmBeforeLaunch)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var profilesTab: some View {
        Form {
            Section("Profile Templates") {
                Text("Templates appear in the “Templates” menu when adding profiles. Each template can define default arguments, environment, and notes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(settings.profileTemplates) { template in
                    DisclosureGroup(template.name) {
                        ProfileTemplateEditor(template: binding(for: template))
                    }
                }
                .onDelete { indices in
                    settings.profileTemplates.remove(atOffsets: indices)
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
                    settings.profileTemplates = ProfileTemplate.defaults
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
        settings.profileTemplates.append(ProfileTemplate(name: trimmed))
        newTemplateName = ""
    }

    private func binding(for template: ProfileTemplate) -> Binding<ProfileTemplate> {
        guard let index = settings.profileTemplates.firstIndex(where: { $0.id == template.id }) else {
            return .constant(template)
        }
        return $settings.profileTemplates[index]
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
            let data = settings.quarantinedProfileTemplateData(
                for: issue
            )
        else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue =
            "Parallax Profile Templates (Preserved).json"
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
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Default Notes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextEditor(text: $template.notes)
                    .frame(minHeight: 50)
                    .scrollContentBackground(.hidden)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 4)
    }
}
