import Foundation
import XCTest
@testable import Parallax

final class LibraryBackupAuditRegressionTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory
        .appendingPathComponent("Parallax-BackupAudit-Uninitialized-\(UUID().uuidString)")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Parallax-BackupAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testClockRollbackKeepsPublishedBackupAndRestoresLatestPublication() throws {
        for index in 0..<5 {
            _ = try store(time: 10_000 + Double(index)).createBackup(of: bytes(index), reason: .manual)
        }
        let rollbackStore = store(time: 100)
        let latestBytes = try bytes(99)
        let latest = try rollbackStore.createBackup(of: latestBytes, reason: .importReplacement)
        XCTAssertEqual(try rollbackStore.prepareRestore(from: latest).bytes, latestBytes)
        XCTAssertEqual(try rollbackStore.prepareLatestBackupRestore().artifact.id, latest.id)
        XCTAssertEqual(try rollbackStore.inspectArtifacts().count, 5)
        XCTAssertEqual(try rollbackStore.inspectArtifacts().first?.artifact.id, latest.id)
    }

    func testPreviousBuildMetadataWithoutSequenceRemainsRestorableAndOlderThanNewPublication() throws {
        let old = try store(time: 10_000).createBackup(of: bytes(1), reason: .manual)
        let metadataURL = old.libraryURL.deletingLastPathComponent().appendingPathComponent("metadata.json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata.removeValue(forKey: "publicationSequence")
        metadata.removeValue(forKey: "publicationOrderingDate")
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        XCTAssertEqual(try store(time: 100).prepareRestore(from: old).bytes, try bytes(1))
        let new = try store(time: 100).createBackup(of: bytes(2), reason: .manual)
        XCTAssertEqual(try store(time: 100).prepareLatestBackupRestore().artifact.id, new.id)
    }

    func testFinderMetadataDoesNotInvalidateBackupOrQuarantine() throws {
        let store = store(time: 100)
        let bytes = try bytes(1)
        let backup = try store.createBackup(of: bytes, reason: .manual)
        let quarantine = try store.quarantine(Data("broken primary".utf8))
        for artifact in [backup, quarantine] {
            try Data("Finder metadata".utf8).write(to: artifact.libraryURL
                .deletingLastPathComponent().appendingPathComponent(".DS_Store"))
        }
        XCTAssertTrue(try store.inspectArtifacts().allSatisfy(\.isVerified))
        XCTAssertEqual(try store.prepareRestore(from: backup).bytes, bytes)
        let destination = root.appendingPathComponent("exported-quarantine.json")
        XCTAssertNoThrow(try store.export(quarantine, to: destination))
    }

    func testPublicationAndPruningHoldOneCrossInstanceLock() throws {
        let recoveryRoot = root.appendingPathComponent("Recovery")
        let fileSystem = MigrationOccurrenceFailingFileSystem()
        fileSystem.afterOperation = { event in
            let publishing = event.operation == .moveItem
                && event.firstURL?.lastPathComponent.hasPrefix(".staging-") == true
            let pruning = event.operation == .removeItem
                && event.firstURL?.pathExtension == "backup"
            guard publishing || pruning else { return }
            let lock = LibraryAdvisoryLock(url: recoveryRoot.appendingPathComponent(".publication.lock"))
            switch try lock.tryWithExclusiveLock({ true }) {
            case .busy: break
            case .acquired: XCTFail("Another backup publisher can prune before this publication finishes")
            }
        }
        let store = LibraryBackupStore(fileSystem: fileSystem, recoveryRoot: recoveryRoot, retentionLimit: 1)
        _ = try store.createBackup(of: bytes(1), reason: .manual)
        _ = try store.createBackup(of: bytes(2), reason: .manual)
        XCTAssertEqual(try store.inspectArtifacts().count, 1)
    }

    func testConcurrentPublishersBothCompleteWithDistinctPublicationSequences() throws {
        let recoveryRoot = root.appendingPathComponent("Recovery")
        let initialStore = LibraryBackupStore(recoveryRoot: recoveryRoot)
        for index in 0..<5 {
            _ = try initialStore.createBackup(of: bytes(index), reason: .manual)
        }
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let results = BackupAuditResults()
        let payloads = try [bytes(1), bytes(2)]
        for payload in payloads {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                start.wait()
                do {
                    let store = LibraryBackupStore(recoveryRoot: recoveryRoot,
                        now: { Date(timeIntervalSince1970: 100) })
                    results.append(.success(try store.createBackup(of: payload, reason: .manual)))
                } catch {
                    results.append(.failure(error))
                }
            }
        }
        start.signal()
        start.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 30), .success)
        let artifacts = try results.values.map { try $0.get() }
        XCTAssertEqual(artifacts.count, 2)
        let sequences = try artifacts.map { artifact -> UInt64 in
            let metadataURL = artifact.libraryURL.deletingLastPathComponent().appendingPathComponent("metadata.json")
            let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
            return try XCTUnwrap(metadata["publicationSequence"] as? NSNumber).uint64Value
        }
        XCTAssertEqual(Set(sequences), [6, 7])
        XCTAssertEqual(try initialStore.inspectArtifacts().count, 5)
        for artifact in artifacts {
            XCTAssertNoThrow(try initialStore.prepareRestore(from: artifact))
        }
    }

    func testImplausiblePublicationSequencesDoNotBlockBackupOrWinOrdering() throws {
        for sequence in [UInt64.max, UInt64.max - 1] {
            let old = try store(time: 100).createBackup(of: bytes(1), reason: .manual)
            let metadataURL = old.libraryURL.deletingLastPathComponent().appendingPathComponent("metadata.json")
            var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
            metadata["publicationSequence"] = NSNumber(value: sequence)
            try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
            let new = try store(time: 200).createBackup(of: bytes(2), reason: .manual)
            XCTAssertEqual(try store(time: 200).prepareLatestBackupRestore().artifact.id, new.id)
            XCTAssertNoThrow(try store(time: 200).prepareRestore(from: old))
        }
    }

    func testNewerDowngradeBackupRanksAfterSequencedBackupsAndSurvivesPruning() throws {
        for index in 0..<4 {
            _ = try store(time: 100 + Double(index)).createBackup(of: bytes(index), reason: .manual)
        }
        let legacy = try store(time: 200).createBackup(of: bytes(10), reason: .manual)
        let metadataURL = legacy.libraryURL.deletingLastPathComponent().appendingPathComponent("metadata.json")
        var metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any])
        metadata.removeValue(forKey: "publicationSequence")
        metadata.removeValue(forKey: "publicationOrderingDate")
        try JSONSerialization.data(withJSONObject: metadata).write(to: metadataURL)
        XCTAssertEqual(try store(time: 300).prepareLatestBackupRestore().artifact.id, legacy.id)
        let new = try store(time: 50).createBackup(of: bytes(11), reason: .manual)
        let artifacts = try store(time: 300).inspectArtifacts().map(\.artifact.id)
        XCTAssertEqual(Array(artifacts.prefix(2)), [new.id, legacy.id])
        XCTAssertNoThrow(try store(time: 300).prepareRestore(from: legacy))
        XCTAssertEqual(artifacts.count, 5)
    }

    func testPublicationLockTimeoutDoesNotClaimAnotherProcess() throws {
        let recoveryRoot = root.appendingPathComponent("Recovery")
        let store = LibraryBackupStore(recoveryRoot: recoveryRoot)
        _ = try store.createBackup(of: bytes(1), reason: .manual)
        let results = BackupAuditResults()
        let finished = DispatchSemaphore(value: 0)
        let payload = try bytes(2)
        try LibraryAdvisoryLock(url: recoveryRoot.appendingPathComponent(".publication.lock")).withExclusiveLock {
            DispatchQueue.global().async {
                defer { finished.signal() }
                do { results.append(.success(try store.createBackup(of: payload, reason: .manual))) }
                catch { results.append(.failure(error)) }
            }
            XCTAssertEqual(finished.wait(timeout: .now() + 10), .success)
        }
        guard case let .failure(error) = try XCTUnwrap(results.values.first) else {
            return XCTFail("Expected the held publication lock to prevent publication")
        }
        XCTAssertEqual(error.localizedDescription, String(localized:
            "Library recovery files are busy. Wait for the current operation to finish and retry."))
    }

    private func store(time: TimeInterval) -> LibraryBackupStore {
        LibraryBackupStore(recoveryRoot: root.appendingPathComponent("Recovery"),
            now: { Date(timeIntervalSince1970: time) })
    }

    private func bytes(_ revision: Int) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(LibraryDocument(
            revision: LibraryRevision(rawValue: UInt64(revision)), applications: []))
    }
}

private final class BackupAuditResults: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Result<LibraryRecoveryArtifact, Error>] = []

    var values: [Result<LibraryRecoveryArtifact, Error>] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ value: Result<LibraryRecoveryArtifact, Error>) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(value)
    }
}
