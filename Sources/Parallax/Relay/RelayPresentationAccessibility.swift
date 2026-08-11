import Foundation

enum RelayAccessibilityIdentifier {
    static let workspace = "relay.workspace"
    static let newRelay = "relay.new"
    static let intake = "relay.intake"
    static let intakeTitle = "relay.intake.title"
    static let intakeRepository = "relay.intake.repository"
    static let intakeChooseRepository = "relay.intake.choose-repository"
    static let intakeObjective = "relay.intake.objective"
    static let intakeCriteria = "relay.intake.acceptance-criteria"
    static let intakeStart = "relay.intake.start"
    static let intakeCancel = "relay.intake.cancel"
    static let detailSection = "relay.detail.section"

    static func task(_ id: UUID) -> String {
        scoped("task", id.uuidString)
    }

    static func executionStatus(_ id: UUID) -> String {
        scoped("execution-status", id.uuidString)
    }

    static func deliveryStatus(_ id: UUID) -> String {
        scoped("delivery-status", id.uuidString)
    }

    static func stage(_ id: UUID) -> String {
        scoped("stage", id.uuidString)
    }

    static func attempt(_ id: UUID) -> String {
        scoped("attempt", id.uuidString)
    }

    static func baton(_ id: UUID) -> String {
        scoped("baton", id.uuidString)
    }

    static func gate(_ id: UUID) -> String {
        scoped("gate", id.uuidString)
    }

    static func approveGate(_ id: UUID) -> String {
        scoped("gate.approve", id.uuidString)
    }

    static func denyGate(_ id: UUID) -> String {
        scoped("gate.deny", id.uuidString)
    }

    static func finding(_ id: String) -> String {
        scoped("finding", id)
    }

    static func evidence(_ id: String) -> String {
        scoped("evidence", id)
    }

    static func pause(_ id: UUID) -> String {
        scoped("pause", id.uuidString)
    }

    static func resume(_ id: UUID) -> String {
        scoped("resume", id.uuidString)
    }

    static func stop(_ id: UUID) -> String {
        scoped("stop", id.uuidString)
    }

    static func retry(_ id: UUID) -> String {
        scoped("retry", id.uuidString)
    }

    static func recoveryAction(_ id: UUID) -> String {
        scoped("recovery", id.uuidString)
    }

    static func completion(_ id: UUID) -> String {
        scoped("completion", id.uuidString)
    }

    private static func scoped(_ component: String, _ rawID: String) -> String {
        let safeID = rawID.lowercased().map { character in
            character.isLetter || character.isNumber || character == "-"
                ? character
                : "-"
        }
        return "relay.\(component).\(String(safeID))"
    }
}

enum RelayAccessibilityContract {
    static func taskTraversal(
        _ task: RelayTaskPresentation
    ) -> [String] {
        var identifiers = [
            RelayAccessibilityIdentifier.task(task.id),
            RelayAccessibilityIdentifier.executionStatus(task.id),
            RelayAccessibilityIdentifier.deliveryStatus(task.id),
        ]
        if task.summary.executionStatus == .running {
            identifiers.append(RelayAccessibilityIdentifier.pause(task.id))
        }
        if task.summary.executionStatus == .paused {
            identifiers.append(RelayAccessibilityIdentifier.resume(task.id))
        }
        if [.failed, .interrupted, .stalled].contains(
            task.summary.executionStatus
        ) {
            identifiers.append(RelayAccessibilityIdentifier.retry(task.id))
        }
        identifiers += task.pendingGates.flatMap {
            [
                RelayAccessibilityIdentifier.gate($0.id),
                RelayAccessibilityIdentifier.approveGate($0.id),
                RelayAccessibilityIdentifier.denyGate($0.id),
            ]
        }
        identifiers += task.stages.map {
            RelayAccessibilityIdentifier.stage($0.id)
        }
        identifiers += task.findings.map {
            RelayAccessibilityIdentifier.finding($0.id)
        }
        identifiers += task.evidence.map {
            RelayAccessibilityIdentifier.evidence($0.id)
        }
        return identifiers
    }
}
