import SwiftUI

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

struct EmptyProfileView: View {
    @Bindable var store: LibraryStore

    var body: some View {
        ContentUnavailableView {
            Label("No Profile Selected", systemImage: "person.crop.circle.badge.plus")
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
