import Foundation
import Observation

extension LaunchHistoryStore {
    func readPersistedEntries() throws -> [LaunchHistoryEntry] {
        guard let fileStore else {
            return []
        }
        let data: Data
        switch try fileStore.read(
            named: Self.fileName,
            maximumBytes: Self.maximumDocumentBytes
        ) {
        case .missing:
            return []
        case .bytes(let bytes):
            data = bytes
        }
        guard !data.isEmpty else {
            throw LaunchHistoryStoreError.invalidDocument
        }
        let header = try JSONDecoder().decode(Header.self, from: data)
        guard header.schemaVersion == Self.schemaVersion else {
            throw LaunchHistoryStoreError.unsupportedSchema(header.schemaVersion)
        }
        let document = try decoder.decode(
            Document.self,
            from: data
        )
        guard document.schemaVersion == Self.schemaVersion else {
            throw LaunchHistoryStoreError.unsupportedSchema(
                document.schemaVersion
            )
        }
        return document.entries
    }

    func mergedEntries(
        _ first: [LaunchHistoryEntry],
        _ second: [LaunchHistoryEntry]
    ) -> [LaunchHistoryEntry] {
        var merged: [UUID: LaunchHistoryEntry] = [:]
        for candidate in first + second {
            guard let existing = merged[candidate.requestID] else {
                merged[candidate.requestID] = candidate
                continue
            }
            if candidate.state.isTerminal != existing.state.isTerminal {
                if candidate.state.isTerminal { merged[candidate.requestID] = candidate }
            } else if recency(of: candidate) >= recency(of: existing) {
                merged[candidate.requestID] = candidate
            }
        }
        return Array(merged.values)
    }

    private func recency(
        of entry: LaunchHistoryEntry
    ) -> Date {
        entry.updatedAt
            ?? entry.endedAt
            ?? entry.startedAt
            ?? entry.requestedAt
    }

    func quarantineCorruptDocument()
        throws -> TrustedContainerFileResidual?
    {
        guard
            let fileStore
        else {
            return nil
        }
        let preferred = "launch-history.corrupt.retained.json"
        let name: String
        switch try fileStore.read(named: preferred, maximumBytes: Self.maximumDocumentBytes) {
        case .missing: name = preferred
        case .bytes: name = "launch-history.corrupt-\(UUID().uuidString).retained.json"
        }
        return try fileStore.quarantine(named: Self.fileName, as: name)
    }
}
