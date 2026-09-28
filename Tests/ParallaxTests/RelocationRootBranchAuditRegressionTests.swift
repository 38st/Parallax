import Foundation
import XCTest
@testable import Parallax

final class RelocationRootBranchAuditRegressionTests: XCTestCase {
    func testTargetWithReplacedDestinationRemainsPending() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try f.publishCopy(preview)
        _ = try f.repository.save([preview.relocatedApplication], expectedVersion: f.version)
        try FileManager.default.moveItem(at: f.destination, to: f.root.appendingPathComponent("OriginalDestination"))
        try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: true)
        try f.publishCopy(preview)
        XCTAssertThrowsError(try f.recover(preview))
        XCTAssertEqual(try f.coordinator.pendingRelocations().count, 1)
        XCTAssertTrue(f.exists(preview.source.applicationRoot.url))
        XCTAssertTrue(f.exists(preview.destination.applicationRoot.url))
    }

    func testPriorWithReplacedEmptyDestinationCompletesRollback() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try FileManager.default.moveItem(at: f.destination, to: f.root.appendingPathComponent("OriginalDestination"))
        try FileManager.default.createDirectory(at: f.destination, withIntermediateDirectories: true)
        XCTAssertEqual(try f.recover(preview), .rolledBack)
        XCTAssertTrue(f.exists(preview.source.applicationRoot.url))
    }

    func testPriorWithMissingSourceAndPublishedCopyRemainsPending() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try f.publishCopy(preview)
        try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("UnmountedSource"))
        XCTAssertThrowsError(try f.recover(preview))
        XCTAssertEqual(try f.coordinator.pendingRelocations().count, 1)
        XCTAssertTrue(f.exists(preview.destination.applicationRoot.url))
    }

    func testPriorWithReplacedSourceAndPublishedCopyRemainsPending() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        try f.publishCopy(preview)
        try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("OriginalSource"))
        try FileManager.default.createDirectory(at: f.source, withIntermediateDirectories: true)
        XCTAssertThrowsError(try f.recover(preview))
        XCTAssertEqual(try f.coordinator.pendingRelocations().count, 1)
        XCTAssertTrue(f.exists(preview.destination.applicationRoot.url))
    }

    func testPriorWithMissingSourceAndOnlyStagingCleansStaging() throws {
        let f = try RelocationAuditFixture()
        defer { f.remove() }
        let preview = try f.preview()
        try f.publishPlan(preview)
        let staging = preview.destination.stagingRoot(transactionID: preview.requestID).url
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: f.source, to: f.root.appendingPathComponent("UnmountedSource"))
        XCTAssertEqual(try f.recover(preview), .rolledBack)
        XCTAssertFalse(f.exists(staging))
    }
}
