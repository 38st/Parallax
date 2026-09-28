import Foundation

extension StorageVolumeEnrollmentStore {
    private static let sharedStores = StorageVolumeEnrollmentRegistry()

    static func shared(applicationSupportURL: URL) throws -> StorageVolumeEnrollmentStore {
        try sharedStores.store(applicationSupportURL: applicationSupportURL)
    }
}

private final class StorageVolumeEnrollmentRegistry: @unchecked Sendable {
    private final class Reference {
        weak var value: StorageVolumeEnrollmentStore?
        init(_ value: StorageVolumeEnrollmentStore) { self.value = value }
    }

    private let lock = NSLock()
    private var stores: [URL: Reference] = [:]

    func store(applicationSupportURL: URL) throws -> StorageVolumeEnrollmentStore {
        try lock.withLock {
            let key = applicationSupportURL.standardizedFileURL
            if let existing = stores[key]?.value { return existing }
            let store = try StorageVolumeEnrollmentStore(applicationSupportURL: key)
            stores = stores.filter { $0.value.value != nil }
            stores[key] = Reference(store)
            return store
        }
    }
}
