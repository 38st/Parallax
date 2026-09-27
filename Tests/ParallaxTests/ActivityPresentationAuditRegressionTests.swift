import Foundation
import XCTest

@testable import Parallax

final class ActivityPresentationAuditRegressionTests: XCTestCase {
    func testDurableAmbiguityMessageUsesARealPlural() {
        XCTAssertEqual(
            LibraryStoreInfrastructureError.ambiguousDurableActivity(1).localizedDescription,
            "1 durable launch activity record could not be reconciled safely.")
        XCTAssertEqual(
            LibraryStoreInfrastructureError.ambiguousDurableActivity(2).localizedDescription,
            "2 durable launch activity records could not be reconciled safely.")
    }

    func testSupportBundleIsPrivateBeforePublicationAndFailurePreservesDestination() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent("support.json")
        let prior = Data("prior".utf8)
        try prior.write(to: destination)
        XCTAssertThrowsError(
            try SanitizedSupportBundleWriter.write(Data("new".utf8), to: destination) { staged in
                let mode = try XCTUnwrap(
                    FileManager.default.attributesOfItem(atPath: staged.path)[.posixPermissions]
                        as? NSNumber)
                XCTAssertEqual(mode.intValue & 0o777, 0o600)
                throw SupportWriteInterruption.interrupted
            })
        XCTAssertEqual(try Data(contentsOf: destination), prior)
    }
}

private enum SupportWriteInterruption: Error { case interrupted }
