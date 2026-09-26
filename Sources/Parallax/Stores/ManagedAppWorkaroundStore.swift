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
    private struct Header: Decodable { let schemaVersion: Int }

    private struct Document: Codable {
        let schemaVersion: Int
        let records: [ManagedAppWorkaroundRecord]
    }

    private static let schemaVersion = 1
    private static let maximumDocumentBytes = 1 * 1_024 * 1_024
    private static let fileName = "managed-app-workarounds.json"
    private static let lockFileName = ".managed-app-workarounds.lock"

    private(set) var records: [ManagedAppWorkaroundRecord]
    private(set) var persistenceErrorMessage: String?

    @ObservationIgnored private let fileStore: TrustedContainerFileStore?

    init(persistenceErrorMessage: String? = nil) {
        records = []
        self.persistenceErrorMessage = persistenceErrorMessage
        fileStore = nil
    }

    init(
        applicationSupportURL: URL,
        fileManager: FileManager = .default
    ) throws {
        _ = fileManager
        let container = try TrustedParallaxContainer.establish(
            applicationSupportURL: applicationSupportURL
        )
        fileStore = TrustedContainerFileStore(container: container)
        records = []
        persistenceErrorMessage = nil
        load()
    }

    init(trustedContainer: TrustedParallaxContainer) throws {
        try trustedContainer.validate()
        fileStore = TrustedContainerFileStore(
            container: trustedContainer
        )
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

        return mutate { records in
            records.removeAll { $0.id == record.id }
            records.append(record)
        }
    }

    @discardableResult
    func remove(
        applicationStorageID: UUID,
        profileStorageID: UUID,
        workaroundID: String
    ) -> Bool {
        mutate { records in
            records.removeAll {
                $0.applicationStorageID == applicationStorageID
                    && $0.profileStorageID == profileStorageID
                    && $0.workaroundID == workaroundID
            }
        }
    }

    private func readRecords() throws -> [ManagedAppWorkaroundRecord] {
        guard let fileStore else { return records }
        let data: Data
        switch try fileStore.read(named: Self.fileName, maximumBytes: Self.maximumDocumentBytes) {
        case .missing: return []
        case .bytes(let bytes): data = bytes
        }
        guard !data.isEmpty else { throw ManagedAppWorkaroundStoreError.invalidDocument }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.schemaVersion == Self.schemaVersion else {
            throw ManagedAppWorkaroundStoreError.unsupportedSchema(header.schemaVersion)
        }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schemaVersion == Self.schemaVersion else {
            throw ManagedAppWorkaroundStoreError.unsupportedSchema(document.schemaVersion)
        }
        return document.records
    }

    private func load() {
        guard let fileStore else { return }
        do {
            try fileStore.withExclusiveLock(named: Self.lockFileName) {
                do {
                    records = try readRecords()
                } catch {
                    if let failure = error as? ManagedAppWorkaroundStoreError,
                        case .unsupportedSchema = failure
                    {
                        throw error
                    }
                    let originalError = error
                    if try quarantineCorruptDocument() != nil {
                        try fileStore.replace(
                            JSONEncoder().encode(
                                Document(schemaVersion: Self.schemaVersion, records: [])),
                            named: Self.fileName
                        )
                    }
                    throw originalError
                }
            }
        } catch {
            persistenceErrorMessage = error.localizedDescription
        }
    }

    private func mutate(_ change: (inout [ManagedAppWorkaroundRecord]) -> Void) -> Bool {
        guard let fileStore else {
            change(&records)
            records.sort { $0.updatedAt > $1.updatedAt }
            persistenceErrorMessage = nil
            return true
        }
        do {
            try fileStore.withExclusiveLock(named: Self.lockFileName) {
                var candidate = try readRecords()
                change(&candidate)
                candidate.sort { $0.updatedAt > $1.updatedAt }
                try fileStore.replace(
                    JSONEncoder().encode(
                        Document(schemaVersion: Self.schemaVersion, records: candidate)),
                    named: Self.fileName
                )
                records = candidate
            }
            persistenceErrorMessage = nil
            return true
        } catch {
            persistenceErrorMessage = error.localizedDescription
            return false
        }
    }

    private func quarantineCorruptDocument()
        throws -> TrustedContainerFileResidual?
    {
        guard
            let fileStore
        else {
            return nil
        }
        let preferred = "managed-app-workarounds.corrupt.retained.json"
        let name: String
        switch try fileStore.read(named: preferred, maximumBytes: Self.maximumDocumentBytes) {
        case .missing: name = preferred
        case .bytes: name = "managed-app-workarounds.corrupt-\(UUID().uuidString).retained.json"
        }
        return try fileStore.quarantine(named: Self.fileName, as: name)
    }
}
