import Foundation
import RelayCore
import RelayEngine

enum RelayCoordinatorError: Error, Equatable {
    case unavailable(String)
    case anotherRelayIsActive
    case invalidRepository
}

/// The app-owned transition authority for the local Relay MVP.
///
/// It persists the task before provisioning a worktree and deliberately stops
/// at `.ready` while Parallax has no positively attested OS sandbox backend.
/// A ready task is therefore presented as blocked, never as running.
actor RelayCoordinator {
    private let eventStore: RelayTaskEventStore
    private let workspaceCustodian: RelayWorkspaceCustodian
    private let repositoryCustodian = RelayRepositoryCustodian()
    private var mutationInProgress = false

    init(applicationSupportURL: URL) {
        let parallaxRoot = applicationSupportURL
            .appendingPathComponent("Parallax", isDirectory: true)
        eventStore = RelayTaskEventStore(
            root: parallaxRoot
                .appendingPathComponent("Relay", isDirectory: true)
                .appendingPathComponent("Events", isDirectory: true)
        )
        workspaceCustodian = RelayWorkspaceCustodian(
            managedRootURL: parallaxRoot.appendingPathComponent(
                "RelayWorkspaces",
                isDirectory: true
            )
        )
    }

    func load() async throws -> [RelayProjection] {
        if mutationInProgress {
            return try await storedProjections()
        }
        mutationInProgress = true
        defer { mutationInProgress = false }
        return try await recoverAndLoad()
    }

    private func recoverAndLoad() async throws -> [RelayProjection] {
        var projections = try await storedProjections()
        for index in projections.indices {
            let projection = projections[index]
            guard projection.status == .draft else { continue }
            if let workspace = projection.workspace {
                projections[index] = try await eventStore.perform(
                    taskID: workspace.taskID,
                    command: .declareReady
                )
                continue
            }
            guard let intent = projection.workspaceProvisioningIntent else {
                continue
            }
            do {
                let custody: RelayWorkspaceCustody
                switch try workspaceCustodian.reconcile(intent: intent) {
                case .notProvisioned:
                    let admission = try repositoryCustodian.preflight(
                        repositoryURL: URL(
                            fileURLWithPath:
                                intent.sourceRepositoryRootPath,
                            isDirectory: true
                        )
                    )
                    custody = try workspaceCustodian.provision(
                        intent: intent,
                        repository: admission
                    )
                case let .prepared(existing):
                    custody = existing
                }
                _ = try await eventStore.perform(
                    taskID: intent.taskID,
                    command: .recordWorkspacePrepared(custody.identity)
                )
                projections[index] = try await eventStore.perform(
                    taskID: intent.taskID,
                    command: .declareReady
                )
            } catch {
                // The durable request remains the recovery authority. Any
                // ambiguous existing target is preserved and left blocked;
                // it is never terminalized, replaced, or cleaned up here.
                projections[index] = projection
            }
        }
        return Self.sorted(projections)
    }

    private func storedProjections() async throws -> [RelayProjection] {
        try await eventStore.prepare()
        var projections: [RelayProjection] = []
        for taskID in try await eventStore.taskIDs() {
            projections.append(
                try await eventStore.projection(taskID: taskID)
            )
        }
        return Self.sorted(projections)
    }

    private static func sorted(
        _ projections: [RelayProjection]
    ) -> [RelayProjection] {
        projections.sorted { lhs, rhs in
            (lhs.task?.createdAt ?? RelayInstant(rawValue: 0))
                > (rhs.task?.createdAt ?? RelayInstant(rawValue: 0))
        }
    }

    func create(_ draft: RelayIntakeDraft) async throws -> RelayProjection {
        guard !mutationInProgress else {
            throw RelayCoordinatorError.anotherRelayIsActive
        }
        mutationInProgress = true
        defer { mutationInProgress = false }
        let existing = try await recoverAndLoad()
        guard !existing.contains(where: Self.isActive) else {
            throw RelayCoordinatorError.anotherRelayIsActive
        }

        let now = RelayInstant(date: Date())
        let taskID = RelayTaskID()
        let definition = Self.definition(
            taskID: taskID,
            draft: draft,
            createdAt: now
        )

        // Task intent is durable before repository admission or worktree
        // creation. Any later failure becomes a durable terminal fact.
        _ = try await eventStore.perform(
            taskID: taskID,
            command: .createTask(definition),
            at: now
        )

        do {
            let repositoryURL = URL(
                fileURLWithPath: draft.repositoryPath,
                isDirectory: true
            )
            guard repositoryURL.path.hasPrefix("/") else {
                throw RelayCoordinatorError.invalidRepository
            }
            let admission = try repositoryCustodian.preflight(
                repositoryURL: repositoryURL
            )
            let provisioningIntent = try workspaceCustodian
                .makeProvisioningIntent(
                    taskID: taskID,
                    repository: admission,
                    requestedAt: now
                )
            _ = try await eventStore.perform(
                taskID: taskID,
                command: .requestWorkspaceProvisioning(
                    provisioningIntent
                ),
                at: now
            )
            let custody = try workspaceCustodian.provision(
                intent: provisioningIntent,
                repository: admission
            )
            _ = try await eventStore.perform(
                taskID: taskID,
                command: .recordWorkspacePrepared(custody.identity)
            )
            return try await eventStore.perform(
                taskID: taskID,
                command: .declareReady
            )
        } catch {
            // Once provisioning authority is durable, keep the task in draft
            // so load() can reconcile an absent or exact unknown outcome. If
            // the journal cannot be inspected, preserve that possibility.
            if let current = try? await eventStore.projection(taskID: taskID),
               current.workspaceProvisioningIntent == nil
            {
                let reason = "Relay setup failed: \(Self.publicFailure(error))"
                _ = try? await eventStore.perform(
                    taskID: taskID,
                    command: .failTask(reason: reason)
                )
            }
            throw error
        }
    }

    func stop(taskID: RelayTaskID) async throws -> RelayProjection {
        guard !mutationInProgress else {
            throw RelayCoordinatorError.unavailable(
                "Another Relay transition is already in progress."
            )
        }
        mutationInProgress = true
        defer { mutationInProgress = false }
        let projection = try await eventStore.projection(taskID: taskID)
        guard projection.activeAttemptID == nil else {
            throw RelayCoordinatorError.unavailable(
                "An active attempt must be interrupted and reaped first."
            )
        }
        return try await eventStore.perform(
            taskID: taskID,
            command: .cancelTask(
                reason: "Stopped by the user. The managed worktree is preserved."
            )
        )
    }

    private static func isActive(_ projection: RelayProjection) -> Bool {
        switch projection.status {
        case .failed, .cancelled, .delivered, .corrupt:
            false
        case .draft, .ready, .running, .waitingForUser, .localReady,
             .delivering:
            true
        }
    }

    private static func definition(
        taskID: RelayTaskID,
        draft: RelayIntakeDraft,
        createdAt: RelayInstant
    ) -> RelayTaskDefinition {
        let scout = RelayStageID()
        let implement = RelayStageID()
        let verify = RelayStageID()
        let review = RelayStageID()
        return RelayTaskDefinition(
            id: taskID,
            title: draft.title.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty
                ? draft.objective.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                : draft.title.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ),
            objective: draft.objective.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            acceptanceCriteria: draft.acceptanceCriteria,
            stages: [
                RelayStageDefinition(
                    id: scout,
                    name: "Scout",
                    role: .scout,
                    authority: .scout
                ),
                RelayStageDefinition(
                    id: implement,
                    name: "Implement",
                    role: .implementer,
                    authority: .implementer
                ),
                RelayStageDefinition(
                    id: verify,
                    name: "Verify",
                    role: .verifier,
                    authority: .verifier,
                    requiredEvidence: [.tests, .verification],
                    rejectionStageID: implement
                ),
                RelayStageDefinition(
                    id: review,
                    name: "Review",
                    role: .reviewer,
                    authority: .reviewer,
                    requiredEvidence: [.independentReview],
                    rejectionStageID: implement
                ),
            ],
            completionPolicy: RelayCompletionPolicy(
                requiredEvidence: [.tests, .verification, .independentReview]
            ),
            createdAt: createdAt
        )
    }

    private static func publicFailure(_ error: Error) -> String {
        switch error {
        case RelayCoordinatorError.anotherRelayIsActive:
            "another Relay is already active"
        case RelayCoordinatorError.invalidRepository:
            "the repository path is invalid"
        default:
            String(describing: error)
        }
    }
}
