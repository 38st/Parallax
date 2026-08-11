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
            let fileStore
        else {
            return
        }
        do {
            let data: Data
            switch try fileStore.read(
                named: Self.fileName,
                maximumBytes: Self.maximumDocumentBytes
            ) {
            case .missing:
                return
            case .bytes(let bytes):
                data = bytes
            }
            guard !data.isEmpty else {
                throw ManagedAppWorkaroundStoreError.invalidDocument
            }
            let document = try JSONDecoder().decode(
                Document.self,
                from: data
            )
            guard document.schemaVersion == Self.schemaVersion else {
                throw ManagedAppWorkaroundStoreError
                    .unsupportedSchema(document.schemaVersion)
            }
            records = document.records
        } catch {
            var residual: TrustedContainerFileResidual?
            var quarantineErrorMessage: String?
            do {
                residual = try quarantineCorruptDocument()
            } catch {
                quarantineErrorMessage = error.localizedDescription
            }
            records = []
            persistenceErrorMessage = [
                error.localizedDescription,
                residual?.cleanupDescription,
                quarantineErrorMessage
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        }
    }

    @discardableResult
    private func persist() -> Bool {
        guard let fileStore else {
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
            try fileStore.replace(
                data,
                named: Self.fileName
            )
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
        return try fileStore.quarantine(
            named: Self.fileName,
            as: "managed-app-workarounds.corrupt.retained.json"
        )
    }
}
