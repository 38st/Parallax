import Foundation
import XCTest
@testable import Parallax

final class ApplicationRemovalDowngradeAuditRegressionTests: XCTestCase {
    func testUnpluggedCustomRootDoesNotBecomeNoDataRemoval() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RemovalEnrollment-\(UUID())")
        defer { try? removeTestDirectory(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let f = try RemovalAuditFixture(root: root, choice: .delete, createData: false)
        let enrollment = try StorageVolumeEnrollmentStore(applicationSupportURL: root)
        try enrollment.recordVerifiedRoot(applicationStorageID: f.application.storageID, baseRoot: f.base,
            volumeUUID: "00000000-0000-0000-0000-000000000099")
        XCTAssertThrowsError(try f.execute(f.coordinator())) {
            XCTAssertEqual(($0 as? ApplicationRemovalTransactionError)?.code, .storageUnavailable)
        }
        guard case .loaded(let snapshot) = f.repository.load() else { return XCTFail("Library unavailable") }
        XCTAssertEqual(snapshot.applications, [f.application])
        XCTAssertTrue(try f.journal.pendingTransactions().isEmpty)
    }

    private enum PreviousPhase: String, Decodable { case prepared, metadataCommitted }

    func testNewRemovalPhasesFailClosedInPreviousDecoder() throws {
        for phase in [ApplicationRemovalTransactionPhase.prepared, .metadataCommitted] {
            let bytes = try JSONEncoder().encode(phase)
            XCTAssertThrowsError(try JSONDecoder().decode(PreviousPhase.self, from: bytes))
            XCTAssertEqual(try JSONDecoder().decode(ApplicationRemovalTransactionPhase.self, from: bytes), phase)
            XCTAssertEqual(String(data: bytes, encoding: .utf8), "\"" + phase.rawValue + "-v2\"")
        }
    }

    func testPreviousRemovalPhasesStillDecode() throws {
        for phase in [ApplicationRemovalTransactionPhase.prepared, .metadataCommitted] {
            let bytes = try JSONEncoder().encode(phase.rawValue)
            XCTAssertEqual(try JSONDecoder().decode(ApplicationRemovalTransactionPhase.self, from: bytes), phase)
        }
    }
}
