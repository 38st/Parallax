import Foundation
import RelayEngine
import XCTest

final class RelayFaultInjectionJournalTests: XCTestCase {
    func testEveryPersistedRecordCorruptionFailsClosedAndPreservesBytes() async throws {
        for corruptSequence in 0..<3 {
            let root = temporaryRoot("record-\(corruptSequence)")
            defer { try? FileManager.default.removeItem(at: root) }
            let taskID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
            let journal = RelayEventJournal(root: root)
            for sequence in 0..<3 {
                _ = try await journal.append(
                    taskID: taskID,
                    payload: Data("event-\(sequence)".utf8),
                    occurredAt: Date(timeIntervalSince1970: Double(sequence))
                )
            }
            let record = recordURL(
                root: root,
                taskID: taskID,
                sequence: UInt64(corruptSequence)
            )
            let original = try Data(contentsOf: record)
            let corrupted = RelayEvidenceCorruptionFixture.truncating(
                original,
                toByteCount: max(1, original.count / 2)
            )
            try corrupted.write(to: record)

            do {
                _ = try await journal.load(taskID: taskID)
                XCTFail("corrupted record \(corruptSequence) was accepted")
            } catch RelayEventJournalError.corruptRecord(UInt64(corruptSequence)) {
                // Expected exact boundary.
            } catch {
                XCTFail("unexpected corruption result: \(error)")
            }
            XCTAssertEqual(try Data(contentsOf: record), corrupted)
            for priorSequence in 0..<corruptSequence {
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: recordURL(
                            root: root,
                            taskID: taskID,
                            sequence: UInt64(priorSequence)
                        ).path
                    )
                )
            }
        }
    }

    func testCrashResidueCannotBeMistakenForAnAcceptedAppend() async throws {
        let root = temporaryRoot("crash-residue")
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        let journal = RelayEventJournal(root: root)
        _ = try await journal.append(
            taskID: taskID,
            payload: Data("accepted".utf8),
            occurredAt: Date(timeIntervalSince1970: 0)
        )
        let taskDirectory = root.appendingPathComponent(
            taskID.uuidString.lowercased()
        )
        let residue = taskDirectory.appendingPathComponent(
            ".event-00000000000000000001.json.partial"
        )
        try Data("status=pass".utf8).write(to: residue)

        do {
            _ = try await journal.load(taskID: taskID)
            XCTFail("crash residue was ignored as though append completed")
        } catch RelayEventJournalError.invalidRecordName(
            ".event-00000000000000000001.json.partial"
        ) {
            // Expected.
        } catch {
            XCTFail("unexpected residue result: \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: residue.path))
    }

    private func temporaryRoot(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "parallax-relay-fault-journal-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func recordURL(
        root: URL,
        taskID: UUID,
        sequence: UInt64
    ) -> URL {
        root.appendingPathComponent(taskID.uuidString.lowercased())
            .appendingPathComponent(
                String(format: "event-%020llu.json", sequence)
            )
    }
}
