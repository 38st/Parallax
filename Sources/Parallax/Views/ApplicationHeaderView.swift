import SwiftUI

struct ApplicationHeaderView: View {
    @Bindable var store: LibraryStore
    var application: ManagedApplication

    @State private var draft: ManagedApplication

    init(store: LibraryStore, application: ManagedApplication) {
        self.store = store
        self.application = application
        _draft = State(initialValue: application)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                headerRow("Name") {
                    TextField("Application name", text: $draft.displayName)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 0, maxWidth: .infinity)
                }

                headerRow("Bundle ID") {
                    bundleIdentifierText
                }

                headerRow("Path") {
                    appPathText
                }

                headerRow("Preset") {
                    presetControls
                }

                headerRow("Storage") {
                    TextField("Default Parallax storage", text: Binding(
                        get: { draft.baseStoragePath ?? "" },
                        set: { draft.baseStoragePath = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 0, maxWidth: .infinity)
                }
            }
            .padding(14)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onChange(of: draft) { _, newValue in
            store.updateApplication(newValue)
        }
        .onChange(of: application) { _, newValue in
            if newValue != draft {
                draft = newValue
            }
        }
    }

    private func headerRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(title)
                    .foregroundStyle(.secondary)
                    .frame(width: 88, alignment: .leading)

                content()
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                content()
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .clipped()
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }

    private var bundleIdentifierText: some View {
        Text(draft.bundleIdentifier ?? "Unavailable")
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
    }

    private var appPathText: some View {
        Text(draft.appPath)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
    }

    private var presetControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Preset", selection: $draft.preset) {
                ForEach(AppPreset.allCases) { preset in
                    Text(preset.label).tag(preset)
                }
            }
            .labelsHidden()
            .frame(width: 180, alignment: .leading)

            Text(store.compatibilityDetail(for: draft))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}
