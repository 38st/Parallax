import Foundation

struct ApplicationRemovalTransactionJournal {
    let rootURL: URL
    var fileSystem: any FileSystem = LocalFileSystem()

    func pendingTransactions() throws -> [UUID] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil
        )
        .filter {
            $0.pathExtension == "json"
                && !$0.lastPathComponent.hasSuffix(".completed.json")
        }
        .compactMap {
            UUID(
                uuidString:
                    $0.deletingPathExtension().lastPathComponent
            )
        }
        .sorted { $0.uuidString < $1.uuidString }
    }

    func persist(
        _ manifest: ApplicationRemovalTransactionManifest
    ) throws {
        try writeDurably(JSONEncoder().encode(manifest), to: manifestURL(manifest.transactionID))
    }

    func loadManifest(
        transactionID: UUID
    ) throws -> ApplicationRemovalTransactionManifest {
        do {
            return try JSONDecoder().decode(
                ApplicationRemovalTransactionManifest.self,
                from: Data(contentsOf: manifestURL(transactionID))
            )
        } catch {
            throw ApplicationRemovalTransactionError(
                code: .transactionNotFound
            )
        }
    }

    func recordCompletion(
        _ manifest: ApplicationRemovalTransactionManifest,
        completion: ApplicationRemovalTransactionCompletion,
        archiveURLs: [UUID: URL]
    ) throws -> ApplicationRemovalTransactionOutcome {
        let record = ApplicationRemovalTransactionCompletedRecord(
            transactionID: manifest.transactionID,
            completion: completion,
            dataChoice: manifest.dataChoice,
            archivePaths: Dictionary(
                uniqueKeysWithValues: archiveURLs.map {
                    ($0.key.uuidString, $0.value.path)
                }
            )
        )
        try writeDurably(JSONEncoder().encode(record), to: completedURL(manifest.transactionID))
        try removeManifest(transactionID: manifest.transactionID)
        return ApplicationRemovalTransactionOutcome(
            transactionID: manifest.transactionID,
            completion: completion,
            dataChoice: manifest.dataChoice,
            archiveURLs: archiveURLs
        )
    }

    func completedOutcome(
        transactionID: UUID
    ) throws -> ApplicationRemovalTransactionOutcome? {
        let url = completedURL(transactionID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let record = try JSONDecoder().decode(
            ApplicationRemovalTransactionCompletedRecord.self,
            from: Data(contentsOf: url)
        )
        guard record.transactionID == transactionID else {
            throw ApplicationRemovalTransactionError(code: .invalidRequest)
        }
        var archives: [UUID: URL] = [:]
        for (key, path) in record.archivePaths {
            guard let profileID = UUID(uuidString: key), archives[profileID] == nil,
                  path.hasPrefix("/"), !path.contains("\0") else {
                throw ApplicationRemovalTransactionError(code: .invalidRequest)
            }
            archives[profileID] = URL(fileURLWithPath: path)
        }
        return ApplicationRemovalTransactionOutcome(
            transactionID: record.transactionID,
            completion: record.completion,
            dataChoice: record.dataChoice,
            archiveURLs: archives
        )
    }

    func keepFiles(_ review: ApplicationRemovalRecoveryReview) throws {
        let data = try manifestData(transactionID: review.transactionID)
        guard LibraryPersistence.sha256(data) == review.manifestSHA256 else {
            throw ApplicationRemovalTransactionError(code: .targetChanged)
        }
        let record = ApplicationRemovalTransactionCompletedRecord(
            transactionID: review.transactionID,
            completion: .keptFiles,
            dataChoice: .keep,
            archivePaths: [:],
            preservedManifest: data,
            preservedPaths: review.locations.map(\.path)
        )
        try writeDurably(JSONEncoder().encode(record), to: completedURL(review.transactionID))
        try removeManifest(transactionID: review.transactionID)
    }

    func preservedFiles() throws -> [ApplicationRemovalPreservedFiles] {
        guard fileSystem.fileExists(at: rootURL) else { return [] }
        return try fileSystem.contentsOfDirectory(at: rootURL)
            .filter { $0.lastPathComponent.hasSuffix(".completed.json") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                let record = try JSONDecoder().decode(
                    ApplicationRemovalTransactionCompletedRecord.self,
                    from: fileSystem.readData(at: url)
                )
                guard record.completion == .keptFiles else { return nil }
                guard let data = record.preservedManifest else {
                    throw ApplicationRemovalTransactionError(code: .invalidRequest)
                }
                let manifest = try JSONDecoder().decode(ApplicationRemovalTransactionManifest.self, from: data)
                let review = try ApplicationRemovalTransactionCoordinator.recoveryReview(
                    data: data, transactionID: record.transactionID
                )
                // Once every recorded location is gone, for example after the
                // person reviewed and removed them, nothing remains to review.
                guard review.locations.contains(where: { fileSystem.fileExists(at: $0) }) else { return nil }
                return ApplicationRemovalPreservedFiles(
                    id: record.transactionID,
                    applicationStorageID: manifest.applicationStorageID,
                    locations: review.locations
                )
            }
    }

    func manifestData(transactionID: UUID) throws -> Data {
        try Data(contentsOf: manifestURL(transactionID))
    }

    func removeManifest(transactionID: UUID) throws {
        let url = manifestURL(transactionID)
        if fileSystem.fileExists(at: url) {
            try fileSystem.removeItem(at: url)
            try fileSystem.synchronize(at: rootURL)
        }
    }

    private func writeDurably(_ data: Data, to url: URL) throws {
        try prepareRoot()
        let temporary = rootURL.appendingPathComponent(".\(UUID().uuidString).tmp")
        defer { try? fileSystem.removeItem(at: temporary) }
        try fileSystem.writeData(data, to: temporary)
        try fileSystem.setPOSIXPermissions(0o600, at: temporary)
        try fileSystem.synchronize(at: temporary)
        try fileSystem.replaceItem(at: url, withItemAt: temporary)
        try fileSystem.synchronize(at: rootURL)
    }

    private func prepareRoot() throws {
        try fileSystem.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileSystem.setPOSIXPermissions(0o700, at: rootURL)
        try fileSystem.synchronize(at: rootURL.deletingLastPathComponent())
    }

    private func manifestURL(_ transactionID: UUID) -> URL {
        rootURL.appendingPathComponent(
            "\(transactionID.uuidString.lowercased()).json"
        )
    }

    private func completedURL(_ transactionID: UUID) -> URL {
        rootURL.appendingPathComponent(
            "\(transactionID.uuidString.lowercased()).completed.json"
        )
    }
}
