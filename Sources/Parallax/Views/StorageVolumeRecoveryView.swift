import AppKit
import SwiftUI

struct StorageVolumeRecoveryView: View {
    @Bindable var store: LibraryStore
    let application: ManagedApplication
    @State private var presentation = StorageVolumeRecoveryPresentation()
    @State private var volumeRevision: UInt = 0

    private struct RefreshKey: Hashable {
        let applicationID: UUID
        let storageID: UUID
        let storagePath: String?
        let errorMessage: String?
        let volumeRevision: UInt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let recovery = presentation.recovery {
                HStack(alignment: .top, spacing: 12) {
                    Label(
                        ManagedPathError(.baseRootUnavailable).localizedDescription,
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button(recovery.actionTitle) {
                        presentation.requestConfirmation()
                    }
                    .accessibilityIdentifier("application.storage.forget-drive")
                }
                .font(.callout)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
        }
        .task(id: RefreshKey(
            applicationID: application.id,
            storageID: application.storageID,
            storagePath: application.baseStoragePath,
            errorMessage: store.errorMessage,
            volumeRevision: volumeRevision
        )) {
            await presentation.refresh(store: store, applicationID: application.id)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in
            volumeRevision &+= 1
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in
            volumeRevision &+= 1
        }
        .alert(
            presentation.pendingConfirmation?.confirmationTitle ?? String(localized: "Forget This Drive?"),
            isPresented: Binding(
                get: { presentation.pendingConfirmation != nil },
                set: { if !$0 { presentation.cancelConfirmation() } }
            )
        ) {
            Button("Forget This Drive", role: .destructive) {
                presentation.confirm(store: store)
            }
            Button("Cancel", role: .cancel) {
                presentation.cancelConfirmation()
            }
        } message: {
            if let request = presentation.pendingConfirmation {
                Text(request.confirmationMessage)
            }
        }
    }
}
