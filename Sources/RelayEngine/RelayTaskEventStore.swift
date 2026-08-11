import Foundation
import RelayCore

public struct RelayEventBatch: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let batchID: UUID
    public let taskID: RelayTaskID
    public let occurredAt: RelayInstant
    public let events: [RelayEvent]

    public init(
        schemaVersion: Int = RelaySchema.currentVersion,
        batchID: UUID,
        taskID: RelayTaskID,
        occurredAt: RelayInstant,
        events: [RelayEvent]
    ) {
        self.schemaVersion = schemaVersion
        self.batchID = batchID
        self.taskID = taskID
        self.occurredAt = occurredAt
        self.events = events
    }
}

public enum RelayTaskEventStoreError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case corruptBatch(UInt64)
    case wrongTask(UInt64)
    case duplicateBatch(UUID)
    case emptyBatch
    case transitionInProgress
}

/// Durable command boundary for RelayCore.
///
/// Every validated command becomes exactly one journal payload even when the
/// reducer emits several events. Recovery therefore observes either the whole
/// transition or none of it; it never accepts half of an attempt failure plus
/// its missing task-waiting event.
public actor RelayTaskEventStore {
    private let journal: RelayEventJournal
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var transitionInProgress = false

    public init(root: URL) {
        journal = RelayEventJournal(root: root)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        decoder = JSONDecoder()
    }

    public func prepare() async throws {
        try await journal.prepare()
    }

    public func taskIDs() async throws -> [RelayTaskID] {
        try await journal.taskIDs().map(RelayTaskID.init)
    }

    public func projection(
        taskID: RelayTaskID
    ) async throws -> RelayProjection {
        let batches = try await loadBatches(taskID: taskID)
        return try RelayReducer.replay(batches.flatMap(\.events))
    }

    @discardableResult
    public func perform(
        taskID: RelayTaskID,
        command: RelayCommand,
        at instant: RelayInstant = RelayInstant(date: Date())
    ) async throws -> RelayProjection {
        guard !transitionInProgress else {
            throw RelayTaskEventStoreError.transitionInProgress
        }
        transitionInProgress = true
        defer { transitionInProgress = false }
        let current = try await projection(taskID: taskID)
        let events = try RelayReducer.events(
            for: command,
            applyingTo: current
        )
        guard !events.isEmpty else {
            throw RelayTaskEventStoreError.emptyBatch
        }
        let batch = RelayEventBatch(
            batchID: UUID(),
            taskID: taskID,
            occurredAt: instant,
            events: events
        )
        let bytes = try encoder.encode(batch)
        _ = try await journal.append(
            taskID: taskID.rawValue,
            payload: bytes,
            occurredAt: Date(
                timeIntervalSince1970:
                    TimeInterval(instant.rawValue) / 1_000
            )
        )
        return try RelayReducer.apply(events, to: current)
    }

    public func loadBatches(
        taskID: RelayTaskID
    ) async throws -> [RelayEventBatch] {
        let records = try await journal.load(taskID: taskID.rawValue)
        var seen = Set<UUID>()
        return try records.map { record in
            let batch: RelayEventBatch
            do {
                batch = try decoder.decode(
                    RelayEventBatch.self,
                    from: record.payload
                )
            } catch {
                throw RelayTaskEventStoreError.corruptBatch(record.sequence)
            }
            guard batch.schemaVersion == RelaySchema.currentVersion else {
                throw RelayTaskEventStoreError.unsupportedSchema(
                    batch.schemaVersion
                )
            }
            guard batch.taskID == taskID else {
                throw RelayTaskEventStoreError.wrongTask(record.sequence)
            }
            guard seen.insert(batch.batchID).inserted else {
                throw RelayTaskEventStoreError.duplicateBatch(batch.batchID)
            }
            guard !batch.events.isEmpty else {
                throw RelayTaskEventStoreError.emptyBatch
            }
            return batch
        }
    }
}
