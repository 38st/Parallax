import Foundation
import RelayCore
import RelayEngine
import XCTest

final class RelayTaskEventStoreTests: XCTestCase {
    func testValidatedCommandIsDurableAndReplaysAfterRestart() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = taskDefinition()
        let instant = RelayInstant(rawValue: 1_000)
        let firstStore = RelayTaskEventStore(root: root)

        let afterCreate = try await firstStore.perform(
            taskID: task.id,
            command: .createTask(task),
            at: instant
        )
        XCTAssertEqual(afterCreate.task, task)
        XCTAssertEqual(afterCreate.status, .draft)

        let restarted = RelayTaskEventStore(root: root)
        let replayed = try await restarted.projection(taskID: task.id)
        XCTAssertEqual(replayed, afterCreate)
        let taskIDs = try await restarted.taskIDs()
        XCTAssertEqual(taskIDs, [task.id])
        let batches = try await restarted.loadBatches(taskID: task.id)
        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].events, [.taskCreated(task)])
    }

    func testRejectedCommandDoesNotAppendJournalRecord() async throws {
        let root = testRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = taskDefinition()
        let store = RelayTaskEventStore(root: root)
        _ = try await store.perform(
            taskID: task.id,
            command: .createTask(task)
        )

        do {
            _ = try await store.perform(
                taskID: task.id,
                command: .createTask(task)
            )
            XCTFail("duplicate task creation was accepted")
        } catch RelayCoreError.taskAlreadyExists {
            // Expected.
        }
        let batchCount = try await store.loadBatches(taskID: task.id).count
        XCTAssertEqual(batchCount, 1)
    }

    private func taskDefinition() -> RelayTaskDefinition {
        RelayTaskDefinition(
            id: RelayTaskID(),
            title: "Relay test",
            objective: "Prove durable commands",
            acceptanceCriteria: ["State replays exactly"],
            stages: [
                RelayStageDefinition(
                    id: RelayStageID(),
                    name: "Scout",
                    role: .scout,
                    authority: .scout
                )
            ],
            createdAt: RelayInstant(rawValue: 1_000)
        )
    }

    private func testRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "parallax-relay-task-store-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}
