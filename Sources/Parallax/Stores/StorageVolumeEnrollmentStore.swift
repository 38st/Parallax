import Darwin
import Foundation

/// Advisory volume memory, separate from library metadata and transaction authority.
final class StorageVolumeEnrollmentStore: Sendable {
    struct Record: Codable, Equatable, Sendable {
        let baseRootPath: String
        let volumeUUID: String?
    }

    let applicationSupportURL: URL
    let identitySource: StorageVolumeIdentitySource
    let isVolumeMounted: @Sendable (String) throws -> Bool

    init(applicationSupportURL: URL,
         identitySource: @escaping StorageVolumeIdentitySource = StorageVolumeIdentity.read,
         isVolumeMounted: @escaping @Sendable (String) throws -> Bool = StorageVolumeEnrollmentStore.isMounted) throws {
        guard applicationSupportURL.isFileURL, applicationSupportURL.path.hasPrefix("/") else {
            throw TrustedParallaxContainerError.invalidURL(applicationSupportURL.path)
        }
        self.applicationSupportURL = applicationSupportURL
        self.identitySource = identitySource
        self.isVolumeMounted = isVolumeMounted
    }

    private func fileStore() throws -> TrustedContainerFileStore {
        let secure = try SecureManagedFileSystem(anchorURL: applicationSupportURL,
            rootComponents: [TrustedParallaxContainer.directoryName], createIfMissing: true)
        let container = try TrustedParallaxContainer(adoptingValidatedContainer:
            FileHandle(fileDescriptor: secure.rootDescriptor, closeOnDealloc: false),
            url: URL(fileURLWithPath: secure.rootPath, isDirectory: true))
        return TrustedContainerFileStore(container: container)
    }

    func record(applicationStorageID: UUID) throws -> Record? {
        do { return try readRecord(applicationStorageID, files: fileStore()) }
        catch {
            AppLog.persistence.error("Storage volume enrollment could not be read: \(error.localizedDescription)")
            return nil
        }
    }

    private func readRecord(_ id: UUID, files: TrustedContainerFileStore) throws -> Record? {
        switch try files.read(named: name(id), maximumBytes: 16 * 1_024) {
        case .missing: return nil
        case .bytes(let bytes):
            let record = try JSONDecoder().decode(Record.self, from: bytes)
            guard record.baseRootPath.hasPrefix("/"), !record.baseRootPath.contains("\0"),
                record.baseRootPath == URL(fileURLWithPath: record.baseRootPath).standardizedFileURL.path,
                record.volumeUUID == nil || record.volumeUUID.flatMap(UUID.init(uuidString:)) != nil else {
                throw TrustedContainerFileStoreError.unsafeItem(name(id))
            }
            return record
        }
    }

    func enroll(applicationStorageID: UUID, configuredBaseRoot: URL, canonicalBaseRoot: URL) throws {
        let secure = try SecureManagedFileSystem(rootURL: canonicalBaseRoot)
        let identity = try identitySource(secure)
        try recordVerifiedRoot(applicationStorageID: applicationStorageID, baseRoot: configuredBaseRoot,
            volumeUUID: identity.volumeUUID)
    }

    func enrollBestEffort(applicationStorageID: UUID, configuredBaseRoot: URL, canonicalBaseRoot: URL) {
        do {
            try enroll(applicationStorageID: applicationStorageID, configuredBaseRoot: configuredBaseRoot,
                canonicalBaseRoot: canonicalBaseRoot)
        } catch { AppLog.persistence.error("Storage volume enrollment failed: \(error.localizedDescription)") }
    }

    func recordVerifiedRoot(applicationStorageID: UUID, baseRoot: URL, volumeUUID: String?) throws {
        let files = try fileStore()
        try files.withExclusiveLock(named: ".storage-volumes.lock") {
            let previous: Record?
            do { previous = try readRecord(applicationStorageID, files: files) }
            catch {
                // Move the entry itself without following links or deleting unknown data.
                try preserveInvalidRecord(applicationStorageID, files: files)
                previous = nil
            }
            let path = baseRoot.standardizedFileURL.path
            let record = Record(baseRootPath: path, volumeUUID: volumeUUID
                ?? (previous?.baseRootPath == path ? previous?.volumeUUID : nil))
            if record != previous {
                try files.replace(JSONEncoder().encode(record), named: name(applicationStorageID))
            }
        }
    }

    private func preserveInvalidRecord(_ id: UUID, files: TrustedContainerFileStore) throws {
        try files.container.withValidatedRootDescriptor { root in
            let preserved = name(id) + ".invalid-" + UUID().uuidString.lowercased()
            guard renameatx_np(root, name(id), root, preserved, UInt32(RENAME_EXCL)) == 0 || errno == ENOENT else {
                throw TrustedContainerFileStoreError.systemCall(operation: "preserve invalid volume enrollment", code: errno)
            }
            guard fsync(root) == 0 else {
                throw TrustedContainerFileStoreError.systemCall(operation: "sync volume enrollment", code: errno)
            }
        }
    }

    func validateMissingRoot(_ root: URL, applicationStorageID: UUID) throws {
        guard let previous = try record(applicationStorageID: applicationStorageID),
            previous.baseRootPath == root.standardizedFileURL.path,
            let uuid = previous.volumeUUID else { return }
        let mounted: Bool
        do { mounted = try isVolumeMounted(uuid) }
        catch {
            AppLog.persistence.error("Mounted volume inventory unavailable: \(error.localizedDescription)")
            return
        }
        guard mounted else { throw ManagedPathError(.baseRootUnavailable, path: root.path) }
    }

    func forget(applicationStorageID: UUID, confirmedRecord: Record) throws {
        let files = try fileStore()
        try files.withExclusiveLock(named: ".storage-volumes.lock") {
            guard try readRecord(applicationStorageID, files: files) == confirmedRecord else {
                throw ManagedPathError(.rootIdentityChanged, path: confirmedRecord.baseRootPath)
            }
            try files.container.withValidatedRootDescriptor { root in
                guard unlinkat(root, name(applicationStorageID), 0) == 0, fsync(root) == 0 else {
                    throw TrustedContainerFileStoreError.systemCall(operation: "forget volume enrollment", code: errno)
                }
            }
        }
    }

    private func name(_ id: UUID) -> String {
        "storage-volume-" + id.uuidString.lowercased() + ".json"
    }

    static func isMounted(_ uuid: String) throws -> Bool {
        guard let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeUUIDStringKey]) else {
            throw ManagedPathError(.baseRootUnavailable)
        }
        return volumes.contains { url in
            guard let current = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString else { return false }
            return current.caseInsensitiveCompare(uuid) == .orderedSame
        }
    }
}
