import Foundation
import XCTest
@testable import Parallax

final class IntegrationImportRecoveryAuditRegressionTests: XCTestCase {
    func testBackupPublicationTimeoutDoesNotRecoverPeerWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = LibraryRepository(applicationSupportURL: root, backupHook: { _, _ in })
        let app = ManagedApplication(displayName: "Original", appPath: "/synthetic.app", baseStoragePath: root.path, profiles: [])
        let initial = try repository.save([app], expectedVersion: .missing)
        let prepared = try repository.prepare([], expectedVersion: initial.versionToken)
        let evidence = LibraryImportReplacementEvidence(id: UUID(), applicationCount: 0, profileCount: 0,
            validationWarnings: [], expectedVersion: initial.versionToken, priorApplications: initial.applications,
            priorLibraryBytes: initial.originalBytes, preparedCommit: prepared, integritySHA256: "fixture")
        var peer = app
        peer.displayName = "Peer saved"
        let snapshot = try repository.save([peer], expectedVersion: initial.versionToken)
        XCTAssertNoThrow(try LibraryImportReplacementRecovery(repository: repository).recoverFailedReplacementIfNeeded(
            evidence: evidence, originalError: LibraryBackupStoreError.publicationBusy))
        guard case .loaded(let current) = repository.load() else { return XCTFail() }
        XCTAssertEqual(current.versionToken, snapshot.versionToken)
        XCTAssertEqual(current.applications, [peer])
    }
}
