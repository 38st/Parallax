import Foundation
import XCTest
@testable import Parallax

final class ApplicationRemovalAuditRegressionTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ApplicationRemovalAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testArchiveFinalizationInterruptionResumesEveryEntry() throws {
        let fixture = try fixture(.archive)
        let interrupted = try fixture.coordinator { boundary in
            if case .afterEffectBeforeRecord(.finalizeArchive(_, 0)) = boundary {
                throw ApplicationRemovalTransactionInterruption.simulatedCrash
            }
        }
        XCTAssertThrowsError(try fixture.execute(interrupted))
        let outcome = try fixture.recover()
        XCTAssertEqual(outcome.archiveURLs.count, 2)
        for (index, profile) in fixture.application.profiles.enumerated() {
            let archive = try XCTUnwrap(outcome.archiveURLs[profile.storageID])
            XCTAssertEqual(try String(contentsOf: archive.appendingPathComponent("payload.txt"), encoding: .utf8), "payload \(index)")
        }
        XCTAssertTrue(try fixture.coordinator().pendingTransactions().isEmpty)
        XCTAssertEqual(try fixture.recover(), outcome)
    }

    func testDeleteInterruptionDuringPurgeResumesWithoutOwnerMarker() throws {
        let fixture = try fixture(.delete)
        let interrupted = try fixture.coordinator { boundary in
            if case .afterEffectBeforeRecord(.purgeChild(_, let name)) = boundary,
               name.hasPrefix(".parallax-owner-") {
                throw ApplicationRemovalTransactionInterruption.simulatedCrash
            }
        }
        XCTAssertThrowsError(try fixture.execute(interrupted))
        XCTAssertEqual(try fixture.recover().completion, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest.stagingRootPath))
    }

    func testCompletionWithLeftoverManifestConverges() throws {
        let fixture = try fixture(.keep)
        let outcome = try fixture.execute(fixture.coordinator())
        try fixture.journal.persist(fixture.manifest)
        XCTAssertEqual(try fixture.recover(), outcome)
        XCTAssertTrue(try fixture.coordinator().pendingTransactions().isEmpty)
    }

    func testRollbackPreservesStagedCopyWhenSourceReappears() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .stageProfile(fixture.application.profiles[0].storageID, 0))
        try FileManager.default.createDirectory(at: fixture.sources[0], withIntermediateDirectories: true)
        let staged = URL(fileURLWithPath: fixture.manifest.entries[0].stagedPath)
        XCTAssertThrowsError(try fixture.recover())
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("payload.txt").path))
        XCTAssertEqual(try fixture.coordinator().pendingTransactions(), [fixture.transactionID])
    }

    func testRollbackReportsMissingOriginalInsteadOfCompleting() throws {
        let fixture = try fixture(.delete)
        try fixture.interrupt(after: .stageProfile(fixture.application.profiles[0].storageID, 0))
        try FileManager.default.removeItem(atPath: fixture.manifest.entries[0].stagedPath)
        XCTAssertThrowsError(try fixture.recover())
        XCTAssertEqual(try fixture.coordinator().pendingTransactions(), [fixture.transactionID])
    }

    func testNeverLaunchedApplicationWithMissingBaseCanBeRemoved() throws {
        for choice in [ApplicationRemovalDataChoice.archive, .delete] {
            let fixture = try fixture(choice, createData: false)
            XCTAssertEqual(try fixture.execute(fixture.coordinator()).completion, .committed)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.base.path))
        }
    }

    func testCommittedRemovalWithOldPhaseAndLaterLibraryWriteFinishes() throws {
        let fixture = try fixture(.archive)
        try fixture.interrupt(after: .commitMetadata)
        var manifest = try fixture.journal.loadManifest(transactionID: fixture.transactionID)
        manifest.phase = .prepared
        try fixture.journal.persist(manifest)
        guard case .loaded(let snapshot) = fixture.repository.load() else { return XCTFail() }
        _ = try fixture.repository.save([], expectedVersion: snapshot.versionToken)
        XCTAssertEqual(try fixture.recover().completion, .committed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sources[0].path))
    }

    func testRecoveryRejectsReplacedBaseRoot() throws {
        let fixture = try fixture(.archive)
        try fixture.interrupt(after: .stageProfile(fixture.application.profiles[0].storageID, 0))
        let previous = fixture.base.appendingPathExtension("previous")
        try FileManager.default.moveItem(at: fixture.base, to: previous)
        try FileManager.default.createDirectory(at: fixture.base, withIntermediateDirectories: true)
        // Preserve every entry inode so only the base-root check can reject it.
        try FileManager.default.moveItem(
            at: previous.appendingPathComponent(".parallax"),
            to: fixture.base.appendingPathComponent(".parallax"))
        XCTAssertThrowsError(try fixture.recover())
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.manifest.entries[0].stagedPath))
    }

    func testFailureCleanupKeepsLibraryLock() throws {
        let fixture = try fixture(.delete)
        let attempts = RemovalAuditCounter()
        let coordinator = try fixture.coordinator { boundary in
            guard case .beforeEffect(.purgeStaging) = boundary else { return }
            if attempts.increment() == 1 { throw RemovalAuditError.injected }
            switch try fixture.repository.tryWithExclusiveAccess({ _ in true }) {
            case .busy: break
            case .acquired: XCTFail("Failure cleanup released the library lock")
            }
        }
        XCTAssertThrowsError(try fixture.execute(coordinator))
        XCTAssertEqual(attempts.value, 2)
    }

    func testManifestIsPublishedOnlyAfterMutationLockAcquired() throws {
        let fixture = try fixture(.delete)
        let repository = RemovalAuditRepository(base: fixture.repository) {
            XCTAssertTrue(try fixture.journal.pendingTransactions().isEmpty)
        }
        _ = try fixture.coordinator().execute(fixture.request, preparedCommit: fixture.commit, repository: repository)
    }

    func testInvalidCompletionArchiveIdentifierFailsClosed() throws {
        let fixture = try fixture(.keep)
        let record = ApplicationRemovalTransactionCompletedRecord(
            transactionID: fixture.transactionID, completion: .committed,
            dataChoice: .archive, archivePaths: ["invalid": "/tmp/archive"])
        try fixture.journal.persist(fixture.manifest)
        let url = fixture.journal.rootURL.appendingPathComponent("\(fixture.transactionID.uuidString.lowercased()).completed.json")
        try JSONEncoder().encode(record).write(to: url)
        XCTAssertThrowsError(try fixture.recover())
    }

    func testJournalSyncFailurePreservesPreviousManifestAndCompletionEvidence() throws {
        let fixture = try fixture(.archive)
        try fixture.journal.persist(fixture.manifest)
        var failingJournal = fixture.journal
        failingJournal.fileSystem = RemovalAuditSyncFailureFileSystem()
        var changed = fixture.manifest
        changed.phase = .metadataCommitted
        XCTAssertThrowsError(try failingJournal.persist(changed))
        XCTAssertEqual(try fixture.journal.loadManifest(transactionID: fixture.transactionID).phase, .prepared)
        XCTAssertThrowsError(try failingJournal.recordCompletion(fixture.manifest, completion: .committed, archiveURLs: [:]))
        XCTAssertEqual(try fixture.journal.pendingTransactions(), [fixture.transactionID])
        XCTAssertNil(try fixture.journal.completedOutcome(transactionID: fixture.transactionID))
    }

    func testLegacyCommittedJournalResumesAfterOwnerMarkerWasRemoved() throws {
        for choice in [ApplicationRemovalDataChoice.archive, .delete] {
            let fixture = try fixture(choice)
            try fixture.interrupt(after: .commitMetadata)
            var legacy = fixture.manifest
            legacy.phase = .metadataCommitted
            try fixture.journal.persist(legacy)
            let entry = legacy.entries[0]
            let directory = URL(fileURLWithPath: choice == .archive ? entry.archivePath : entry.stagedPath)
            try FileManager.default.removeItem(at: directory.appendingPathComponent(
                ApplicationRemovalTransactionPaths.ownerMarkerName(fixture.transactionID)))
            XCTAssertEqual(try fixture.recover().completion, .committed)
            XCTAssertTrue(try fixture.journal.pendingTransactions().isEmpty)
        }
    }

    private func fixture(_ choice: ApplicationRemovalDataChoice, createData: Bool = true) throws -> RemovalAuditFixture {
        try RemovalAuditFixture(root: root.appendingPathComponent(UUID().uuidString), choice: choice, createData: createData)
    }
}

private enum RemovalAuditError: Error { case injected }

private final class RemovalAuditCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() -> Int { lock.withLock { count += 1; return count } }
}

private struct RemovalAuditRepository: LibraryRepositoryPersisting {
    let base: LibraryRepository
    let beforeLock: @Sendable () throws -> Void
    var persistence: any LibraryRepositoryPersistence { base.persistence }
    func load() -> LibraryRepositoryLoadOutcome { base.load() }
    func prepare(_ applications: [ManagedApplication], expectedVersion: LibraryVersionToken) throws -> PreparedLibraryCommit {
        try base.prepare(applications, expectedVersion: expectedVersion)
    }
    func tryWithExclusiveAccess<T>(_ body: (LibraryExclusiveAccess) throws -> T) throws -> LibraryExclusiveAccessResult<T> {
        try base.tryWithExclusiveAccess(body)
    }
    func withExclusiveMutation<T>(expectedVersion: LibraryVersionToken, _ body: (LibraryMutationCommitCapability) throws -> T) throws -> T {
        try beforeLock()
        return try base.withExclusiveMutation(expectedVersion: expectedVersion, body)
    }
    func save(_ applications: [ManagedApplication], expectedVersion: LibraryVersionToken, backupReason: LibraryBackupReason?) throws -> LibraryRepositorySnapshot {
        try base.save(applications, expectedVersion: expectedVersion, backupReason: backupReason)
    }
}

struct RemovalAuditFixture: Sendable {
    let root: URL
    let base: URL
    let application: ManagedApplication
    let sources: [URL]
    let repository: LibraryRepository
    let request: ApplicationRemovalTransactionRequest
    let commit: PreparedLibraryCommit
    let transactionID: UUID

    var journal: ApplicationRemovalTransactionJournal {
        ApplicationRemovalTransactionJournal(rootURL: root.appendingPathComponent("Parallax/ApplicationRemovalTransactions"))
    }
    let manifest: ApplicationRemovalTransactionManifest

    init(root: URL, choice: ApplicationRemovalDataChoice, createData: Bool, base: URL? = nil) throws {
        self.root = root
        let base = base ?? root.appendingPathComponent("Managed", isDirectory: true)
        self.base = base
        let profiles = [LaunchProfile(name: "First"), LaunchProfile(name: "Second")]
        let application = ManagedApplication(displayName: "Fixture", appPath: "/Applications/Fixture.app", baseStoragePath: base.path, profiles: profiles)
        self.application = application
        let sources = profiles.map {
            base.appendingPathComponent(".parallax/Applications/\(application.storageID.uuidString.lowercased())/Profiles/\($0.storageID.uuidString.lowercased())", isDirectory: true)
        }
        self.sources = sources
        if createData {
            for (index, source) in sources.enumerated() {
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
                try Data("payload \(index)".utf8).write(to: source.appendingPathComponent("payload.txt"))
            }
        }
        repository = LibraryRepository(applicationSupportURL: root)
        let snapshot = try repository.save([application], expectedVersion: .missing)
        let targets = try zip(profiles, sources).map { profile, source in
            ApplicationRemovalProfileTarget(profileID: profile.id, profileStorageID: profile.storageID, profileName: profile.name,
                managedProfileRoot: DestructiveActionPathSnapshot(canonicalURL: source,
                    fileIdentity: createData ? try LocalFileSystem().attributesOfItem(at: source).identity : nil), externalPaths: [])
        }
        let removal = try ApplicationRemovalRequest(requestID: UUID(), sceneID: UUID(), applicationID: application.id,
            applicationStorageID: application.storageID, applicationName: application.displayName, profiles: targets,
            dataChoice: choice, repositoryVersion: snapshot.versionToken)
        let backup = LibraryRecoveryArtifact(id: UUID(), kind: .backup, reason: .destructiveRewrite, content: .currentLibrary,
            createdAt: Date(timeIntervalSince1970: 1), libraryURL: root.appendingPathComponent("backup.json"),
            byteCount: snapshot.originalBytes.count, sha256: try XCTUnwrap(snapshot.versionToken.primarySHA256))
        let execution = try removal.authorizeExecution(
            currentTarget: ApplicationRemovalCurrentTarget(applicationID: application.id, applicationStorageID: application.storageID,
                applicationName: application.displayName, profiles: targets, repositoryVersion: snapshot.versionToken),
            activity: ApplicationRemovalActivitySnapshot(profiles: targets.map {
                ApplicationRemovalProfileActivity(applicationID: application.id, applicationStorageID: application.storageID,
                    profileID: $0.profileID, profileStorageID: $0.profileStorageID, state: .inactive)
            }), priorBackup: removal.acceptPriorBackup(backup))
        let transactionID = UUID()
        self.transactionID = transactionID
        request = ApplicationRemovalTransactionRequest(transactionID: transactionID, executionAuthorization: execution, profiles: targets)
        commit = try repository.prepare([], expectedVersion: snapshot.versionToken)
        let staging = base.appendingPathComponent(".parallax/ApplicationRemovalTransactions/\(transactionID.uuidString.lowercased())")
        manifest = ApplicationRemovalTransactionManifest(transactionID: transactionID, applicationID: application.id,
            applicationStorageID: application.storageID, dataChoice: choice,
            priorRevision: snapshot.versionToken.revision.rawValue, priorSHA256: snapshot.versionToken.primarySHA256,
            targetRevision: commit.targetVersion.revision.rawValue, targetSHA256: commit.targetVersion.primarySHA256,
            stagingRootPath: staging.path, phase: .prepared,
            entries: targets.map { target in
                ApplicationRemovalTransactionEntry(profileID: target.profileID, profileStorageID: target.profileStorageID,
                    baseRootPath: base.path, sourcePath: target.managedProfileRoot.canonicalPath,
                    stagedPath: staging.appendingPathComponent(target.profileStorageID.uuidString.lowercased()).path,
                    archivePath: base.appendingPathComponent(".parallax/Archives/\(application.storageID.uuidString.lowercased())/\(target.profileStorageID.uuidString.lowercased())/100000-\(transactionID.uuidString.lowercased())").path,
                    expectedDevice: target.managedProfileRoot.fileIdentity?.volumeID,
                    expectedInode: target.managedProfileRoot.fileIdentity?.fileID, sourceExisted: createData && choice != .keep)
            })
    }

    func coordinator(_ boundary: (@Sendable (ApplicationRemovalTransactionBoundary) throws -> Void)? = nil) throws -> ApplicationRemovalTransactionCoordinator {
        try ApplicationRemovalTransactionCoordinator(applicationSupportURL: root, now: { Date(timeIntervalSince1970: 100) }, transactionBoundary: boundary)
    }
    func execute(_ coordinator: ApplicationRemovalTransactionCoordinator) throws -> ApplicationRemovalTransactionOutcome {
        try coordinator.execute(request, preparedCommit: commit, repository: repository)
    }
    func interrupt(after effect: ApplicationRemovalTransactionEffect) throws {
        let coordinator = try coordinator { boundary in
            if boundary == .afterEffectBeforeRecord(effect) { throw ApplicationRemovalTransactionInterruption.simulatedCrash }
        }
        XCTAssertThrowsError(try execute(coordinator))
    }
    func recover() throws -> ApplicationRemovalTransactionOutcome {
        switch try repository.tryWithExclusiveAccess({ access in
            try coordinator().recover(transactionID: transactionID, repository: repository, access: access)
        }) {
        case .acquired(let outcome): return outcome
        case .busy: throw RemovalAuditError.injected
        }
    }
}

private struct RemovalAuditSyncFailureFileSystem: FileSystem {
    let base = LocalFileSystem()
    func fileExists(at url: URL) -> Bool { base.fileExists(at: url) }
    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes { try base.attributesOfItem(at: url) }
    func canonicalURL(for url: URL) throws -> URL { try base.canonicalURL(for: url) }
    func createDirectory(at url: URL, withIntermediateDirectories flag: Bool) throws { try base.createDirectory(at: url, withIntermediateDirectories: flag) }
    func copyItem(at source: URL, to destination: URL) throws { try base.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) throws { try base.moveItem(at: source, to: destination) }
    func removeItem(at url: URL) throws { try base.removeItem(at: url) }
    func contentsOfDirectory(at url: URL) throws -> [URL] { try base.contentsOfDirectory(at: url) }
    func readData(at url: URL) throws -> Data { try base.readData(at: url) }
    func writeData(_ data: Data, to url: URL) throws { try base.writeData(data, to: url) }
    func writeDataAtomically(_ data: Data, to url: URL) throws { try base.writeDataAtomically(data, to: url) }
    func replaceItem(at destination: URL, withItemAt source: URL) throws { try base.replaceItem(at: destination, withItemAt: source) }
    func synchronize(at url: URL) throws {
        if url.pathExtension == "tmp" { throw RemovalAuditError.injected }
        try base.synchronize(at: url)
    }
    func applicationSupportURL(create: Bool) throws -> URL { throw RemovalAuditError.injected }
}

final class ApplicationRemovalCompletionAuditRegressionTests: XCTestCase {
    func testDuplicateCompletionArchiveIdentifiersFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RemovalCompletionAudit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transactionID = UUID()
        let record = ApplicationRemovalTransactionCompletedRecord(transactionID: transactionID,
            completion: .committed, dataChoice: .archive, archivePaths: [
                "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE": "/tmp/one",
                "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee": "/tmp/two",
            ])
        let url = root.appendingPathComponent("\(transactionID.uuidString.lowercased()).completed.json")
        try JSONEncoder().encode(record).write(to: url)
        let journal = ApplicationRemovalTransactionJournal(rootURL: root)
        XCTAssertThrowsError(try journal.completedOutcome(transactionID: transactionID))
    }
}
