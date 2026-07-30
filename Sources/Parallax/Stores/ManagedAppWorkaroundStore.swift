import Foundation
import Observation

enum ManagedAppWorkaroundState: String, Codable, Sendable {
    case appliedAwaitingRestart
    case verified
    case rollbackPending
    case rolledBack
}

struct ManagedAppWorkaroundRecord:
    Identifiable,
    Codable,
    Equatable,
    Sendable
{
    var id: String {
        [
            applicationStorageID.uuidString.lowercased(),
            profileStorageID.uuidString.lowercased(),
            workaroundID,
        ].joined(separator: ":")
    }

    let applicationStorageID: UUID
    let profileStorageID: UUID
    let workaroundID: String
    let displayName: String
    let definitionVersion: Int
    let configurationReference: String
    var state: ManagedAppWorkaroundState
    var updatedAt: Date
    var operatorNote: String?
}

enum ManagedAppWorkaroundStoreError: LocalizedError {
    case invalidDocument
    case unsupportedSchema(Int)
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .invalidDocument:
            "Managed-app workaround state could not be read."
        case let .unsupportedSchema(version):
            "Managed-app workaround state uses unsupported format \(version)."
        case .invalidRecord:
            "The workaround record is invalid and was not saved."
        }
    }
}

@Observable
@MainActor
final class ManagedAppWorkaroundStore {
    private struct Document: Codable {
        let schemaVersion: Int
        let records: [ManagedAppWorkaroundRecord]
    }

    private static let schemaVersion = 1
    private static let maximumDocumentBytes = 1 * 1_024 * 1_024
    private static let fileName = "managed-app-workarounds.json"

    private(set) var records: [ManagedAppWorkaroundRecord]
    private(set) var persistenceErrorMessage: String?

    @ObservationIgnored private let storageURL: URL?
    @ObservationIgnored private let fileManager: FileManager

    init(persistenceErrorMessage: String? = nil) {
        records = []
        self.persistenceErrorMessage = persistenceErrorMessage
        storageURL = nil
        fileManager = .default
    }

    init(
        applicationSupportURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = applicationSupportURL
            .appendingPathComponent("Parallax", isDirectory: true)
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [
                .posixPermissions: NSNumber(value: Int16(0o700))
            ]
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directory.path
        )
        storageURL = directory.appendingPathComponent(
            Self.fileName,
            isDirectory: false
        )
        self.fileManager = fileManager
        records = []
        persistenceErrorMessage = nil
        load()
    }

    func records(
        applicationStorageID: UUID,
        profileStorageID: UUID? = nil
    ) -> [ManagedAppWorkaroundRecord] {
        records.filter {
            $0.applicationStorageID == applicationStorageID
                && (profileStorageID == nil
                    || $0.profileStorageID == profileStorageID)
        }
    }

    @discardableResult
    func upsert(_ record: ManagedAppWorkaroundRecord) -> Bool {
        guard
            !record.workaroundID.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
            !record.displayName.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty,
            record.definitionVersion > 0,
            record.configurationReference.count <= 500,
            (record.operatorNote?.count ?? 0) <= 1_000
        else {
            persistenceErrorMessage =
                ManagedAppWorkaroundStoreError.invalidRecord
                    .localizedDescription
            return false
        }

        records.removeAll { $0.id == record.id }
        records.append(record)
        records.sort { $0.updatedAt > $1.updatedAt }
        return persist()
    }

    @discardableResult
    func remove(
        applicationStorageID: UUID,
        profileStorageID: UUID,
        workaroundID: String
    ) -> Bool {
        let priorCount = records.count
        records.removeAll {
            $0.applicationStorageID == applicationStorageID
                && $0.profileStorageID == profileStorageID
                && $0.workaroundID == workaroundID
        }
        guard records.count != priorCount else { return true }
        return persist()
    }

    private func load() {
        guard
            let storageURL,
            fileManager.fileExists(atPath: storageURL.path)
        else {
            return
        }
        do {
            let attributes = try fileManager.attributesOfItem(
                atPath: storageURL.path
            )
            let byteCount =
                (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard
                byteCount > 0,
                byteCount <= Self.maximumDocumentBytes
            else {
                throw ManagedAppWorkaroundStoreError.invalidDocument
            }
            let document = try JSONDecoder().decode(
                Document.self,
                from: Data(contentsOf: storageURL)
            )
            guard document.schemaVersion == Self.schemaVersion else {
                throw ManagedAppWorkaroundStoreError
                    .unsupportedSchema(document.schemaVersion)
            }
            records = document.records
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: storageURL.path
            )
        } catch {
            quarantineCorruptDocument()
            records = []
            persistenceErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard let storageURL else {
            persistenceErrorMessage = nil
            return true
        }
        do {
            let data = try JSONEncoder().encode(
                Document(
                    schemaVersion: Self.schemaVersion,
                    records: records
                )
            )
            try data.write(to: storageURL, options: .atomic)
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: storageURL.path
            )
            persistenceErrorMessage = nil
            return true
        } catch {
            persistenceErrorMessage = error.localizedDescription
            return false
        }
    }

    private func quarantineCorruptDocument() {
        guard
            let storageURL,
            fileManager.fileExists(atPath: storageURL.path)
        else {
            return
        }
        let quarantineURL = storageURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "managed-app-workarounds.corrupt.\(UUID().uuidString.lowercased()).json"
            )
        try? fileManager.moveItem(at: storageURL, to: quarantineURL)
        try? fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: quarantineURL.path
        )
    }
}
