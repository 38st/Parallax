import XCTest
@testable import Parallax

final class UIAutomationContractTests: XCTestCase {
    func testCriticalJourneyIdentifiersAreStableAndUnique() {
        XCTAssertEqual(
            UIAutomationContract.newSpaceName,
            "new-space.name"
        )
        XCTAssertEqual(
            UIAutomationContract.newSpaceCreateAndOpen,
            "new-space.create-and-open"
        )
        XCTAssertEqual(
            UIAutomationContract.editorSaveAndOpen,
            "space-editor.save-and-open"
        )
        XCTAssertEqual(
            UIAutomationContract.applicationRemovalConfirm,
            "application-removal.confirm"
        )
        XCTAssertEqual(
            Set(UIAutomationContract.criticalJourneyIdentifiers).count,
            UIAutomationContract.criticalJourneyIdentifiers.count
        )
    }
}
