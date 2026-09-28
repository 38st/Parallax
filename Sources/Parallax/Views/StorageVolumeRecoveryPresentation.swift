import Foundation
import Observation

@Observable
@MainActor
final class StorageVolumeRecoveryPresentation {
    private(set) var recovery: StorageVolumeForgetRequest?
    private(set) var pendingConfirmation: StorageVolumeForgetRequest?
    private var refreshRevision: UInt = 0

    func refresh(store: LibraryStore, applicationID: UUID) async {
        refreshRevision &+= 1
        let revision = refreshRevision
        recovery = nil
        if pendingConfirmation?.applicationID != applicationID {
            pendingConfirmation = nil
        }
        let current = await store.unavailableStorageRecovery(applicationID: applicationID)
        guard revision == refreshRevision, !Task.isCancelled else { return }
        recovery = current
        if pendingConfirmation != current {
            pendingConfirmation = nil
        }
    }

    func requestConfirmation() {
        pendingConfirmation = recovery
    }

    func cancelConfirmation() {
        pendingConfirmation = nil
    }

    @discardableResult
    func confirm(store: LibraryStore) -> Task<Bool, Never>? {
        guard let confirmed = pendingConfirmation else { return nil }
        pendingConfirmation = nil
        // Consume the confirmation synchronously, before SwiftUI dismisses the alert.
        return Task {
            // Reconnection or a changed enrollment invalidates the displayed choice.
            guard await store.unavailableStorageRecovery(applicationID: confirmed.applicationID) == confirmed else {
                if recovery == confirmed { recovery = nil }
                return false
            }
            let succeeded = await store.forgetStorageVolume(confirmed)
            if succeeded, recovery == confirmed { recovery = nil }
            return succeeded
        }
    }
}
