import Foundation

enum RelayPresentationTone: Sendable, Equatable {
    case neutral
    case accent
    case active
    case warning
    case failure
}

enum RelayExecutionStatus: String, CaseIterable, Sendable, Equatable {
    case draft
    case queued
    case starting
    case running
    case needsUser
    case pausing
    case paused
    case recovering
    case blocked
    case stalled
    case interrupted
    case failed
    case stopped
    case completed

    var label: String {
        switch self {
        case .draft: String(localized: "Draft")
        case .queued: String(localized: "Queued")
        case .starting: String(localized: "Starting")
        case .running: String(localized: "Running")
        case .needsUser: String(localized: "Needs You")
        case .pausing: String(localized: "Pausing")
        case .paused: String(localized: "Paused")
        case .recovering: String(localized: "Reconciling")
        case .blocked: String(localized: "Blocked")
        case .stalled: String(localized: "Stalled")
        case .interrupted: String(localized: "Interrupted")
        case .failed: String(localized: "Failed")
        case .stopped: String(localized: "Stopped")
        case .completed: String(localized: "Completion Contract Met")
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .draft:
            String(localized: "The relay has not started.")
        case .queued:
            String(localized: "The relay is accepted but no worker has started.")
        case .starting:
            String(localized: "Parallax requested a worker and is waiting for the first durable stage event.")
        case .running:
            String(localized: "The current attempt has a verified live worker.")
        case .needsUser:
            String(localized: "The relay is waiting for a human decision.")
        case .pausing:
            String(localized: "A pause was requested and the relay is moving to a safe checkpoint.")
        case .paused:
            String(localized: "The relay reached a safe paused checkpoint.")
        case .recovering:
            String(localized: "Parallax is reconciling durable events with live workers.")
        case .blocked:
            String(localized: "The relay is durably saved but cannot execute because a required capability is unavailable.")
        case .stalled:
            String(localized: "The current worker has not provided recent liveness evidence.")
        case .interrupted:
            String(localized: "The prior attempt ended without a terminal result.")
        case .failed:
            String(localized: "The relay recorded a terminal failure.")
        case .stopped:
            String(localized: "The relay was stopped before completion.")
        case .completed:
            String(localized: "The configured completion contract is satisfied. Delivery is reported separately.")
        }
    }

    var systemImage: String {
        switch self {
        case .draft: "doc"
        case .queued: "clock"
        case .starting: "hourglass"
        case .running: "play.circle.fill"
        case .needsUser: "person.crop.circle.badge.exclamationmark"
        case .pausing: "pause.circle"
        case .paused: "pause.circle.fill"
        case .recovering: "arrow.triangle.2.circlepath"
        case .blocked: "exclamationmark.lock.fill"
        case .stalled: "clock.badge.exclamationmark"
        case .interrupted: "bolt.slash"
        case .failed: "xmark.octagon.fill"
        case .stopped: "stop.circle"
        case .completed: "checkmark.circle.fill"
        }
    }

    var tone: RelayPresentationTone {
        switch self {
        case .running: .active
        case .needsUser, .blocked, .stalled, .interrupted: .warning
        case .failed: .failure
        case .completed: .accent
        case .draft, .queued, .starting, .pausing, .paused,
             .recovering, .stopped: .neutral
        }
    }

    var listGroup: RelayTaskListGroup {
        switch self {
        case .needsUser, .blocked, .stalled, .interrupted, .failed:
            .needsAttention
        case .draft, .queued, .starting, .running, .pausing, .paused,
             .recovering:
            .active
        case .stopped, .completed:
            .recent
        }
    }
}

enum RelayDeliveryStatus: String, CaseIterable, Sendable, Equatable {
    case noArtifact
    case localEvidenceCaptured
    case independentlyApproved
    case commitCreated
    case draftPullRequestCreated
    case ciPending
    case ciFailed
    case ciVerified
    case delivered
    case stateUnknown

    var label: String {
        switch self {
        case .noArtifact: String(localized: "No Delivery Artifact")
        case .localEvidenceCaptured: String(localized: "Local Evidence Captured")
        case .independentlyApproved: String(localized: "Independently Approved")
        case .commitCreated: String(localized: "Commit Created")
        case .draftPullRequestCreated: String(localized: "Draft Pull Request Created")
        case .ciPending: String(localized: "CI Pending")
        case .ciFailed: String(localized: "CI Failed")
        case .ciVerified: String(localized: "CI Verified")
        case .delivered: String(localized: "Delivered")
        case .stateUnknown: String(localized: "Delivery State Unknown")
        }
    }

    var systemImage: String {
        switch self {
        case .noArtifact: "shippingbox"
        case .localEvidenceCaptured: "checklist"
        case .independentlyApproved: "checkmark.seal"
        case .commitCreated: "point.topleft.down.to.point.bottomright.curvepath"
        case .draftPullRequestCreated: "arrow.triangle.pull"
        case .ciPending: "clock.arrow.circlepath"
        case .ciFailed: "xmark.octagon"
        case .ciVerified: "checkmark.shield"
        case .delivered: "paperplane.fill"
        case .stateUnknown: "questionmark.diamond"
        }
    }

    var tone: RelayPresentationTone {
        switch self {
        case .ciFailed: .failure
        case .stateUnknown: .warning
        case .ciVerified, .delivered: .active
        case .independentlyApproved: .accent
        case .noArtifact, .localEvidenceCaptured, .commitCreated,
             .draftPullRequestCreated, .ciPending: .neutral
        }
    }
}

enum RelayTaskListGroup: Int, CaseIterable, Sendable, Equatable {
    case needsAttention
    case active
    case recent

    var label: String {
        switch self {
        case .needsAttention: String(localized: "Needs Attention")
        case .active: String(localized: "Active")
        case .recent: String(localized: "Recent")
        }
    }
}

struct RelayTaskSummaryPresentation: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let objective: String
    let repositoryName: String
    let repositoryPath: String
    let branchName: String?
    let executionStatus: RelayExecutionStatus
    let deliveryStatus: RelayDeliveryStatus
    let currentStageLabel: String?
    let lastVerifiedAt: Date?
    let updatedAt: Date

    var listGroup: RelayTaskListGroup { executionStatus.listGroup }

    func accessibilityLabel(
        now: Date = Date(),
        locale: Locale = .current
    ) -> String {
        let relative = Self.relativeDate(
            updatedAt,
            now: now,
            locale: locale
        )
        let stage = currentStageLabel.map { stageName in
            String(
                format: String(localized: "Current stage: %@."),
                stageName
            )
        } ?? String(localized: "No current stage.")
        return String(
            format: String(
                localized:
                    "%1$@, %2$@. Execution: %3$@. Delivery: %4$@. %5$@ Updated %6$@."
            ),
            title,
            repositoryName,
            executionStatus.label,
            deliveryStatus.label,
            stage,
            relative
        )
    }

    func lastVerifiedLabel(
        now: Date = Date(),
        locale: Locale = .current
    ) -> String {
        guard let lastVerifiedAt else {
            return String(localized: "No live verification recorded")
        }
        return String(
            format: String(localized: "Last verified %@"),
            Self.relativeDate(lastVerifiedAt, now: now, locale: locale)
        )
    }

    private static func relativeDate(
        _ date: Date,
        now: Date,
        locale: Locale
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

enum RelayStageStatus: String, CaseIterable, Sendable, Equatable {
    case notStarted
    case queued
    case running
    case waitingForApproval
    case pausing
    case paused
    case rejected
    case approved
    case failed
    case interrupted
    case blocked
    case skipped

    var label: String {
        switch self {
        case .notStarted: String(localized: "Not Started")
        case .queued: String(localized: "Queued")
        case .running: String(localized: "Running")
        case .waitingForApproval: String(localized: "Waiting for Approval")
        case .pausing: String(localized: "Pausing")
        case .paused: String(localized: "Paused")
        case .rejected: String(localized: "Rejected")
        case .approved: String(localized: "Approved")
        case .failed: String(localized: "Failed")
        case .interrupted: String(localized: "Interrupted")
        case .blocked: String(localized: "Blocked")
        case .skipped: String(localized: "Skipped")
        }
    }

    var systemImage: String {
        switch self {
        case .notStarted: "circle"
        case .queued: "clock"
        case .running: "play.circle.fill"
        case .waitingForApproval: "person.crop.circle.badge.questionmark"
        case .pausing: "pause.circle"
        case .paused: "pause.circle.fill"
        case .rejected: "arrow.uturn.backward.circle"
        case .approved: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .interrupted: "bolt.slash"
        case .blocked: "exclamationmark.lock.fill"
        case .skipped: "forward.end.circle"
        }
    }

    var tone: RelayPresentationTone {
        switch self {
        case .running: .active
        case .waitingForApproval, .rejected, .interrupted, .blocked: .warning
        case .failed: .failure
        case .approved: .accent
        case .notStarted, .queued, .pausing, .paused, .skipped: .neutral
        }
    }
}

struct RelayAttemptPresentation: Identifiable, Sendable, Equatable {
    let id: UUID
    let number: Int
    let status: RelayStageStatus
    let startedAt: Date?
    let endedAt: Date?
    let summary: String?
    let returnReasonFindingIDs: [String]

    var title: String {
        String(localized: "Attempt \(number)")
    }
}

struct RelayStagePresentation: Identifiable, Sendable, Equatable {
    let id: UUID
    let position: Int
    let name: String
    let role: String
    let status: RelayStageStatus
    let isCurrent: Bool
    let attempts: [RelayAttemptPresentation]
    let incomingBatonID: UUID?
    let outgoingBatonID: UUID?
}

struct RelayBatonPresentation: Identifiable, Sendable, Equatable {
    let id: UUID
    let sourceStage: String
    let destinationStage: String
    let recordedAt: Date
    let taskRevision: Int
    let workspaceCommit: String?
    let objective: String
    let acceptanceCriteria: [String]
    let changes: [String]
    let evidenceIDs: [String]
    let openFindingIDs: [String]
    let residualRisks: [String]
    let isStale: Bool
}

enum RelayFindingSeverity: Int, CaseIterable, Sendable, Equatable {
    case p0 = 0
    case p1 = 1
    case p2 = 2
    case p3 = 3

    var label: String { "P\(rawValue)" }

    var tone: RelayPresentationTone {
        switch self {
        case .p0, .p1: .failure
        case .p2: .warning
        case .p3: .neutral
        }
    }
}

enum RelayFindingStatus: String, CaseIterable, Sendable, Equatable {
    case open
    case resolved
    case waived

    var label: String {
        switch self {
        case .open: String(localized: "Open")
        case .resolved: String(localized: "Resolved")
        case .waived: String(localized: "Waived")
        }
    }
}

struct RelayFindingPresentation: Identifiable, Sendable, Equatable {
    let id: String
    let severity: RelayFindingSeverity
    let status: RelayFindingStatus
    let title: String
    let ownerStage: String
    let attemptLabel: String
    let detail: String
    let evidenceIDs: [String]
    let resolution: String?
}

enum RelayEvidenceKind: String, CaseIterable, Sendable, Equatable {
    case command
    case testSuite
    case artifact
    case commit
    case ciRun
    case humanDecision

    var label: String {
        switch self {
        case .command: String(localized: "Command")
        case .testSuite: String(localized: "Test Suite")
        case .artifact: String(localized: "Artifact")
        case .commit: String(localized: "Commit")
        case .ciRun: String(localized: "CI Run")
        case .humanDecision: String(localized: "Human Decision")
        }
    }

    var systemImage: String {
        switch self {
        case .command: "terminal"
        case .testSuite: "checklist"
        case .artifact: "shippingbox"
        case .commit: "point.topleft.down.to.point.bottomright.curvepath"
        case .ciRun: "gearshape.2"
        case .humanDecision: "person.badge.key"
        }
    }
}

enum RelayEvidenceStatus: String, CaseIterable, Sendable, Equatable {
    case claimed
    case captured
    case reproduced
    case running
    case failed
    case unavailable
    case redacted

    var label: String {
        switch self {
        case .claimed: String(localized: "Agent Claim")
        case .captured: String(localized: "Captured")
        case .reproduced: String(localized: "Independently Reproduced")
        case .running: String(localized: "Running")
        case .failed: String(localized: "Failed")
        case .unavailable: String(localized: "Unavailable")
        case .redacted: String(localized: "Sensitive Values Redacted")
        }
    }

    var tone: RelayPresentationTone {
        switch self {
        case .reproduced: .active
        case .failed: .failure
        case .unavailable: .warning
        case .claimed, .captured, .running, .redacted: .neutral
        }
    }
}

struct RelayEvidencePresentation: Identifiable, Sendable, Equatable {
    let id: String
    let kind: RelayEvidenceKind
    let status: RelayEvidenceStatus
    let title: String
    let detail: String?
    let command: String?
    let workingDirectory: String?
    let startedAt: Date?
    let endedAt: Date?
    let exitCode: Int32?
    let digest: String?
    let output: String?
    let isOutputTruncated: Bool
    let lastOutputAt: Date?
}

enum RelayGateState: String, CaseIterable, Sendable, Equatable {
    case pending
    case submitting
    case approved
    case denied
    case expired

    var label: String {
        switch self {
        case .pending: String(localized: "Decision Required")
        case .submitting: String(localized: "Submitting Decision")
        case .approved: String(localized: "Approved")
        case .denied: String(localized: "Denied")
        case .expired: String(localized: "Expired")
        }
    }
}

struct RelayHumanGatePresentation: Identifiable, Sendable, Equatable {
    let id: UUID
    let title: String
    let requestedAction: String
    let target: String
    let authority: String
    let sideEffects: String
    let reversibility: String
    let evidenceSummary: String?
    let requestedAt: Date
    let state: RelayGateState
}

enum RelayRecoveryPresentation: Sendable, Equatable {
    case none
    case reconciling(lastDurableEvent: String)
    case stalled(detail: String)
    case interrupted(detail: String)
    case deliveryStateUnknown(detail: String)
    case blocked(title: String, detail: String)

    var title: String? {
        switch self {
        case .none: nil
        case .reconciling: String(localized: "Reconciling Relay State")
        case .stalled: String(localized: "Worker Liveness Is Stale")
        case .interrupted: String(localized: "Attempt Interrupted")
        case .deliveryStateUnknown: String(localized: "Delivery State Unknown")
        case .blocked(let title, _): title
        }
    }

    var detail: String? {
        switch self {
        case .none: nil
        case .reconciling(let event):
            String(
                format: String(
                    localized:
                        "Parallax is comparing live workers with the last durable event: %@"
                ),
                event
            )
        case .stalled(let detail), .interrupted(let detail),
             .deliveryStateUnknown(let detail), .blocked(_, let detail):
            detail
        }
    }

    var systemImage: String {
        switch self {
        case .none: ""
        case .reconciling: "arrow.triangle.2.circlepath"
        case .stalled: "clock.badge.exclamationmark"
        case .interrupted: "bolt.slash"
        case .deliveryStateUnknown: "questionmark.diamond"
        case .blocked: "exclamationmark.lock"
        }
    }

    var actionLabel: String? {
        switch self {
        case .none, .reconciling: nil
        case .stalled: String(localized: "Check Worker")
        case .interrupted: String(localized: "Retry Stage")
        case .deliveryStateUnknown: String(localized: "Reconcile Delivery")
        case .blocked: String(localized: "Review Recovery")
        }
    }
}

enum RelayCriterionStatus: Sendable, Equatable {
    case pending
    case satisfied
    case failed
    case waived

    var label: String {
        switch self {
        case .pending: String(localized: "Pending")
        case .satisfied: String(localized: "Satisfied")
        case .failed: String(localized: "Failed")
        case .waived: String(localized: "Waived")
        }
    }

    var systemImage: String {
        switch self {
        case .pending: "circle"
        case .satisfied: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .waived: "exclamationmark.circle"
        }
    }
}

struct RelayCriterionPresentation: Identifiable, Sendable, Equatable {
    let id: String
    let text: String
    let status: RelayCriterionStatus
    let evidenceIDs: [String]
}

struct RelayCompletionPresentation: Sendable, Equatable {
    let title: String
    let summary: String
    let criteria: [RelayCriterionPresentation]
    let residualRisks: [String]
    let artifactLabel: String?
    let artifactDestination: String?
    let approvalSummary: String?
}

struct RelayTaskPresentation: Identifiable, Sendable, Equatable {
    var id: UUID { summary.id }

    let summary: RelayTaskSummaryPresentation
    let stages: [RelayStagePresentation]
    let batons: [RelayBatonPresentation]
    let findings: [RelayFindingPresentation]
    let evidence: [RelayEvidencePresentation]
    let gates: [RelayHumanGatePresentation]
    let recovery: RelayRecoveryPresentation
    let completion: RelayCompletionPresentation?

    var pendingGates: [RelayHumanGatePresentation] {
        gates.filter { $0.state == .pending || $0.state == .submitting }
    }

    var openFindings: [RelayFindingPresentation] {
        findings.filter { $0.status == .open }
            .sorted {
                if $0.severity.rawValue == $1.severity.rawValue {
                    return $0.id.localizedStandardCompare($1.id) == .orderedAscending
                }
                return $0.severity.rawValue < $1.severity.rawValue
            }
    }
}

enum RelayTaskDetailSection: String, CaseIterable, Identifiable, Sendable {
    case progress
    case findings
    case evidence

    var id: String { rawValue }

    var label: String {
        switch self {
        case .progress: String(localized: "Progress")
        case .findings: String(localized: "Findings")
        case .evidence: String(localized: "Evidence")
        }
    }
}

struct RelayIntakeDraft: Sendable, Equatable {
    var title = ""
    var repositoryPath = ""
    var objective = ""
    var acceptanceCriteriaText = ""

    var acceptanceCriteria: [String] {
        acceptanceCriteriaText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var validationIssues: [RelayIntakeValidationIssue] {
        var issues: [RelayIntakeValidationIssue] = []
        if repositoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.repositoryRequired)
        }
        if objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.objectiveRequired)
        }
        if acceptanceCriteria.isEmpty {
            issues.append(.acceptanceCriteriaRequired)
        }
        return issues
    }

    var canStart: Bool { validationIssues.isEmpty }
}

enum RelayIntakeValidationIssue: CaseIterable, Sendable, Equatable {
    case repositoryRequired
    case objectiveRequired
    case acceptanceCriteriaRequired

    var message: String {
        switch self {
        case .repositoryRequired:
            String(localized: "Choose a Git repository.")
        case .objectiveRequired:
            String(localized: "Describe the outcome this relay should achieve.")
        case .acceptanceCriteriaRequired:
            String(localized: "Add at least one acceptance criterion on its own line.")
        }
    }
}

enum RelayIntakePresentation {
    static let stages = String(
        localized: "Scout → Implement → Verify → Review"
    )
    static let result = String(
        localized: "Preserved worktree, patch, and evidence"
    )
    static let schedulingDisclosure = String(
        localized:
            "The task is saved before a worker is scheduled. Relay stops at Ready for Your Inspection."
    )
}
