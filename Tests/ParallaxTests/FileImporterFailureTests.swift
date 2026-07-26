import Foundation
import XCTest
@testable import Parallax

final class FileImporterFailureTests: XCTestCase {
    func testUserCancellationIsTheOnlyIgnoredCocoaFailure() {
        XCTAssertNil(
            FileImporterFailure.userFacingMessage(
                for: CancellationError()
            )
        )
        let cancellation = CocoaError(.userCancelled)
        XCTAssertNil(
            FileImporterFailure.userFacingMessage(
                for: cancellation
            )
        )

        let permission = CocoaError(
            .fileReadNoPermission,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The provider denied access.",
            ]
        )
        XCTAssertEqual(
            FileImporterFailure.userFacingMessage(for: permission),
            "The provider denied access."
        )
    }

    func testProviderAndMalformedSelectionFailuresRemainVisible() {
        let provider = NSError(
            domain: "FileProvider",
            code: 42,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "The provider is unavailable.",
            ]
        )
        XCTAssertEqual(
            FileImporterFailure.userFacingMessage(for: provider),
            "The provider is unavailable."
        )

        let malformed = CocoaError(.fileReadCorruptFile)
        XCTAssertNotNil(
            FileImporterFailure.userFacingMessage(for: malformed)
        )
    }
}
