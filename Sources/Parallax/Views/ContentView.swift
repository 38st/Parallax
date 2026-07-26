import SwiftUI

struct ContentView: View {
    @Bindable var store: LibraryStore
    @State private var pendingStartOverAuthorization: LibraryStore.StartOverAuthorization?
    @State private var pendingProfileRemovalConfirmation:
        LibraryStore.ProfileRemovalRecovery?

    var body: some View {
        libraryContent
            .fileImporter(
                isPresented: appImporterPresentation,
                allowedContentTypes: [.applicationBundle],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    store.addApplication(at: url)
                }
            }
            .alert(
                "Start Over With an Empty Library?",
                isPresented: startOverConfirmationPresentation
            ) {
                Button("Start Over", role: .destructive) {
                    guard let authorization = pendingStartOverAuthorization else {
                        return
                    }
                    pendingStartOverAuthorization = nil
                    store.isShowingAppImporter = false
                    store.confirmStartOver(authorization)
                }
                Button("Cancel", role: .cancel) {
                    pendingStartOverAuthorization = nil
                }
            } message: {
                Text("Parallax will quarantine the current library before creating an empty one. Existing managed profile folders will not be deleted.")
            }
            .alert(
                "Parallax could not complete the action",
                isPresented: Binding(
                    get: { store.errorMessage != nil },
                    set: { if !$0 { store.errorMessage = nil } }
                )
            ) {
                if let recovery = store.pendingProfileRemovalRecovery {
                    Button("Remove Entry Anyway…", role: .destructive) {
                        store.errorMessage = nil
                        pendingProfileRemovalConfirmation = recovery
                    }
                }
                Button("OK") {
                    store.errorMessage = nil
                    store.dismissProfileRemovalRecovery()
                }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .alert(
                "Remove Profile Entry Anyway?",
                isPresented: Binding(
                    get: {
                        pendingProfileRemovalConfirmation != nil
                    },
                    set: { isPresented in
                        if !isPresented {
                            pendingProfileRemovalConfirmation = nil
                        }
                    }
                )
            ) {
                Button("Remove Entry Anyway", role: .destructive) {
                    guard
                        let recovery =
                            pendingProfileRemovalConfirmation
                    else { return }
                    pendingProfileRemovalConfirmation = nil
                    store.removeEntryAnyway(recovery)
                }
                Button("Cancel", role: .cancel) {
                    pendingProfileRemovalConfirmation = nil
                    store.dismissProfileRemovalRecovery()
                }
            } message: {
                if let recovery = pendingProfileRemovalConfirmation {
                    Text(
                        "Only \(recovery.profileName)'s library entry will be removed. Its remaining data will stay at:\n\(recovery.canonicalRemainingDataPath)"
                    )
                }
            }
    }

    @ViewBuilder
    private var libraryContent: some View {
        switch store.loadState {
        case .loading:
            LibraryLoadingView()

        case .loaded:
            loadedLibraryContent

        case let .recoveryRequired(originalBytes, message):
            LibraryUnavailableView(
                store: store,
                title: "Library Recovery Required",
                systemImage: "exclamationmark.triangle",
                message: message,
                recoveryDetail: "Restore a verified backup, or quarantine this library and start over.",
                canAttemptRecovery: originalBytes != nil,
                requestStartOver: requestStartOver
            )

        case let .unsupportedNewerVersion(originalBytes, message):
            LibraryUnavailableView(
                store: store,
                title: "Library Requires a Newer Parallax",
                systemImage: "lock.shield",
                message: message,
                recoveryDetail: "This library is read-only. You can restore a compatible verified backup or preserve it in quarantine before starting over.",
                canAttemptRecovery: originalBytes != nil,
                requestStartOver: requestStartOver
            )

        case let .unrecoverable(originalBytes, message):
            LibraryUnavailableView(
                store: store,
                title: "Library Could Not Be Loaded",
                systemImage: "xmark.octagon",
                message: message,
                recoveryDetail: "Parallax has disabled library changes to protect the original data.",
                canAttemptRecovery: originalBytes != nil,
                requestStartOver: requestStartOver
            )
        }
    }

    private var loadedLibraryContent: some View {
        NavigationSplitView {
            SidebarView(store: store)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let application = store.selectedApplication {
                DetailView(store: store, application: application)
            } else if store.applications.isEmpty {
                EmptyLibraryView(store: store)
            } else {
                NoApplicationSelectedView()
            }
        }
    }

    private var appImporterPresentation: Binding<Bool> {
        Binding(
            get: {
                guard case .loaded = store.loadState else { return false }
                return store.isShowingAppImporter
            },
            set: { isPresented in
                store.isShowingAppImporter = isPresented
            }
        )
    }

    private var startOverConfirmationPresentation: Binding<Bool> {
        Binding(
            get: { pendingStartOverAuthorization != nil },
            set: { isPresented in
                if !isPresented {
                    pendingStartOverAuthorization = nil
                }
            }
        )
    }

    private func requestStartOver(
        _ authorization: LibraryStore.StartOverAuthorization
    ) {
        pendingStartOverAuthorization = authorization
    }
}
