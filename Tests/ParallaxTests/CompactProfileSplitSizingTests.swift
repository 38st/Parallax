import XCTest
@testable import Parallax

final class CompactProfileSplitSizingTests: XCTestCase {
    func testRequestedHeightTracksWithinAvailableRange() {
        XCTAssertEqual(
            CompactProfileSplitSizing.listHeight(
                requested: 295,
                availableHeight: 600
            ),
            295
        )
    }

    func testRequestedHeightClampsAtBothPaneMinimums() {
        XCTAssertEqual(
            CompactProfileSplitSizing.listHeight(
                requested: 20,
                availableHeight: 600
            ),
            CompactProfileSplitSizing.minimumListHeight
        )
        XCTAssertEqual(
            CompactProfileSplitSizing.listHeight(
                requested: 900,
                availableHeight: 600
            ),
            600
                - CompactProfileSplitSizing.minimumEditorHeight
                - CompactProfileSplitSizing.handleHeight
        )
    }

    func testSmallContainerPrioritizesMinimumListHeight() {
        XCTAssertEqual(
            CompactProfileSplitSizing.listHeight(
                requested: 220,
                availableHeight: 300
            ),
            CompactProfileSplitSizing.minimumListHeight
        )
    }
}
