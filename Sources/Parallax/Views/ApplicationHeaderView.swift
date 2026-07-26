import SwiftUI
import UniformTypeIdentifiers

struct ApplicationHeaderView: View {
    @Bindable var store: LibraryStore
    var application: ManagedApplication

    @State private var draft: ManagedApplication
    @State private var baseline: ManagedApplication
    @State private var baselineVersion: LibraryVersionToken
    @State private var isChoosingStorageLocation = false
    @State private var isLocatingApplication = false
    @State private var pendingPresetPreview:
        PresetChangePreview?

    init(store: LibraryStore, application: ManagedApplication) {
        self.store = store
        self.application = application
        _draft = State(initialValue: application)
        _baseline = State(initialValue: application)
        _baselineVersion = State(
            initialValue: store.currentLibraryVersion ?? .missing
        )
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
                    HStack {
                        appPathText
                        if store.applicationNeedsRelink(application) {
                            Button("Locate Application…") {
                                isLocatingApplication = true
                            }
                            .accessibilityIdentifier(
                                "application.relink.\(application.id.uuidString)"
                            )
                        }
                    }
                }

                headerRow("Preset") {
                    presetControls
                }

                headerRow("Storage") {
                    HStack(spacing: 8) {
                        Text(store.storagePath(for: application))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .frame(
                                minWidth: 0,
                                maxWidth: .infinity,
                                alignment: .leading
                            )

                        Button("Change…") {
                            isChoosingStorageLocation = true
                        }
                        .accessibilityLabel(Text("Change storage location"))
                    }
                }

                HStack {
                    Spacer()
                    Button("Revert") {
                        draft = baseline
                    }
                    .disabled(draft == baseline)

                    Button("Apply") {
                        applyDraft()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft == baseline)
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
        .onChange(of: application) { _, newValue in
            if newValue.id != baseline.id
                || newValue.storageID != baseline.storageID
                || draft == baseline
            {
                draft = newValue
                baseline = newValue
                baselineVersion =
                    store.currentLibraryVersion ?? baselineVersion
            }
        }
        .fileImporter(
            isPresented: $isChoosingStorageLocation,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let destination = urls.first else {
                    store.errorMessage = String(
                        localized:
                            "The file provider returned no folder."
                    )
                    return
                }
                store.prepareStorageRelocation(
                    for: application,
                    to: destination
                )
            case let .failure(error):
                if let message =
                    FileImporterFailure.userFacingMessage(
                        for: error
                    )
                {
                    store.errorMessage = message
                }
            }
        }
        .fileImporter(
            isPresented: $isLocatingApplication,
            allowedContentTypes: [.applicationBundle],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let candidate = urls.first else {
                    store.errorMessage = String(
                        localized:
                            "The file provider returned no application."
                    )
                    return
                }
                store.assessApplicationRelink(
                    application,
                    candidateURL: candidate
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
        .sheet(
            isPresented: Binding(
                get: { store.storageRelocationPreview != nil },
                set: { isPresented in
                    guard
                        !isPresented,
                        let preview = store.storageRelocationPreview
                    else { return }
                    store.cancelStorageRelocation(preview)
                }
            )
        ) {
            if let preview = store.storageRelocationPreview {
                StorageRelocationPreviewView(
                    store: store,
                    preview: preview
                )
            }
        }
        .sheet(
            isPresented: Binding(
                get: { pendingPresetPreview != nil },
                set: { isPresented in
                    if !isPresented {
                        pendingPresetPreview = nil
                    }
                }
            )
        ) {
            if let preview = pendingPresetPreview {
                PresetChangePreviewView(
                    preview: preview,
                    applyMetadataOnly: {
                        applyPresetPreview(
                            preview,
                            refreshGeneratedValues: false
                        )
                    },
                    applyAndRefresh: {
                        applyPresetPreview(
                            preview,
                            refreshGeneratedValues: true
                        )
                    },
                    cancel: {
                        pendingPresetPreview = nil
                    }
                )
            }
        }
    }

    private func applyDraft() {
        if draft.preset != baseline.preset {
            pendingPresetPreview = store.presetChangePreview(
                for: baseline,
                targetPreset: draft.preset
            )
            return
        }
        guard store.applyApplicationEdit(
            draft: draft,
            baseline: baseline,
            baselineVersion: baselineVersion
        ) else {
            return
        }
        guard
            let persisted = store.applications.first(where: {
                $0.id == application.id
            })
        else { return }
        draft = persisted
        baseline = persisted
        baselineVersion =
            store.currentLibraryVersion ?? baselineVersion
    }

    private func applyPresetPreview(
        _ preview: PresetChangePreview,
        refreshGeneratedValues: Bool
    ) {
        guard store.applyApplicationPresetEdit(
            draft: draft,
            baseline: baseline,
            baselineVersion: baselineVersion,
            preview: preview,
            refreshGeneratedValues: refreshGeneratedValues
        ) else {
            return
        }
        pendingPresetPreview = nil
        guard
            let persisted = store.applications.first(where: {
                $0.id == application.id
            })
        else { return }
        draft = persisted
        baseline = persisted
        baselineVersion =
            store.currentLibraryVersion ?? baselineVersion
    }

    private func headerRow<Content: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
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
        Text(
            draft.bundleIdentifier
                ?? String(localized: "Unavailable")
        )
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

            Button("Preview Recommended Settings…") {
                pendingPresetPreview = store.presetChangePreview(
                    for: baseline,
                    targetPreset: draft.preset
                )
            }
            .buttonStyle(.link)
            .accessibilityIdentifier(
                "application.preset.preview.\(application.id.uuidString)"
            )
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
    }
}
