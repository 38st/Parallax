import Foundation

struct LibraryBackupStoreOrdering {
    static func sequence(_ value: UInt64?) -> UInt64? {
        // Leave ample arithmetic headroom and reject implausible imported counts.
        guard let value, value > 0, value < UInt64.max / 2 else { return nil }
        return value
    }

    static func newestFirst<Value>(
        _ values: [Value],
        artifact: (Value) -> LibraryRecoveryArtifact
    ) -> [Value] {
        let artifacts = values.map(artifact)
        let sequences = artifacts.map { sequence($0.publicationSequence) }
        var dates = artifacts.map(\.createdAt)
        let sequenced = artifacts.indices.filter { sequences[$0] != nil }.sorted {
            if sequences[$0] != sequences[$1] {
                return (sequences[$0] ?? 0) < (sequences[$1] ?? 0)
            }
            return artifacts[$0].id.uuidString < artifacts[$1].id.uuidString
        }
        var latest = Date.distantPast
        for index in sequenced {
            // Existing sequenced backups may predate the ordering-date field.
            // A running maximum preserves their order across a clock rollback.
            latest = max(latest, artifacts[index].createdAt,
                artifacts[index].publicationOrderingDate ?? artifacts[index].createdAt)
            dates[index] = latest
        }
        return artifacts.indices.sorted {
            if dates[$0] != dates[$1] { return dates[$0] > dates[$1] }
            let lhsSequence = sequences[$0] ?? 0
            let rhsSequence = sequences[$1] ?? 0
            if lhsSequence != rhsSequence { return lhsSequence > rhsSequence }
            return artifacts[$0].id.uuidString > artifacts[$1].id.uuidString
        }.map { values[$0] }
    }
}
