import SwiftUI
import UniformTypeIdentifiers

struct ProfileEditorView: View {
    @Bindable var store: LibraryStore
    var application: ManagedApplication
    var profile: LaunchProfile

    @State private var draft: LaunchProfile
    @State private var isConfirmingClearData = false
    @State private var isConfirmingRemoveProfile = false
    @State private var isImportingCodexHome = false

    init(store: LibraryStore, application: ManagedApplication, profile: LaunchProfile) {
        self.store = store
        self.application = application
        self.profile = profile
        _draft = State(initialValue: profile)
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
                                store.applyRecommendedSettings(to: draft)
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

                        Text("Parsed as \(draft.arguments.count) argument\(draft.arguments.count == 1 ? "" : "s"). Quote paths that contain spaces.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Environment") {
                        TextEditor(text: $draft.environmentText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 86)
                            .scrollContentBackground(.hidden)

                        Text("Use KEY=value, one per line. Values override the inherited environment.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        .onChange(of: draft) { _, newValue in
            store.updateProfile(newValue)
        }
        .onChange(of: profile) { _, newValue in
            if newValue != draft {
                draft = newValue
            }
        }
        .confirmationDialog(
            "Clear all data for \(draft.name)?",
            isPresented: $isConfirmingClearData,
            titleVisibility: .visible
        ) {
            Button("Clear Profile Data", role: .destructive) {
                store.clearProfileData(for: application, profile: draft)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the profile folder managed by Parallax. The profile settings stay in the library.")
            Text("Existing data is moved into an Archives folder instead of being deleted.")
        }
        .confirmationDialog(
            "Remove \(draft.name)?",
            isPresented: $isConfirmingRemoveProfile,
            titleVisibility: .visible
        ) {
            Button("Remove Profile Only") {
                store.remove(profile: draft, dataRemoval: .keep)
            }
            Button("Remove and Archive Data") {
                store.remove(profile: draft, dataRemoval: .archive)
            }
            Button("Remove and Delete Data", role: .destructive) {
                store.remove(profile: draft, dataRemoval: .delete)
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
            guard case .success(let urls) = result, let url = urls.first else { return }
            store.useCodexHome(url, for: draft)
        }
    }

    private var profileDataSummary: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.profileFolderPath(for: application, profile: draft))
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
                    .accessibilityLabel(Text("\(item.label): \(item.isHealthy ? "passing" : "not passing")"))
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

            if store.codexHomePath(for: application, profile: draft) != nil {
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

            if store.userDataPath(for: application, profile: draft) != nil {
                Button {
                    store.revealUserData(for: application, profile: draft)
                } label: {
                    Label("Reveal User Data", systemImage: "globe")
                }
            }

            Divider()

            Button(role: .destructive) {
                isConfirmingClearData = true
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

            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(store.resolvedArguments(for: draft), id: \.self) { argument in
                        Text(argument)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    ForEach(store.resolvedEnvironment(for: draft), id: \.key) { item in
                        Text("\(item.key)=\(item.value)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var healthSummary: String {
        let items = store.healthItems(for: application, profile: draft)
        let healthyCount = items.filter(\.isHealthy).count
        return "\(healthyCount) of \(items.count) checks passing"
    }

    private var argumentSummary: String {
        let count = store.resolvedArguments(for: draft).count
        return count == 0 ? "None" : "\(count) argument\(count == 1 ? "" : "s")"
    }

    private var environmentSummary: String {
        let count = store.resolvedEnvironment(for: draft).count
        return count == 0 ? "None" : "\(count) override\(count == 1 ? "" : "s")"
    }

    @ViewBuilder
    private func footerControls(axis: Axis) -> some View {
        let layout = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 8)) : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))

        layout {
            Button {
                store.launch(draft)
            } label: {
                Label("Launch Profile", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)

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

            if let launchStatusMessage = store.launchStatusMessage {
                Text(launchStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
