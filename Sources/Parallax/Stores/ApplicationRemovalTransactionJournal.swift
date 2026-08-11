import Foundation

struct ApplicationRemovalTransactionJournal {
    private let fileManager = FileManager.default
    let rootURL: URL

    func pendingTransactions() throws -> [UUID] {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return []
        }
        return try fileManager.contentsOfDirectory(
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
        try prepareRoot()
        let data = try JSONEncoder().encode(manifest)
        let url = manifestURL(manifest.transactionID)
        try data.write(
            to: url,
            options: [.atomic]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
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
        try prepareRoot()
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
        let completionURL = completedURL(manifest.transactionID)
        try JSONEncoder().encode(record).write(
            to: completionURL,
            options: [.atomic]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: completionURL.path
        )
        try? fileManager.removeItem(
            at: manifestURL(manifest.transactionID)
        )
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
        guard fileManager.fileExists(atPath: url.path) else {
            return nil
        }
        let record = try JSONDecoder().decode(
            ApplicationRemovalTransactionCompletedRecord.self,
            from: Data(contentsOf: url)
        )
        return ApplicationRemovalTransactionOutcome(
            transactionID: record.transactionID,
            completion: record.completion,
            dataChoice: record.dataChoice,
            archiveURLs: Dictionary(
                uniqueKeysWithValues:
                    record.archivePaths.compactMap {
                        key,
                        path in
                        UUID(uuidString: key).map {
                            ($0, URL(fileURLWithPath: path))
                        }
                    }
            )
        )
    }

    private func prepareRoot() throws {
        try fileManager.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: NSNumber(value: Int16(0o700))
            ]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: rootURL.path
        )
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
