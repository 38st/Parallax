import Foundation
import XCTest
@testable import Parallax

final class LibraryBackupStoreTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory
    private var recoveryRoot = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Parallax-PERS-002-\(UUID().uuidString)", isDirectory: true)
        recoveryRoot = temporaryDirectory
            .appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testBackupPreservesExactBytesHashAndRestrictivePermissions() throws {
        let bytes = try currentLibraryBytes(marker: "synthetic-secret")
        let store = makeStore()

        let artifact = try store.createBackup(
            of: bytes,
            reason: .destructiveRewrite
        )

        XCTAssertEqual(artifact.kind, .backup)
        XCTAssertEqual(artifact.byteCount, bytes.count)
        XCTAssertEqual(artifact.sha256, LibraryPersistence.sha256(bytes))
        XCTAssertEqual(try Data(contentsOf: artifact.libraryURL), bytes)
        XCTAssertEqual(
            try permissions(at: artifact.libraryURL),
            0o600
        )
        XCTAssertEqual(
            try permissions(at: artifact.libraryURL.deletingLastPathComponent()),
            0o700
        )
        XCTAssertEqual(
            try permissions(
                at: artifact.libraryURL
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
            ),
            0o700
        )

        let manifest = try Data(
            contentsOf: artifact.libraryURL
                .deletingLastPathComponent()
                .appendingPathComponent("metadata.json")
        )
        XCTAssertFalse(
            String(decoding: manifest, as: UTF8.self)
                .contains("synthetic-secret")
        )
    }

    func testBackupRetentionKeepsNewestBoundedSet() throws {
        var instant = Date(timeIntervalSince1970: 1_000)
        var identifierIndex = 0
        let identifiers = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        ]
        let store = LibraryBackupStore(
            recoveryRoot: recoveryRoot,
            retentionLimit: 2,
            now: {
                defer { instant.addTimeInterval(1) }
                return instant
            },
            makeIdentifier: {
                defer { identifierIndex += 1 }
                return identifiers[identifierIndex]
            }
        )

        let first = try store.createBackup(
            of: currentLibraryBytes(marker: "one"),
            reason: .migration
        )
        let second = try store.createBackup(
            of: currentLibraryBytes(marker: "two"),
            reason: .importReplacement
        )
        let third = try store.createBackup(
            of: currentLibraryBytes(marker: "three"),
            reason: .destructiveRewrite
        )

        let inspections = try store.inspectArtifacts(kind: .backup)
        XCTAssertEqual(inspections.map(\.artifact.id), [third.id, second.id])
        XCTAssertTrue(inspections.allSatisfy(\.isVerified))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: first.libraryURL.deletingLastPathComponent().path
            )
        )
    }

    func testQuarantineCopiesTimestampedExactBytesWithoutDeletingPrimary() throws {
        let primary = temporaryDirectory.appendingPathComponent("library.json")
        let bytes = Data(#"{"broken":"synthetic"}"#.utf8)
        try bytes.write(to: primary)
        let timestamp = Date(timeIntervalSince1970: 1_725_000_123)
        let store = LibraryBackupStore(
            recoveryRoot: recoveryRoot,
            now: { timestamp },
            makeIdentifier: {
                UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            }
        )

        let artifact = try store.quarantineFile(at: primary)

        XCTAssertEqual(artifact.kind, .quarantine)
        XCTAssertEqual(artifact.createdAt, timestamp)
        XCTAssertTrue(
            artifact.libraryURL
                .deletingLastPathComponent()
                .lastPathComponent
                .hasPrefix("1725000123000-")
        )
        XCTAssertEqual(try Data(contentsOf: artifact.libraryURL), bytes)
        XCTAssertEqual(try Data(contentsOf: primary), bytes)
    }

    func testRestorePreparationRejectsTamperedBackup() throws {
        let store = makeStore()
        let artifact = try store.createBackup(
            of: currentLibraryBytes(marker: "known-good"),
            reason: .importReplacement
        )
        try Data("tampered".utf8).write(to: artifact.libraryURL)

        XCTAssertThrowsError(try store.prepareRestore(from: artifact)) { error in
            XCTAssertEqual(error as? LibraryBackupStoreError, .hashMismatch)
        }
        let inspection = try XCTUnwrap(
            store.inspectArtifacts(kind: .backup).first
        )
        XCTAssertFalse(inspection.isVerified)
        XCTAssertEqual(inspection.problem, .hashMismatch)
    }

    func testRestoreRevalidatesSupportedCurrentSchemaEvenWhenManifestHashMatches() throws {
        let store = makeStore()
        let artifact = try store.createBackup(
            of: currentLibraryBytes(marker: "original"),
            reason: .manual
        )
        let unsupported = Data(
            #"{"version":999,"revision":0,"applications":[]}"#.utf8
        )
        try unsupported.write(to: artifact.libraryURL)
        let metadataURL = artifact.libraryURL
            .deletingLastPathComponent()
            .appendingPathComponent("metadata.json")
        var metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: metadataURL)
            ) as? [String: Any]
        )
        metadata["byteCount"] = unsupported.count
        metadata["sha256"] = LibraryPersistence.sha256(unsupported)
        try JSONSerialization.data(
            withJSONObject: metadata,
            options: [.sortedKeys]
        ).write(to: metadataURL)

        let inspection = try XCTUnwrap(
            store.inspectArtifacts(kind: .backup).first
        )
        XCTAssertFalse(inspection.isRestorable)
        XCTAssertEqual(inspection.problem, .invalidLibrary)
        XCTAssertThrowsError(try store.prepareRestore(from: artifact)) { error in
            XCTAssertEqual(error as? LibraryBackupStoreError, .invalidLibrary)
        }
    }

    func testLatestRestoreSkipsCorruptNewestBackup() throws {
        var instant = Date(timeIntervalSince1970: 2_000)
        let store = LibraryBackupStore(
            recoveryRoot: recoveryRoot,
            retentionLimit: 3,
            now: {
                defer { instant.addTimeInterval(1) }
                return instant
            }
        )
        let goodBytes = try currentLibraryBytes(marker: "known-good")
        let good = try store.createBackup(of: goodBytes, reason: .migration)
        let corrupt = try store.createBackup(
            of: currentLibraryBytes(marker: "newer"),
            reason: .destructiveRewrite
        )
        try Data("changed".utf8).write(to: corrupt.libraryURL)

        let preparation = try store.prepareLatestBackupRestore()

        XCTAssertEqual(preparation.artifact.id, good.id)
        XCTAssertEqual(preparation.bytes, goodBytes)
    }

    func testExportRequiresVerificationAndPublishesExactBytes() throws {
        let store = makeStore()
        let bytes = try currentLibraryBytes(
            marker: "portable-library-metadata"
        )
        let artifact = try store.createBackup(of: bytes, reason: .manual)
        let exportParent = temporaryDirectory.appendingPathComponent("Export")
        try FileManager.default.createDirectory(
            at: exportParent,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: exportParent.path
        )
        let exportURL = exportParent.appendingPathComponent("library.json")

        let exported = try store.export(artifact, to: exportURL)

        XCTAssertEqual(exported, exportURL)
        XCTAssertEqual(try Data(contentsOf: exportURL), bytes)
        XCTAssertEqual(try permissions(at: exportURL), 0o600)
        XCTAssertEqual(try permissions(at: exportParent), 0o755)
    }

    func testAtomicPublicationFailureLeavesNoVisibleArtifactOrStagingData() throws {
        let fileSystem = BackupMoveFailingFileSystem()
        let store = LibraryBackupStore(
            fileSystem: fileSystem,
            recoveryRoot: recoveryRoot
        )

        XCTAssertThrowsError(
            try store.createBackup(
                of: currentLibraryBytes(marker: "not-published"),
                reason: .migration
            )
        )

        let backupRoot = recoveryRoot.appendingPathComponent("Backups")
        if FileManager.default.fileExists(atPath: backupRoot.path) {
            XCTAssertTrue(
                try FileManager.default.contentsOfDirectory(
                    at: backupRoot,
                    includingPropertiesForKeys: nil
                ).isEmpty
            )
        }
    }

    func testInspectionDoesNotExposeLibraryContents() throws {
        let store = makeStore()
        let secret = "synthetic-sensitive-value"
        _ = try store.createBackup(
            of: currentLibraryBytes(marker: secret),
            reason: .manual
        )

        let inspection = try XCTUnwrap(
            store.inspectArtifacts(kind: .backup).first
        )

        XCTAssertTrue(inspection.isVerified)
        XCTAssertFalse(String(describing: inspection).contains(secret))
    }

    func testUnexpectedBundleContentsInvalidateRestoreAndAreNeverPruned() throws {
        let store = LibraryBackupStore(
            recoveryRoot: recoveryRoot,
            retentionLimit: 1
        )
        let first = try store.createBackup(
            of: currentLibraryBytes(marker: "first"),
            reason: .manual
        )
        let unexpected = first.libraryURL
            .deletingLastPathComponent()
            .appendingPathComponent("unexpected")
        try Data("preserve".utf8).write(to: unexpected)

        XCTAssertThrowsError(try store.prepareRestore(from: first)) { error in
            XCTAssertEqual(error as? LibraryBackupStoreError, .invalidMetadata)
        }
        _ = try store.createBackup(
            of: currentLibraryBytes(marker: "second"),
            reason: .manual
        )

        XCTAssertEqual(try Data(contentsOf: unexpected), Data("preserve".utf8))
    }

    func testCorruptUnsupportedAndLegacyBytesAreNotLastKnownGoodBackups() throws {
        let store = makeStore()
        let corrupt = Data(#"{"version":2,"applications":["#.utf8)
        let unsupported = Data(
            #"{"version":999,"revision":0,"applications":[]}"#.utf8
        )
        let legacy = try fixture(named: "valid-v1-library.json")

        for bytes in [corrupt, unsupported, legacy] {
            XCTAssertThrowsError(
                try store.createBackup(of: bytes, reason: .manual)
            ) { error in
                XCTAssertEqual(
                    error as? LibraryBackupStoreError,
                    .invalidLibrary
                )
            }
        }
        XCTAssertTrue(try store.inspectArtifacts(kind: .backup).isEmpty)
    }

    func testMigrationReasonPreservesExactLegacyBytesButDoesNotMakeThemRestorable() throws {
        let store = makeStore()
        let legacy = try fixture(named: "valid-v1-library.json")

        let artifact = try store.createBackup(
            of: legacy,
            reason: .migration
        )

        XCTAssertEqual(artifact.content, .legacyMigrationSource)
        XCTAssertEqual(try Data(contentsOf: artifact.libraryURL), legacy)
        let inspection = try XCTUnwrap(
            store.inspectArtifacts(kind: .backup).first
        )
        XCTAssertTrue(inspection.isVerified)
        XCTAssertFalse(inspection.isRestorable)
        XCTAssertThrowsError(
            try store.prepareRestore(from: artifact)
        ) { error in
            XCTAssertEqual(
                error as? LibraryBackupStoreError,
                .notRestorable
            )
        }
    }

    func testBackupCurrentPrimaryCapturesExactValidatedBytes() throws {
        let store = makeStore()
        let primary = temporaryDirectory.appendingPathComponent("library.json")
        let bytes = try currentLibraryBytes(marker: "before-save")
        try bytes.write(to: primary)

        let artifact = try store.backupCurrentPrimary(
            at: primary,
            reason: .destructiveRewrite
        )

        XCTAssertEqual(artifact.content, .currentLibrary)
        XCTAssertEqual(artifact.sha256, LibraryPersistence.sha256(bytes))
        XCTAssertEqual(try Data(contentsOf: artifact.libraryURL), bytes)
        XCTAssertEqual(try Data(contentsOf: primary), bytes)
    }

    func testBackupCurrentPrimaryRejectsSameLengthMutationDuringSnapshot() throws {
        let primary = temporaryDirectory.appendingPathComponent("library.json")
        let original = try currentLibraryBytes(marker: "before")
        let changed = try currentLibraryBytes(marker: "change")
        XCTAssertEqual(original.count, changed.count)
        try original.write(to: primary)
        let fileSystem = BackupMoveFailingFileSystem(
            failPublication: false,
            mutateAfterFirstReadAt: primary,
            mutation: changed
        )
        let store = LibraryBackupStore(
            fileSystem: fileSystem,
            recoveryRoot: recoveryRoot
        )

        XCTAssertThrowsError(
            try store.backupCurrentPrimary(
                at: primary,
                reason: .destructiveRewrite
            )
        ) { error in
            XCTAssertEqual(
                error as? LibraryBackupStoreError,
                .invalidArtifact
            )
        }
        XCTAssertTrue(try store.inspectArtifacts(kind: .backup).isEmpty)
    }

    func testPreparePrimaryRestorePreservesCurrentPrimaryAndNeverOverwritesIt() throws {
        let store = makeStore()
        let restoreBytes = try currentLibraryBytes(marker: "restore")
        let artifact = try store.createBackup(
            of: restoreBytes,
            reason: .manual
        )
        let primary = temporaryDirectory.appendingPathComponent("library.json")
        let primaryBytes = try currentLibraryBytes(marker: "current")
        try primaryBytes.write(to: primary)

        let preparation = try store.preparePrimaryRestore(
            from: artifact,
            replacing: primary
        )

        XCTAssertEqual(preparation.restore.bytes, restoreBytes)
        XCTAssertEqual(
            preparation.preservedPrimary?.kind,
            .backup
        )
        XCTAssertEqual(
            try preparation.preservedPrimary.map {
                try Data(contentsOf: $0.libraryURL)
            },
            primaryBytes
        )
        XCTAssertEqual(try Data(contentsOf: primary), primaryBytes)
    }

    func testPreparePrimaryRestoreQuarantinesInvalidPrimaryWithoutOverwritingIt() throws {
        let store = makeStore()
        let artifact = try store.createBackup(
            of: currentLibraryBytes(marker: "restore"),
            reason: .manual
        )
        let primary = temporaryDirectory.appendingPathComponent("library.json")
        let corrupt = Data(#"{"version":2,"broken":"#.utf8)
        try corrupt.write(to: primary)

        let preparation = try store.preparePrimaryRestore(
            from: artifact,
            replacing: primary
        )

        let preserved = try XCTUnwrap(preparation.preservedPrimary)
        XCTAssertEqual(preserved.kind, .quarantine)
        XCTAssertEqual(try Data(contentsOf: preserved.libraryURL), corrupt)
        XCTAssertEqual(try Data(contentsOf: primary), corrupt)
    }

    func testPrepareQuarantineAndStartOverPreservesExactPrimaryAndReturnsValidEmptyV2() throws {
        let store = makeStore()
        let primary = temporaryDirectory.appendingPathComponent("library.json")
        let corrupt = Data(#"{"version":2,"truncated":"#.utf8)
        try corrupt.write(to: primary)

        let preparation = try store.prepareQuarantineAndStartOver(
            primaryAt: primary
        )

        XCTAssertEqual(preparation.originalSHA256, LibraryPersistence.sha256(corrupt))
        XCTAssertEqual(
            try Data(contentsOf: preparation.quarantine.libraryURL),
            corrupt
        )
        XCTAssertEqual(try Data(contentsOf: primary), corrupt)
        let replacement = try LibraryPersistence.decodeCurrentDocument(
            from: preparation.emptyLibraryBytes
        )
        XCTAssertEqual(replacement.revision, .initial)
        XCTAssertTrue(replacement.applications.isEmpty)
    }

    private func makeStore() -> LibraryBackupStore {
        LibraryBackupStore(recoveryRoot: recoveryRoot)
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(
            (attributes[.posixPermissions] as? NSNumber)?.intValue
        )
    }

    private func currentLibraryBytes(marker: String) throws -> Data {
        let profile = LaunchProfile(
            name: "Profile",
            notes: marker
        )
        let application = ManagedApplication(
            displayName: "Fixture \(marker)",
            appPath: "/Applications/Fixture.app",
            profiles: [profile]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(
            LibraryDocument(
                revision: LibraryRevision(rawValue: 7),
                applications: [application]
            )
        )
    }

    private func fixture(named fileName: String) throws -> Data {
        try XCTUnwrap(
            LibraryFixtureCase.matrix.first { $0.fileName == fileName }
        ).data()
    }
}

private final class BackupMoveFailingFileSystem: FileSystem, @unchecked Sendable {
    private let underlying = LocalFileSystem()
    private let failPublication: Bool
    private let mutateAfterFirstReadAt: URL?
    private let mutation: Data?
    private var hasFailedPublication = false
    private var hasMutatedRead = false

    init(
        failPublication: Bool = true,
        mutateAfterFirstReadAt: URL? = nil,
        mutation: Data? = nil
    ) {
        self.failPublication = failPublication
        self.mutateAfterFirstReadAt = mutateAfterFirstReadAt
        self.mutation = mutation
    }

    func fileExists(at url: URL) -> Bool {
        underlying.fileExists(at: url)
    }

    func attributesOfItem(at url: URL) throws -> FileSystemItemAttributes {
        try underlying.attributesOfItem(at: url)
    }

    func canonicalURL(for url: URL) throws -> URL {
        try underlying.canonicalURL(for: url)
    }

    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try underlying.createDirectory(
            at: url,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    func copyItem(at sourceURL: URL, to destinationURL: URL) throws {
        try underlying.copyItem(at: sourceURL, to: destinationURL)
    }

    func moveItem(at sourceURL: URL, to destinationURL: URL) throws {
        if sourceURL.lastPathComponent.hasPrefix(".staging-"),
           failPublication,
           !hasFailedPublication
        {
            hasFailedPublication = true
            throw CocoaError(.fileWriteNoPermission)
        }
        try underlying.moveItem(at: sourceURL, to: destinationURL)
    }

    func removeItem(at url: URL) throws {
        try underlying.removeItem(at: url)
    }

    func contentsOfDirectory(at url: URL) throws -> [URL] {
        try underlying.contentsOfDirectory(at: url)
    }

    func readData(at url: URL) throws -> Data {
        let data = try underlying.readData(at: url)
        if url.standardizedFileURL == mutateAfterFirstReadAt?.standardizedFileURL,
           !hasMutatedRead,
           let mutation
        {
            hasMutatedRead = true
            try mutation.write(to: url)
        }
        return data
    }

    func writeData(_ data: Data, to url: URL) throws {
        try underlying.writeData(data, to: url)
    }

    func writeDataAtomically(_ data: Data, to url: URL) throws {
        try underlying.writeDataAtomically(data, to: url)
    }

    func replaceItem(at destinationURL: URL, withItemAt sourceURL: URL) throws {
        try underlying.replaceItem(at: destinationURL, withItemAt: sourceURL)
    }

    func setPOSIXPermissions(_ permissions: Int, at url: URL) throws {
        try underlying.setPOSIXPermissions(permissions, at: url)
    }

    func destinationOfSymbolicLink(at url: URL) throws -> String {
        try underlying.destinationOfSymbolicLink(at: url)
    }

    func synchronize(at url: URL) throws {
        try underlying.synchronize(at: url)
    }

    func applicationSupportURL(create: Bool) throws -> URL {
        try underlying.applicationSupportURL(create: create)
    }
}
