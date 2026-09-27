import SwiftUI

struct ContentView: View {
    @Bindable var store: LibraryStore
    @Bindable var corporateStore: CorporateUsageStore
    @Bindable var corporateAccountOperationCoordinator:
        CorporateAccountOperationCoordinator

    var body: some View {
        ParallaxWorkspaceView(
            store: store,
            corporateStore: corporateStore,
            corporateAccountOperationCoordinator:
                corporateAccountOperationCoordinator
        )
            .fileImporter(
                isPresented: appImporterPresentation,
                allowedContentTypes: [.applicationBundle],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        store.errorMessage = String(
                            localized:
                                "The file provider returned no application."
                        )
                        return
                    }
                    store.addApplication(at: url)
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
            .storeErrorPresentation(
                store: store,
                isEnabled: store.sceneCoordinator.presentsWorkspaceErrors
            )
            .workspaceSidebarToggle()
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
}

struct LocalSpacesView: View {
    @Bindable var store: LibraryStore
    @State private var pendingStartOverAuthorization: LibraryStore.StartOverAuthorization?

    var body: some View {
        libraryContent
            .safeAreaInset(edge: .bottom) {
                if let message =
                    store.libraryOperationStatusMessage
                {
                    HStack(spacing: 12) {
                        if store.isLibraryOperationInProgress {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "checkmark.circle")
                                .foregroundStyle(.secondary)
                        }
                        Text(message)
                            .lineLimit(2)
                        Spacer()
                        Button("Dismiss") {
                            store.dismissLibraryOperationStatus()
                        }
                        .accessibilityIdentifier(
                            "library.operation-status.dismiss"
                        )
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.bar)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier(
                        "library.operation-status"
                    )
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
                Text("Parallax will quarantine the current library before creating an empty one. Existing managed space folders will not be deleted.")
            }
    }

    @ViewBuilder
    private var libraryContent: some View {
        switch presentationState {
        case .loading:
            LibraryLoadingView()

        case let .recoveryRequired(message, canAttemptRecovery):
            // An infrastructure failure leaves the library itself intact, so it
            // must not be presented as library damage or offered library repairs.
            LibraryUnavailableView(
                store: store,
                title: store.infrastructureFailureMessage == nil
                    ? "Library Recovery Required"
                    : "Parallax Could Not Start Cleanly",
                systemImage: "exclamationmark.triangle",
                message: message,
                recoveryDetail: store.libraryRecoveryDetail,
                canAttemptRecovery: canAttemptRecovery,
                requestStartOver: requestStartOver
            )

        case let .readOnlyNewerVersion(message, canAttemptRecovery):
            LibraryUnavailableView(
                store: store,
                title: "Library Requires a Newer Parallax",
                systemImage: "lock.shield",
                message: message,
                recoveryDetail: String(localized: "This library is read-only. You can restore a compatible verified backup or preserve it in quarantine before starting over."),
                canAttemptRecovery: canAttemptRecovery,
                requestStartOver: requestStartOver
            )

        case let .unrecoverable(message, canAttemptRecovery):
            LibraryUnavailableView(
                store: store,
                title: "Library Could Not Be Loaded",
                systemImage: "xmark.octagon",
                message: message,
                recoveryDetail: String(localized: "Parallax has disabled library changes to protect the original data."),
                canAttemptRecovery: canAttemptRecovery,
                requestStartOver: requestStartOver
            )

        case .emptyLibrary,
             .noApplicationSelected,
             .selectedApplicationHasNoProfiles,
             .noProfileSelected,
             .profileSelected:
            loadedLibraryContent(for: presentationState)
        }
    }

    private func loadedLibraryContent(
        for presentationState: LibraryPresentationState
    ) -> some View {
        GeometryReader { windowProxy in
            Group {
                switch presentationState {
                case .emptyLibrary:
                    EmptyLibraryView(store: store)

                case .noApplicationSelected:
                    NoApplicationSelectedView()

                case let .selectedApplicationHasNoProfiles(applicationID),
                     let .noProfileSelected(applicationID),
                     let .profileSelected(applicationID, _):
                    if let application = store.applications.first(where: {
                        $0.id == applicationID
                    }) {
                        DetailView(
                            store: store,
                            application: application,
                            presentationState: presentationState,
                            windowWidth: windowProxy.size.width
                        )
                    } else {
                        NoApplicationSelectedView()
                    }

                case .loading,
                     .recoveryRequired,
                     .readOnlyNewerVersion,
                     .unrecoverable:
                    NoApplicationSelectedView()
                }
            }
            .frame(
                width: windowProxy.size.width,
                height: windowProxy.size.height,
                alignment: .center
            )
        }
    }

    private var presentationState: LibraryPresentationState {
        LibraryPresentationClassifier.classify(
            loadState: presentationLoadState,
            applications: store.applications,
            selectedApplicationID: store.selectedApplicationID,
            selectedProfileID: store.selectedProfileID
        )
    }

    private var presentationLoadState: LibraryPresentationLoadState {
        switch store.loadState {
        case .loading:
            return .loading
        case .loaded:
            return .loaded
        case let .recoveryRequired(originalBytes, message):
            return .recoveryRequired(
                message: message,
                canAttemptRecovery: originalBytes != nil
                    && store.infrastructureFailureMessage == nil
            )
        case let .unsupportedNewerVersion(originalBytes, message):
            return .readOnlyNewerVersion(
                message: message,
                canAttemptRecovery: originalBytes != nil
            )
        case let .unrecoverable(originalBytes, message):
            return .unrecoverable(
                message: message,
                canAttemptRecovery: originalBytes != nil
            )
        }
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

private struct StoreErrorPresentation: ViewModifier {
    @Bindable var store: LibraryStore
    let isEnabled: Bool
    @State private var pendingProfileRemovalConfirmation:
        LibraryStore.ProfileRemovalRecovery?

    func body(content: Content) -> some View {
        content
            .alert(
                "Parallax could not complete the action",
                isPresented: Binding(
                    get: { isEnabled && store.errorMessage != nil },
                    set: {
                        if isEnabled && !$0 { store.errorMessage = nil }
                    }
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
                "Remove Space Anyway?",
                isPresented: Binding(
                    get: {
                        isEnabled && pendingProfileRemovalConfirmation != nil
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
}

extension View {
    func storeErrorPresentation(
        store: LibraryStore,
        isEnabled: Bool = true
    ) -> some View {
        modifier(StoreErrorPresentation(store: store, isEnabled: isEnabled))
    }

    func applicationRelinkPresentation(
        store: LibraryStore,
        isEnabled: Bool = true
    ) -> some View {
        alert(
            "Update Application Location?",
            isPresented: Binding(
                get: { isEnabled && store.isShowingApplicationRelinkConfirmation },
                set: {
                    if isEnabled { store.isShowingApplicationRelinkConfirmation = $0 }
                }
            )
        ) {
            Button("Update Location") { store.confirmApplicationRelink() }
            Button("Cancel", role: .cancel) { store.cancelApplicationRelink() }
        } message: {
            Text(
                store.pendingApplicationRelinkMessage
                    ?? String(localized: "Review the verified application location before updating the library.")
            )
        }
    }
}
