import Foundation
import RelayCore
import XCTest

final class RelayIdentityAndDigestTests: XCTestCase {
    func testTypedIDsEncodeAsStableLowercaseStrings() throws {
        let id: RelayTaskID = RelayCoreFixtures.id(0xAB)
        let encoded = try RelayCanonicalEncoding.encode(id)

        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"\(id.description)\"")
        XCTAssertEqual(try JSONDecoder().decode(RelayTaskID.self, from: encoded), id)
    }

    func testMalformedIdentifiersAndHashesAreRejected() {
        XCTAssertNil(RelayTaskID(uuidString: "not-a-uuid"))
        XCTAssertNil(RelayDigest(rawValue: String(repeating: "z", count: 64)))
        XCTAssertNil(RelayDigest(rawValue: String(repeating: "a", count: 63)))
        XCTAssertNil(RelayGitOID(rawValue: String(repeating: "a", count: 39)))
        XCTAssertNil(RelayGitOID(rawValue: String(repeating: "g", count: 40)))
    }

    func testMalformedHashCannotBypassValidationThroughDecoding() {
        XCTAssertThrowsError(
            try JSONDecoder().decode(RelayDigest.self, from: Data("\"bad\"".utf8))
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(RelayGitOID.self, from: Data("\"bad\"".utf8))
        )
    }

    func testCanonicalDigestIsDeterministicAndContentSensitive() throws {
        struct Fixture: Codable {
            let name: String
            let count: Int
        }
        let first = try RelayCanonicalEncoding.digest(Fixture(name: "relay", count: 1))
        let replay = try RelayCanonicalEncoding.digest(Fixture(name: "relay", count: 1))
        let changed = try RelayCanonicalEncoding.digest(Fixture(name: "relay", count: 2))

        XCTAssertEqual(first, replay)
        XCTAssertNotEqual(first, changed)
    }

    func testEventRoundTripsWithoutLosingAssociatedValues() throws {
        let event = RelayEvent.attemptApproved(
            RelayCoreFixtures.id(20),
            resultCommit: RelayCoreFixtures.initialCommit,
            resultWorkspaceDigest: RelayCoreFixtures.changedDigest,
            baton: RelayCoreFixtures.baton(
                id: RelayCoreFixtures.id(21),
                revision: 1,
                from: RelayCoreFixtures.implementStageID,
                to: RelayCoreFixtures.verifyStageID,
                sourceDigest: RelayCoreFixtures.initialDigest,
                resultDigest: RelayCoreFixtures.changedDigest
            ),
            at: RelayCoreFixtures.later
        )
        let bytes = try RelayCanonicalEncoding.encode(event)

        XCTAssertEqual(try JSONDecoder().decode(RelayEvent.self, from: bytes), event)
    }
}
