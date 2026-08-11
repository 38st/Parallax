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

    func testStableAssignmentAndSelectableOrderingAreFrozen() throws {
        let profileID = try XCTUnwrap(
            UUID(uuidString: "10000000-0000-4000-8000-000000000001")
        )

        XCTAssertEqual(
            ProfileInstanceVisualIdentity(profileID: profileID),
            ProfileInstanceVisualIdentity(symbol: .terminal, color: .green)
        )
        XCTAssertEqual(
            ProfileInstanceVisualIdentity.selectableSymbols.map(\.rawValue),
            [
                "briefcase.fill", "person.crop.circle.fill", "flask.fill",
                "terminal.fill", "book.closed.fill", "paintpalette.fill",
                "globe", "lightbulb.fill", "hammer.fill", "camera.fill",
                "music.note", "leaf.fill",
            ]
        )
        XCTAssertEqual(
            ProfileInstanceVisualIdentity.selectableColors.map(\.rawValue),
            [
                "blue", "purple", "orange", "pink", "teal", "green",
                "indigo", "cyan", "brown",
            ]
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
