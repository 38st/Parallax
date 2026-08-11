import XCTest
@testable import Parallax

final class RelayAccessibilityTests: XCTestCase {
    func testCriticalTaskTraversalUsesUniqueStableIdentifiers() {
        let task = RelayPresentationFixtures.task()

        let identifiers = RelayAccessibilityContract.taskTraversal(task)

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(
            identifiers.first,
            RelayAccessibilityIdentifier.task(task.id)
        )
        XCTAssertTrue(
            identifiers.contains(
                RelayAccessibilityIdentifier.executionStatus(task.id)
            )
        )
        XCTAssertTrue(
            identifiers.contains(
                RelayAccessibilityIdentifier.deliveryStatus(task.id)
            )
        )
        XCTAssertTrue(
            identifiers.contains(
                RelayAccessibilityIdentifier.approveGate(
                    RelayPresentationFixtures.gateID
                )
            )
        )
        XCTAssertTrue(
            identifiers.contains(
                RelayAccessibilityIdentifier.finding("SEC-17")
            )
        )
        XCTAssertTrue(
            identifiers.contains(
                RelayAccessibilityIdentifier.evidence("TEST-1")
            )
        )
    }

    func testActionTraversalMatchesExecutionState() {
        let running = RelayPresentationFixtures.task(execution: .running)
        let paused = RelayPresentationFixtures.task(execution: .paused)
        let interrupted = RelayPresentationFixtures.task(execution: .interrupted)

        XCTAssertTrue(
            RelayAccessibilityContract.taskTraversal(running).contains(
                RelayAccessibilityIdentifier.pause(running.id)
            )
        )
        XCTAssertFalse(
            RelayAccessibilityContract.taskTraversal(running).contains(
                RelayAccessibilityIdentifier.resume(running.id)
            )
        )
        XCTAssertTrue(
            RelayAccessibilityContract.taskTraversal(paused).contains(
                RelayAccessibilityIdentifier.resume(paused.id)
            )
        )
        XCTAssertTrue(
            RelayAccessibilityContract.taskTraversal(interrupted).contains(
                RelayAccessibilityIdentifier.retry(interrupted.id)
            )
        )
    }

    func testExternalIdentifiersAreSanitized() {
        let identifier = RelayAccessibilityIdentifier.finding(
            "SEC/17: root symlink"
        )

        XCTAssertEqual(identifier, "relay.finding.sec-17--root-symlink")
        XCTAssertFalse(identifier.contains(" "))
        XCTAssertFalse(identifier.contains("/"))
        XCTAssertFalse(identifier.contains(":"))
    }

    func testIntakeIdentifiersAreUnique() {
        let identifiers = [
            RelayAccessibilityIdentifier.intake,
            RelayAccessibilityIdentifier.intakeTitle,
            RelayAccessibilityIdentifier.intakeRepository,
            RelayAccessibilityIdentifier.intakeChooseRepository,
            RelayAccessibilityIdentifier.intakeObjective,
            RelayAccessibilityIdentifier.intakeCriteria,
            RelayAccessibilityIdentifier.intakeStart,
            RelayAccessibilityIdentifier.intakeCancel,
        ]

        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }
}
