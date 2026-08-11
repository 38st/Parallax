import XCTest
@testable import Parallax

final class RelayPresentationTests: XCTestCase {
    func testEveryExecutionStatusHasTruthfulAccessiblePresentation() {
        for status in RelayExecutionStatus.allCases {
            XCTAssertFalse(status.label.isEmpty, "Missing label for \(status)")
            XCTAssertFalse(status.systemImage.isEmpty, "Missing symbol for \(status)")
            XCTAssertFalse(
                status.accessibilityDescription.isEmpty,
                "Missing accessibility description for \(status)"
            )
        }

        XCTAssertNotEqual(
            RelayExecutionStatus.starting.label,
            RelayExecutionStatus.running.label
        )
        XCTAssertNotEqual(
            RelayExecutionStatus.completed.label,
            RelayDeliveryStatus.delivered.label
        )
        XCTAssertTrue(
            RelayExecutionStatus.completed.accessibilityDescription
                .localizedCaseInsensitiveContains("delivery")
        )
    }

    func testEveryDeliveryStatusHasVisibleTextAndSymbol() {
        for status in RelayDeliveryStatus.allCases {
            XCTAssertFalse(status.label.isEmpty, "Missing label for \(status)")
            XCTAssertFalse(status.systemImage.isEmpty, "Missing symbol for \(status)")
        }

        XCTAssertEqual(
            RelayDeliveryStatus.stateUnknown.tone,
            .warning
        )
        XCTAssertNotEqual(
            RelayDeliveryStatus.ciPending.label,
            RelayDeliveryStatus.ciVerified.label
        )
    }

    func testTaskGroupingKeepsAttentionAndTerminalStatesSeparate() {
        XCTAssertEqual(RelayExecutionStatus.needsUser.listGroup, .needsAttention)
        XCTAssertEqual(RelayExecutionStatus.stalled.listGroup, .needsAttention)
        XCTAssertEqual(RelayExecutionStatus.failed.listGroup, .needsAttention)
        XCTAssertEqual(RelayExecutionStatus.blocked.listGroup, .needsAttention)
        XCTAssertEqual(RelayExecutionStatus.running.listGroup, .active)
        XCTAssertEqual(RelayExecutionStatus.recovering.listGroup, .active)
        XCTAssertEqual(RelayExecutionStatus.completed.listGroup, .recent)
        XCTAssertEqual(RelayExecutionStatus.stopped.listGroup, .recent)
    }

    func testBlockedIsDurableAndDistinctFromFailureOrStalledLiveness() {
        XCTAssertEqual(RelayExecutionStatus.blocked.label, "Blocked")
        XCTAssertEqual(RelayExecutionStatus.blocked.listGroup, .needsAttention)
        XCTAssertNotEqual(
            RelayExecutionStatus.blocked.label,
            RelayExecutionStatus.failed.label
        )
        XCTAssertNotEqual(
            RelayExecutionStatus.blocked.label,
            RelayExecutionStatus.stalled.label
        )
        XCTAssertTrue(
            RelayExecutionStatus.blocked.accessibilityDescription
                .localizedCaseInsensitiveContains("capability")
        )
    }

    func testTaskAccessibilityLabelNamesBothTruthAxes() {
        let summary = RelayPresentationFixtures.task().summary

        let label = summary.accessibilityLabel(
            now: RelayPresentationFixtures.now,
            locale: Locale(identifier: "en_US")
        )

        XCTAssertTrue(label.contains("Execution:"))
        XCTAssertTrue(label.contains(RelayExecutionStatus.needsUser.label))
        XCTAssertTrue(label.contains("Delivery:"))
        XCTAssertTrue(
            label.contains(RelayDeliveryStatus.localEvidenceCaptured.label)
        )
        XCTAssertTrue(label.contains("Security Review"))
    }

    func testMissingLiveVerificationIsNotPresentedAsCurrent() {
        let task = RelayPresentationFixtures.task()
        let summary = RelayTaskSummaryPresentation(
            id: task.id,
            title: task.summary.title,
            objective: task.summary.objective,
            repositoryName: task.summary.repositoryName,
            repositoryPath: task.summary.repositoryPath,
            branchName: task.summary.branchName,
            executionStatus: .running,
            deliveryStatus: .noArtifact,
            currentStageLabel: task.summary.currentStageLabel,
            lastVerifiedAt: nil,
            updatedAt: task.summary.updatedAt
        )

        XCTAssertEqual(
            summary.lastVerifiedLabel(),
            "No live verification recorded"
        )
    }

    func testOpenFindingsSortBySeverityThenStableIdentifier() {
        let base = RelayPresentationFixtures.task()
        let findings = [
            finding("UX-2", severity: .p2),
            finding("SEC-2", severity: .p0),
            finding("SEC-1", severity: .p0),
            finding("DONE-1", severity: .p0, status: .resolved),
        ]
        let task = RelayTaskPresentation(
            summary: base.summary,
            stages: base.stages,
            batons: base.batons,
            findings: findings,
            evidence: base.evidence,
            gates: base.gates,
            recovery: base.recovery,
            completion: base.completion
        )

        XCTAssertEqual(task.openFindings.map(\.id), ["SEC-1", "SEC-2", "UX-2"])
    }

    func testIntakeRequiresRepositoryObjectiveAndCriteria() {
        var draft = RelayIntakeDraft()

        XCTAssertEqual(
            draft.validationIssues,
            [.repositoryRequired, .objectiveRequired, .acceptanceCriteriaRequired]
        )
        XCTAssertFalse(draft.canStart)

        draft.repositoryPath = "/tmp/Parallax"
        draft.objective = "Fix the release pipeline"
        draft.acceptanceCriteriaText = "Tests pass\n\nCI reports exact failures\n"

        XCTAssertEqual(
            draft.acceptanceCriteria,
            ["Tests pass", "CI reports exact failures"]
        )
        XCTAssertTrue(draft.canStart)
    }

    func testIntakePromisesOnlyLocalReadyForInspectionResult() {
        let copy = [
            RelayIntakePresentation.stages,
            RelayIntakePresentation.result,
            RelayIntakePresentation.schedulingDisclosure,
        ].joined(separator: " ").lowercased()

        XCTAssertTrue(copy.contains("ready for your inspection"))
        XCTAssertTrue(copy.contains("worktree"))
        XCTAssertTrue(copy.contains("patch"))
        XCTAssertFalse(copy.contains("deliver"))
        XCTAssertFalse(copy.contains("commit"))
        XCTAssertFalse(copy.contains("pull request"))
    }

    func testRecoveryCopyDoesNotClaimFailureForUnknownDelivery() {
        let recovery = RelayRecoveryPresentation.deliveryStateUnknown(
            detail: "The push may have completed before the connection closed."
        )

        XCTAssertEqual(recovery.title, "Delivery State Unknown")
        XCTAssertEqual(recovery.actionLabel, "Reconcile Delivery")
        XCTAssertFalse(recovery.detail?.localizedCaseInsensitiveContains("failed") == true)
    }

    private func finding(
        _ id: String,
        severity: RelayFindingSeverity,
        status: RelayFindingStatus = .open
    ) -> RelayFindingPresentation {
        RelayFindingPresentation(
            id: id,
            severity: severity,
            status: status,
            title: "Finding \(id)",
            ownerStage: "Implement",
            attemptLabel: "Attempt 1",
            detail: "Detail",
            evidenceIDs: [],
            resolution: status == .resolved ? "Fixed" : nil
        )
    }
}
