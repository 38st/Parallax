import Foundation
@testable import Parallax

enum RelayPresentationFixtures {
    static let taskID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    static let stageID = UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
    static let attemptID = UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
    static let batonID = UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
    static let gateID = UUID(uuidString: "50000000-0000-0000-0000-000000000001")!
    static let now = Date(timeIntervalSince1970: 1_700_000_000)

    static func task(
        execution: RelayExecutionStatus = .needsUser,
        delivery: RelayDeliveryStatus = .localEvidenceCaptured,
        recovery: RelayRecoveryPresentation = .none
    ) -> RelayTaskPresentation {
        RelayTaskPresentation(
            summary: RelayTaskSummaryPresentation(
                id: taskID,
                title: "Harden archive installation",
                objective: "Reject unsafe archive entries and preserve valid releases.",
                repositoryName: "Parallax",
                repositoryPath: "/tmp/Parallax",
                branchName: "codex/relay",
                executionStatus: execution,
                deliveryStatus: delivery,
                currentStageLabel: "Security Review",
                lastVerifiedAt: now.addingTimeInterval(-30),
                updatedAt: now
            ),
            stages: [
                RelayStagePresentation(
                    id: stageID,
                    position: 1,
                    name: "Security Review",
                    role: "Reviewer",
                    status: execution == .needsUser
                        ? .waitingForApproval
                        : .running,
                    isCurrent: true,
                    attempts: [
                        RelayAttemptPresentation(
                            id: attemptID,
                            number: 1,
                            status: .rejected,
                            startedAt: now.addingTimeInterval(-120),
                            endedAt: now.addingTimeInterval(-60),
                            summary: "Returned one blocking finding.",
                            returnReasonFindingIDs: ["SEC-17"]
                        )
                    ],
                    incomingBatonID: batonID,
                    outgoingBatonID: nil
                )
            ],
            batons: [
                RelayBatonPresentation(
                    id: batonID,
                    sourceStage: "Implement",
                    destinationStage: "Security Review",
                    recordedAt: now.addingTimeInterval(-130),
                    taskRevision: 3,
                    workspaceCommit: "abc123",
                    objective: "Reject unsafe archive entries.",
                    acceptanceCriteria: ["Traversal entries are rejected."],
                    changes: ["Added canonical path validation."],
                    evidenceIDs: ["TEST-1"],
                    openFindingIDs: ["SEC-17"],
                    residualRisks: ["Malformed central-directory overlap is out of scope."],
                    isStale: false
                )
            ],
            findings: [
                RelayFindingPresentation(
                    id: "SEC-17",
                    severity: .p1,
                    status: .open,
                    title: "Archive root symlink is accepted",
                    ownerStage: "Implement",
                    attemptLabel: "Attempt 1",
                    detail: "The extracted root must be a physical directory.",
                    evidenceIDs: ["TEST-1"],
                    resolution: nil
                )
            ],
            evidence: [
                RelayEvidencePresentation(
                    id: "TEST-1",
                    kind: .testSuite,
                    status: .captured,
                    title: "Archive verification tests",
                    detail: "9 tests passed.",
                    command: "swift test --filter ArchiveTests",
                    workingDirectory: "/tmp/Parallax",
                    startedAt: now.addingTimeInterval(-50),
                    endedAt: now.addingTimeInterval(-40),
                    exitCode: 0,
                    digest: "sha256:def456",
                    output: "Executed 9 tests, with 0 failures",
                    isOutputTruncated: false,
                    lastOutputAt: now.addingTimeInterval(-40)
                )
            ],
            gates: execution == .needsUser ? [gate] : [],
            recovery: recovery,
            completion: nil
        )
    }

    static let gate = RelayHumanGatePresentation(
        id: gateID,
        title: "Run repository tests?",
        requestedAction: "Execute the repository's local test command.",
        target: "/tmp/Parallax",
        authority: "Execute repository code in the isolated worktree",
        sideEffects: "The command may write only inside the isolated worktree.",
        reversibility: "The worktree is preserved for inspection.",
        evidenceSummary: "The exact command and sandbox limits were recorded.",
        requestedAt: now,
        state: .pending
    )
}
