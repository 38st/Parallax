import AppKit
import SwiftUI

struct ApplicationRemovalConfirmationView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        if store.pendingApplicationRemovalPresentation == nil {
            ApplicationRemovalRecoveryView(store: store)
        } else if let presentation =
            store.pendingApplicationRemovalPresentation
        {
            VStack(alignment: .leading, spacing: 16) {
                Label(
                    presentation.title,
                    systemImage: "trash"
                )
                .font(.title2.bold())

                Text(presentation.message)

                ApplicationRemovalPreservedFilesView(
                    records: store.preservedApplicationRemovalFiles.filter {
                        $0.applicationStorageID == store.pendingApplicationRemoval?.applicationStorageID
                    }
                )
                if let error = store.applicationRemovalRecoveryListingError {
                    Text(error).foregroundStyle(.secondary)
                }

                Picker(
                    "Managed space data",
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
                    .disabled(store.isProfileDataOperationRunning)
                    Spacer()
                    Button("Remove Application", role: .destructive) {
                        Task {
                            await store.confirmApplicationRemovalAsync()
                        }
                    }
                    .accessibilityIdentifier(
                        UIAutomationContract
                            .applicationRemovalConfirm
                    )
                    .disabled(store.isProfileDataOperationRunning)
                }
            }
            .padding(24)
            .frame(minWidth: 660, minHeight: 520)
            .task { await store.refreshApplicationRemovalRecoveryReviews() }
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

struct ApplicationRemovalRecoveryView: View {
    @Bindable var store: LibraryStore
    @State private var reviewToConfirm: ApplicationRemovalRecoveryReview?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Application Removal Recovery")
                .font(.title2.bold())
            if let message = store.errorMessage {
                Text(message)
            }
            if let message = store.applicationRemovalRecoveryListingError {
                Text(message)
            }
            if store.isRefreshingApplicationRemovalRecovery {
                ProgressView()
            } else if store.applicationRemovalRecoveryJournals.isEmpty {
                Text("No pending application removal records were found. Close this window, or retry to reload the library.")
            }
            Text("Files may remain at these locations. Reconnect unavailable storage before using Show in Finder.")
                .foregroundStyle(.secondary)
            ScrollView {
                if let completion = store.libraryOperationStatusMessage {
                    Text(completion)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(store.applicationRemovalRecoveryJournals) { journal in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(journal.id.uuidString)
                                .font(.caption.monospaced())
                            Text(journal.status.message)
                            if let review = journal.review {
                                ApplicationRemovalLocationsView(locations: review.locations)
                                Button("Keep Files and Continue…") {
                                    reviewToConfirm = review
                                }
                                .disabled(store.infrastructureFailureMessage != nil)
                            }
                        }
                    }
                }
                ApplicationRemovalPreservedFilesView(records: store.preservedApplicationRemovalFiles)
            }
            HStack {
                Button("Close", role: .cancel) {
                    store.isShowingApplicationRemovalConfirmation = false
                }
                Spacer()
                Button("Refresh Locations") {
                    Task { await store.refreshApplicationRemovalRecoveryReviews() }
                }
                Button("Retry Recovery") {
                    store.retryApplicationRemovalRecovery()
                }
                .disabled(store.infrastructureFailureMessage != nil)
            }
        }
        .padding(24)
        .frame(minWidth: 660, minHeight: 420)
        .task { await store.refreshApplicationRemovalRecoveryReviews() }
        .alert(
            "Keep Files and Continue?",
            isPresented: Binding(
                get: { reviewToConfirm != nil },
                set: { if !$0 { reviewToConfirm = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { reviewToConfirm = nil }
            Button("Keep Files and Continue") {
                if let review = reviewToConfirm {
                    store.keepApplicationRemovalFilesAndContinue(review)
                }
                reviewToConfirm = nil
            }
        } message: {
            Text("Parallax will stop recovery for this removal and leave every file where it is. Staged or archived data will not be restored automatically. The current application list will be kept. Review the displayed locations before continuing.")
        }
    }
}

struct ApplicationRemovalPreservedFilesView: View {
    let records: [ApplicationRemovalPreservedFiles]

    var body: some View {
        if !records.isEmpty {
            GroupBox("Preserved Files") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("These locations were preserved by Keep Files and Continue. Staged or archived files were not restored. Opening a listed space may create an empty data folder. Archive and Delete do not remove these preserved copies.")
                    ScrollView {
                        ForEach(records) { record in
                            ApplicationRemovalLocationsView(locations: record.locations)
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
        }
    }
}

private struct ApplicationRemovalLocationsView: View {
    let locations: [URL]

    var body: some View {
        ForEach(locations, id: \.self) { location in
            HStack {
                Text(location.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([location])
                }
            }
        }
    }
}

struct ApplicationRemovalRecoveryButton: View {
    @Bindable var store: LibraryStore

    var body: some View {
        Group {
            if store.infrastructureFailureMessage == nil,
               store.isPendingApplicationRemovalRecovery
                || !store.applicationRemovalRecoveryJournals.isEmpty
                || !store.preservedApplicationRemovalFiles.isEmpty {
                Button("Review Application Removal…") {
                    store.isShowingApplicationRemovalConfirmation = true
                }
            }
        }
        .task { await store.refreshApplicationRemovalRecoveryReviews() }
    }
}
