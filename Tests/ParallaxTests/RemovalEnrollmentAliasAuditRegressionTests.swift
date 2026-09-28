import Foundation
import XCTest
@testable import Parallax

final class RemovalEnrollmentAliasAuditRegressionTests: XCTestCase {
    func testMissingCanonicalRootUsesConfiguredEnrollmentKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RemovalAlias-\(UUID())")
        defer { try? removeTestDirectory(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let canonical = root.appendingPathComponent("missing-volume")
        let alias = root.appendingPathComponent("configured-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: canonical)
        let f = try RemovalAuditFixture(root: root, choice: .delete, createData: false, base: alias)
        let enrollment = try StorageVolumeEnrollmentStore(applicationSupportURL: root)
        try enrollment.recordVerifiedRoot(applicationStorageID: f.application.storageID, baseRoot: alias,
            volumeUUID: "00000000-0000-0000-0000-000000000099")
        let targets = f.request.profiles.map { profile in
            let canonicalProfile = ManagedPathResolver.profileRootURL(baseRootURL: canonical,
                applicationStorageID: f.application.storageID, profileStorageID: profile.profileStorageID)
            return ApplicationRemovalProfileTarget(profileID: profile.profileID, profileStorageID: profile.profileStorageID,
                profileName: profile.profileName, managedProfileRoot: DestructiveActionPathSnapshot(canonicalURL: canonicalProfile,
                    fileIdentity: nil), externalPaths: [])
        }
        let request = ApplicationRemovalTransactionRequest(transactionID: f.transactionID,
            executionAuthorization: f.request.executionAuthorization, profiles: targets)
        XCTAssertThrowsError(try f.coordinator().execute(request, preparedCommit: f.commit, repository: f.repository)) {
            XCTAssertEqual(($0 as? ApplicationRemovalTransactionError)?.code, .storageUnavailable)
        }
        guard case .loaded(let snapshot) = f.repository.load() else { return XCTFail("Library unavailable") }
        XCTAssertEqual(snapshot.applications, [f.application])
    }
}
