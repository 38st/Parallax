import Foundation
import XCTest
@testable import Parallax

final class ProfileInstanceVisualIdentityTests: XCTestCase {
    func testIdentityIsStableForAProfile() throws {
        let profileID = try XCTUnwrap(
            UUID(uuidString: "7C4A78B1-11B8-4D41-9E0E-7C8C509BA8E4")
        )

        XCTAssertEqual(
            ProfileInstanceVisualIdentity(profileID: profileID),
            ProfileInstanceVisualIdentity(profileID: profileID)
        )
    }

    func testDifferentProfilesReceiveDifferentCombinedIdentities()
        throws
    {
        let firstID = try XCTUnwrap(
            UUID(uuidString: "7C4A78B1-11B8-4D41-9E0E-7C8C509BA8E4")
        )
        let secondID = try XCTUnwrap(
            UUID(uuidString: "B6258A10-1BA7-4A75-ACCD-A07A00B4B6EE")
        )

        XCTAssertNotEqual(
            ProfileInstanceVisualIdentity(profileID: firstID),
            ProfileInstanceVisualIdentity(profileID: secondID)
        )
    }

    func testOutsideParallaxInstanceUsesNeutralIdentity() {
        let identity = ProfileInstanceVisualIdentity(profileID: nil)

        XCTAssertEqual(identity.systemImageName, "app.dashed")
        XCTAssertEqual(identity.color, .gray)
    }
}
