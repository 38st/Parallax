import Foundation
import RelayEngine
import XCTest

final class RelayEventJournalTests: XCTestCase {
    func testAppendBuildsVerifiedChainAndReloadsExactly() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID()
        let journal = RelayEventJournal(root: root)
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 101)

        let first = try await journal.append(
            taskID: taskID,
            payload: Data("one".utf8),
            occurredAt: firstDate
        )
        let second = try await journal.append(
            taskID: taskID,
            payload: Data("two".utf8),
            occurredAt: secondDate
        )
        let loaded = try await journal.load(taskID: taskID)

        XCTAssertEqual(loaded, [first, second])
        XCTAssertNil(first.previousDigest)
        XCTAssertEqual(second.previousDigest, first.digest)
        XCTAssertNotEqual(first.digest, second.digest)
    }

    func testTamperedRecordFailsClosedWithoutHidingAcceptedPrefix() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID()
        let journal = RelayEventJournal(root: root)
        _ = try await journal.append(taskID: taskID, payload: Data("one".utf8))
        _ = try await journal.append(taskID: taskID, payload: Data("two".utf8))
        let second = recordURL(root: root, taskID: taskID, sequence: 1)
        var bytes = try Data(contentsOf: second)
        bytes[bytes.startIndex] ^= 0x01
        try bytes.write(to: second)

        do {
            _ = try await journal.load(taskID: taskID)
            XCTFail("tampered record was accepted")
        } catch RelayEventJournalError.corruptRecord(1) {
            // Expected.
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recordURL(root: root, taskID: taskID, sequence: 0).path
        ))
    }

    func testMissingSequenceFailsClosed() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID()
        let journal = RelayEventJournal(root: root)
        _ = try await journal.append(taskID: taskID, payload: Data("one".utf8))
        _ = try await journal.append(taskID: taskID, payload: Data("two".utf8))
        try FileManager.default.moveItem(
            at: recordURL(root: root, taskID: taskID, sequence: 1),
            to: recordURL(root: root, taskID: taskID, sequence: 2)
        )

        do {
            _ = try await journal.load(taskID: taskID)
            XCTFail("record gap was accepted")
        } catch RelayEventJournalError.brokenSequence(
            expected: 1,
            actual: 2
        ) {
            // Expected.
        }
    }

    func testUnknownFileInTaskDirectoryFailsClosed() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID()
        let journal = RelayEventJournal(root: root)
        _ = try await journal.append(taskID: taskID, payload: Data("one".utf8))
        let taskDirectory = root.appendingPathComponent(
            taskID.uuidString.lowercased(),
            isDirectory: true
        )
        try Data("unknown".utf8).write(
            to: taskDirectory.appendingPathComponent("foreign")
        )

        do {
            _ = try await journal.load(taskID: taskID)
            XCTFail("unknown file was ignored")
        } catch RelayEventJournalError.invalidRecordName("foreign") {
            // Expected.
        }
    }

    func testOversizedPayloadIsRejectedBeforeCreatingTaskDirectory() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let taskID = UUID()
        let journal = RelayEventJournal(root: root)
        let payload = Data(
            repeating: 0,
            count: RelayEventJournal.maximumPayloadBytes + 1
        )

        do {
            _ = try await journal.append(taskID: taskID, payload: payload)
            XCTFail("oversized payload was accepted")
        } catch RelayEventJournalError.recordTooLarge {
            // Expected.
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(
                taskID.uuidString.lowercased()
            ).path
        ))
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "parallax-relay-journal-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return root
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
