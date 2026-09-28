import Foundation

struct StorageVolumeForgetRequest: Equatable, Sendable {
    let applicationID: UUID
    let applicationStorageID: UUID
    let applicationName: String
    let record: StorageVolumeEnrollmentStore.Record

    var actionTitle: String { String(localized: "Forget This Drive") }
    var confirmationTitle: String { String(localized: "Forget This Drive?") }
    var confirmationMessage: String {
        let name = applicationName
        let path = record.baseRootPath
        return String(localized: "Parallax will forget the drive recorded for \(name). Future operations may recreate \(path) on the currently mounted disk. Forgetting the drive does not move or delete profile data.")
    }
}

extension LibraryStore {
    func unavailableStorageRecovery(applicationID: UUID) async -> StorageVolumeForgetRequest? {
        guard let enrollment = pathResolver.enrollmentStore,
            let application = applications.first(where: { $0.id == applicationID }) else { return nil }
        let configured = configuredBaseRoot(for: application)
        let fileSystem = fileSystem
        let record = await Task.detached { () -> StorageVolumeEnrollmentStore.Record? in
            let root = URL(fileURLWithPath: configured, isDirectory: true)
            guard !fileSystem.fileExists(at: root),
                let record = try? enrollment.record(applicationStorageID: application.storageID),
                record.baseRootPath == root.standardizedFileURL.path else { return nil }
            do {
                try enrollment.validateMissingRoot(root, applicationStorageID: application.storageID)
                return nil
            } catch let error as ManagedPathError where error.code == .baseRootUnavailable {
                return record
            } catch { return nil }
        }.value
        guard let record, let current = applications.first(where: { $0.id == applicationID }),
            current.storageID == application.storageID, configuredBaseRoot(for: current) == configured else { return nil }
        return StorageVolumeForgetRequest(applicationID: application.id, applicationStorageID: application.storageID,
            applicationName: application.displayName, record: record)
    }

    func forgetStorageVolume(_ confirmed: StorageVolumeForgetRequest) async -> Bool {
        guard let enrollment = pathResolver.enrollmentStore, let repository,
            let application = applications.first(where: { $0.id == confirmed.applicationID }),
            application.storageID == confirmed.applicationStorageID,
            URL(fileURLWithPath: configuredBaseRoot(for: application)).standardizedFileURL.path == confirmed.record.baseRootPath else {
            return false
        }
        let defaultRoot = Self.defaultProfilesRootPath
        do {
            try await Task.detached {
                let result = try repository.tryWithExclusiveAccess { _ in
                    guard case .loaded(let snapshot) = repository.load(),
                        let current = snapshot.applications.first(where: {
                            $0.id == confirmed.applicationID && $0.storageID == confirmed.applicationStorageID
                        }) else { throw ManagedPathError(.rootIdentityChanged, path: confirmed.record.baseRootPath) }
                    let configured = current.baseStoragePath ?? ""
                    let root = configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultRoot : configured
                    guard URL(fileURLWithPath: root).standardizedFileURL.path == confirmed.record.baseRootPath else {
                        throw ManagedPathError(.rootIdentityChanged, path: confirmed.record.baseRootPath)
                    }
                    try enrollment.forget(applicationStorageID: confirmed.applicationStorageID, confirmedRecord: confirmed.record)
                }
                if case .busy = result { throw LibraryOperationInProgressError() }
            }.value
            healthItemsCache.removeAll()
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
