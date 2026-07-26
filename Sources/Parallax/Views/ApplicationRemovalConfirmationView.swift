import SwiftUI

struct ApplicationRemovalConfirmationView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        if let presentation =
            store.pendingApplicationRemovalPresentation
        {
            VStack(alignment: .leading, spacing: 16) {
                Label(
                    presentation.title,
                    systemImage: "trash"
                )
                .font(.title2.bold())

                Text(presentation.message)

                Picker(
                    "Managed profile data",
                    selection: Binding(
                        get: { presentation.dataChoice },
                        set: {
                            store
                                .updatePendingApplicationRemovalChoice(
                                    $0
                                )
                        }
                    )
                ) {
                    Text("Keep in Place")
                        .tag(ApplicationRemovalDataChoice.keep)
                    Text("Archive")
                        .tag(ApplicationRemovalDataChoice.archive)
                    Text("Delete Permanently")
                        .tag(ApplicationRemovalDataChoice.delete)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(
                    "application-removal.data-choice"
                )

                GroupBox("Exact managed paths") {
                    pathList(presentation.managedDataPaths)
                }

                if !presentation.externalDataPaths.isEmpty {
                    GroupBox("External paths (kept in place)") {
                        pathList(
                            presentation.externalDataPaths
                        )
                    }
                }

                Text(presentation.externalDataCaveat)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(
                    "A verified backup of this exact library version is created before removal."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                HStack {
                    Button("Cancel", role: .cancel) {
                        store.cancelApplicationRemoval()
                    }
                    Spacer()
                    Button("Remove Application", role: .destructive) {
                        store.confirmApplicationRemoval()
                    }
                    .accessibilityIdentifier(
                        "application-removal.confirm"
                    )
                }
            }
            .padding(24)
            .frame(minWidth: 660, minHeight: 520)
        } else {
            ProgressView()
                .padding(40)
        }
    }

    private func pathList(_ paths: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(
                    Array(paths.enumerated()),
                    id: \.offset
                ) { _, path in
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                }
            }
        }
        .frame(maxHeight: 110)
    }
}
