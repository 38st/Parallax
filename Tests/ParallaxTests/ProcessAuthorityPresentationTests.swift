import Foundation
import XCTest
@testable import Parallax

final class ProcessAuthorityPresentationTests: XCTestCase {
    func testVerifiedTrackedInstanceEnablesExactProcessActions() {
        let instance = makeInstance(tracked: true)

        XCTAssertTrue(instance.isActionable)
        XCTAssertTrue(instance.actionPresentation.canShow)
        XCTAssertTrue(instance.actionPresentation.canQuit)
        XCTAssertEqual(
            instance.controlPresentation,
            .verifiedParallaxInstance
        )
        XCTAssertTrue(
            instance.controlPresentation.actionHelp.contains(
                "exact process"
            )
        )
    }

    func testOutsideProcessIsInformationalAndActionsAreUnavailable() {
        let instance = makeInstance(tracked: false)

        XCTAssertFalse(instance.isActionable)
        XCTAssertFalse(instance.actionPresentation.canShow)
        XCTAssertFalse(instance.actionPresentation.canQuit)
        XCTAssertEqual(instance.controlPresentation, .outsideParallax)
        XCTAssertTrue(
            instance.controlPresentation.detailLabel.contains(
                "Informational only"
            )
        )
        XCTAssertTrue(
            instance.controlPresentation.actionHelp.contains(
                "Show and Quit are unavailable"
            )
        )
    }

    func testVerificationUnavailablePresentationFailsClosed() {
        let presentation = ProcessAuthorityPresentation
            .verificationUnavailable

        XCTAssertFalse(presentation.isActionable)
        XCTAssertTrue(
            presentation.detailLabel.contains(
                "verification unavailable"
            )
        )
        XCTAssertTrue(
            presentation.actionHelp.contains(
                "Show and Quit are unavailable"
            )
        )
    }

    func testIncompleteTrackedAttributionFailsClosed() {
        let base = makeInstance(tracked: true)
        let incomplete = ManagedApplicationInstance(
            processIdentity: base.processIdentity,
            requestID: base.requestID,
            profileID: base.profileID,
            profileStorageID: base.profileStorageID,
            profileName: nil
        )

        XCTAssertFalse(incomplete.isActionable)
        XCTAssertEqual(
            incomplete.controlPresentation,
            .outsideParallax
        )
    }

    func testPresentationTransitionChangesBothActionGatesBehaviorally() {
        let pending = makeInstance(tracked: true).presenting(
            .verificationUnavailable
        )
        let verified = pending.presenting(.verifiedParallaxInstance)

        XCTAssertFalse(pending.isActionable)
        XCTAssertFalse(pending.actionPresentation.canShow)
        XCTAssertFalse(pending.actionPresentation.canQuit)
        XCTAssertTrue(verified.isActionable)
        XCTAssertTrue(verified.actionPresentation.canShow)
        XCTAssertTrue(verified.actionPresentation.canQuit)
        XCTAssertEqual(
            pending.processIdentity,
            verified.processIdentity
        )
        XCTAssertEqual(pending.requestID, verified.requestID)
    }

    private func makeInstance(
        tracked: Bool
    ) -> ManagedApplicationInstance {
        ManagedApplicationInstance(
            processIdentity: WorkspaceProcessIdentity(
                process: ProcessStartIdentity(
                    processIdentifier: 801,
                    startTimeSeconds: 1,
                    startTimeMicroseconds: 2
                ),
                application: WorkspaceApplicationBundleIdentity(
                    bundleURL: URL(
                        fileURLWithPath: "/Applications/Test.app"
                    ),
                    bundleIdentifier: "example.test"
                )
            ),
            requestID: tracked ? UUID() : nil,
            profileID: tracked ? UUID() : nil,
            profileStorageID: tracked ? UUID() : nil,
            profileName: tracked ? "Work" : nil,
            controlPresentation:
                tracked ? .verifiedParallaxInstance : .outsideParallax
        )
    }
}
