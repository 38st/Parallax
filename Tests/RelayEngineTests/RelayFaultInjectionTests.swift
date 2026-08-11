import Foundation
import XCTest

final class RelayFaultInjectionTests: XCTestCase {
    private enum Boundary: String, CustomStringConvertible {
        case beforeAppend
        case afterAppend

        var description: String { rawValue }
    }

    func testInjectorFailsOnlyAtPlannedOccurrenceAndRetainsTrace() throws {
        let injector = RelayFaultInjector<Boundary>(
            plannedOccurrences: [.afterAppend: [2]]
        )

        try injector.hit(.beforeAppend)
        try injector.hit(.afterAppend)
        XCTAssertThrowsError(try injector.hit(.afterAppend)) { error in
            XCTAssertEqual(
                error as? RelayInjectedFault,
                RelayInjectedFault(boundary: "afterAppend", occurrence: 2)
            )
        }
        try injector.hit(.afterAppend)

        XCTAssertEqual(
            injector.trace,
            [.beforeAppend, .afterAppend, .afterAppend, .afterAppend]
        )
        XCTAssertEqual(injector.occurrenceCount(for: .afterAppend), 3)
    }

    func testCorruptionFixturesAreStableAndDoNotMutateInput() {
        let original = Data([0x01, 0x02, 0x03, 0x04])

        XCTAssertEqual(
            RelayEvidenceCorruptionFixture.truncating(original, toByteCount: 2),
            Data([0x01, 0x02])
        )
        XCTAssertEqual(
            RelayEvidenceCorruptionFixture.flippingByte(original, at: 1),
            Data([0x01, 0xFD, 0x03, 0x04])
        )
        XCTAssertEqual(
            RelayEvidenceCorruptionFixture.appendingGarbage(original),
            Data([0x01, 0x02, 0x03, 0x04, 0x00, 0xFF, 0x7B])
        )
        XCTAssertEqual(original, Data([0x01, 0x02, 0x03, 0x04]))
    }

    func testFalseReadyFixturesRemainPlausibleButContradictTheirClaim() throws {
        let wrongCommit = try jsonObject(
            RelayFalseReadyFixture.wrongCommit()
        )
        let evidence = try XCTUnwrap(wrongCommit["evidence"] as? [String: Any])
        XCTAssertEqual(wrongCommit["claim"] as? String, "ready")
        XCTAssertEqual(evidence["status"] as? String, "pass")
        XCTAssertNotEqual(
            wrongCommit["claimedCommit"] as? String,
            evidence["commit"] as? String
        )

        let diagnostic = try jsonObject(
            RelayFalseReadyFixture.zeroExitFailureDiagnostic()
        )
        let diagnosticEvidence = try XCTUnwrap(
            diagnostic["evidence"] as? [String: Any]
        )
        XCTAssertEqual(diagnosticEvidence["exitStatus"] as? Int, 0)
        XCTAssertTrue(
            try XCTUnwrap(diagnosticEvidence["stderr"] as? String)
                .contains("data race detected")
        )

        let staleDigest = try jsonObject(
            RelayFalseReadyFixture.sameCommitStaleWorkspaceDigest()
        )
        let staleDigestEvidence = try XCTUnwrap(
            staleDigest["evidence"] as? [String: Any]
        )
        XCTAssertEqual(
            staleDigest["claimedCommit"] as? String,
            staleDigestEvidence["commit"] as? String
        )
        XCTAssertNotEqual(
            staleDigest["claimedWorkspaceDigest"] as? String,
            staleDigestEvidence["workspaceDigest"] as? String
        )
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }
}
