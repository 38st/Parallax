import SwiftUI

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
        .frame(width: 520, height: 420)
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
                Text("Templates appear in the “Templates” menu when adding profiles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(settings.profileTemplateNames.indices, id: \.self) { index in
                    HStack {
                        TextField("Template name", text: Binding(
                            get: { settings.profileTemplateNames[index] },
                            set: { settings.profileTemplateNames[index] = $0 }
                        ))
                        .textFieldStyle(.roundedBorder)

                        Button(role: .destructive) {
                            settings.profileTemplateNames.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove template")
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
                }
            }

            Section {
                Button("Reset to Defaults", role: .destructive) {
                    settings.profileTemplateNames = AppSettings.defaultProfileTemplateNames
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
        settings.profileTemplateNames.append(trimmed)
        newTemplateName = ""
    }
}
