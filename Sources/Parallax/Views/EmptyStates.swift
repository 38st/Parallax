import SwiftUI

enum LibraryPresentationLoadState: Equatable, Sendable {
    case loading
    case loaded
    case recoveryRequired(message: String, canAttemptRecovery: Bool)
    case readOnlyNewerVersion(message: String, canAttemptRecovery: Bool)
    case unrecoverable(message: String, canAttemptRecovery: Bool)
}

enum LibraryPresentationState: Equatable, Sendable {
    case loading
    case emptyLibrary
    case noApplicationSelected
    case selectedApplicationHasNoProfiles(applicationID: UUID)
    case noProfileSelected(applicationID: UUID)
    case profileSelected(applicationID: UUID, profileID: UUID)
    case recoveryRequired(message: String, canAttemptRecovery: Bool)
    case readOnlyNewerVersion(message: String, canAttemptRecovery: Bool)
    case unrecoverable(message: String, canAttemptRecovery: Bool)
}

enum LibraryPresentationClassifier {
    static func classify(
        loadState: LibraryPresentationLoadState,
        applications: [ManagedApplication],
        selectedApplicationID: ManagedApplication.ID?,
        selectedProfileID: LaunchProfile.ID?
    ) -> LibraryPresentationState {
        switch loadState {
        case .loading:
            return .loading

        case .loaded:
            guard !applications.isEmpty else {
                return .emptyLibrary
            }
            guard
                let selectedApplicationID,
                let application = applications.first(where: {
                    $0.id == selectedApplicationID
                })
            else {
                return .noApplicationSelected
            }
            guard !application.profiles.isEmpty else {
                return .selectedApplicationHasNoProfiles(
                    applicationID: application.id
                )
            }
            guard
                let selectedProfileID,
                application.profiles.contains(where: {
                    $0.id == selectedProfileID
                })
            else {
                return .noProfileSelected(applicationID: application.id)
            }
            return .profileSelected(
                applicationID: application.id,
                profileID: selectedProfileID
            )

        case let .recoveryRequired(message, canAttemptRecovery):
            return .recoveryRequired(
                message: message,
                canAttemptRecovery: canAttemptRecovery
            )

        case let .readOnlyNewerVersion(message, canAttemptRecovery):
            return .readOnlyNewerVersion(
                message: message,
                canAttemptRecovery: canAttemptRecovery
            )

        case let .unrecoverable(message, canAttemptRecovery):
            return .unrecoverable(
                message: message,
                canAttemptRecovery: canAttemptRecovery
            )
        }
    }
}

struct LibraryLoadingView: View {
    var body: some View {
        ContentUnavailableView {
            ProgressView()
                .controlSize(.large)
        } description: {
            Text("Loading the Parallax library…")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Loading the Parallax library"))
    }
}

struct EmptyLibraryView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        ContentUnavailableView {
            Label("No Applications", systemImage: "rectangle.stack.badge.plus")
        } description: {
            Text("Add an app to create isolated launch profiles.")
        } actions: {
            Button("Add Application") {
                store.beginAddingApplication()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct NoApplicationSelectedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Application Selected", systemImage: "sidebar.left")
        } description: {
            Text("Select an application in the sidebar to view its profiles.")
        }
    }
}

struct LibraryUnavailableView: View {
    @Bindable var store: LibraryStore

    let title: LocalizedStringKey
    let systemImage: String
    let message: String
    let recoveryDetail: LocalizedStringKey
    let canAttemptRecovery: Bool
    let requestStartOver: (LibraryStore.StartOverAuthorization) -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            VStack(spacing: 8) {
                Text(message)
                Text(recoveryDetail)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 560)
        } actions: {
            if canAttemptRecovery {
                Button("Restore Latest Verified Backup") {
                    store.isShowingAppImporter = false
                    store.restoreLatestVerifiedBackup()
                }

                Button("Export Recovery Copy…") {
                    store.exportRecoveryCopy()
                }

                Button("Show Recovery Files") {
                    store.revealRecoveryArtifacts()
                }

                if let authorization = store.startOverAuthorization() {
                    Button("Start Over…", role: .destructive) {
                        requestStartOver(authorization)
                    }
                }
            }
        }
    }
}

struct EmptyApplicationProfilesView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        ContentUnavailableView {
            Label("No Profiles", systemImage: "person.crop.circle.badge.plus")
        } description: {
            Text("Create a profile to launch this app with profile-specific arguments and environment.")
        } actions: {
            Button("Add Profile") {
                store.addProfile()
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

struct NoProfileSelectedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("No Profile Selected", systemImage: "person.crop.circle")
        } description: {
            Text("Select a profile in the list to view and edit its launch settings.")
        }
    }
}
