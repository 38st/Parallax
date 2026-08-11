import Foundation
@testable import Parallax
import RelayCore
import RelayEngine
import XCTest

final class RelayCoordinatorTests: XCTestCase {
    func testCreationIsDurableBeforeProvisionAndStopsBlockedAtReady()
        async throws
    {
        let fixture = try RelayCoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = RelayCoordinator(
            applicationSupportURL: fixture.applicationSupportURL
        )

        let projection = try await coordinator.create(fixture.draft)

        XCTAssertEqual(
            projection.status,
            .ready,
            projection.failureReason ?? "No failure reason"
        )
        XCTAssertNotNil(projection.workspace)
        XCTAssertNotNil(projection.workspaceProvisioningIntent)
        XCTAssertEqual(
            projection.workspaceProvisioningIntent?.targetWorkspacePath,
            projection.workspace?.repositoryRootPath
        )
        XCTAssertEqual(
            projection.workspace?.workspaceDigest,
            projection.currentWorkspaceDigest
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: projection.workspace?.repositoryRootPath ?? ""
            )
        )
        let recovered = try await coordinator.load()
        XCTAssertEqual(recovered, [projection])
        let presentation = try XCTUnwrap(
            RelayPresentationAdapter.make(projection)
        )
        XCTAssertEqual(presentation.summary.executionStatus, .blocked)
        if case .blocked = presentation.recovery {
            // Expected: no unsupported execution is started optimistically.
        } else {
            XCTFail("A ready Relay must expose the unavailable sandbox gate.")
        }
    }

    func testOneActiveRelayLimitIsEnforcedBeforeSecondTaskIsPersisted()
        async throws
    {
        let fixture = try RelayCoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = RelayCoordinator(
            applicationSupportURL: fixture.applicationSupportURL
        )
        _ = try await coordinator.create(fixture.draft)

        do {
            _ = try await coordinator.create(fixture.draft)
            XCTFail("A second active Relay must be refused.")
        } catch let error as RelayCoordinatorError {
            XCTAssertEqual(error, .anotherRelayIsActive)
        }

        let recovered = try await coordinator.load()
        XCTAssertEqual(recovered.count, 1)
    }

    func testStopPreservesManagedWorktreeAndRecordsTerminalState()
        async throws
    {
        let fixture = try RelayCoordinatorFixture()
        defer { fixture.remove() }
        let coordinator = RelayCoordinator(
            applicationSupportURL: fixture.applicationSupportURL
        )
        let created = try await coordinator.create(fixture.draft)
        let workspacePath = try XCTUnwrap(
            created.workspace?.repositoryRootPath
        )
        let taskID = try XCTUnwrap(created.task?.id)

        let stopped = try await coordinator.stop(taskID: taskID)

        XCTAssertEqual(stopped.status, .cancelled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspacePath))
        let recovered = try await coordinator.load()
        XCTAssertEqual(recovered.first?.status, .cancelled)
    }

    func testLoadCompletesDurablyRequestedAbsentProvisioning() async throws {
        let fixture = try RelayCoordinatorFixture()
        defer { fixture.remove() }
        let pending = try await fixture.seedRequestedProvisioning(
            createWorktree: false
        )
        let coordinator = RelayCoordinator(
            applicationSupportURL: fixture.applicationSupportURL
        )

        let recovered = try await coordinator.load()

        let projection = try XCTUnwrap(recovered.first)
        XCTAssertEqual(
            projection.status,
            .ready,
            projection.failureReason ?? "No failure reason"
        )
        XCTAssertEqual(
            projection.workspaceProvisioningIntent,
            pending.intent
        )
        XCTAssertEqual(
            projection.workspace?.repositoryRootPath,
            pending.intent.targetWorkspacePath
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: pending.intent.targetWorkspacePath
            )
        )
    }

    func testLoadAdoptsExactUnknownProvisioningOutcome() async throws {
        let fixture = try RelayCoordinatorFixture()
        defer { fixture.remove() }
        let pending = try await fixture.seedRequestedProvisioning(
            createWorktree: true
        )
        let createdWorkspace = try XCTUnwrap(pending.workspace)
        let coordinator = RelayCoordinator(
            applicationSupportURL: fixture.applicationSupportURL
        )

        let recovered = try await coordinator.load()

        let projection = try XCTUnwrap(recovered.first)
        XCTAssertEqual(projection.status, .ready)
        XCTAssertEqual(
            projection.workspace?.repositoryRootPath,
            createdWorkspace.workspaceURL.path
        )
        XCTAssertEqual(
            projection.workspace?.repositoryFileIdentity,
            createdWorkspace.workspaceFileIdentity
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: createdWorkspace.workspaceURL.path
            )
        )
    }

    func testLoadPreservesAmbiguousOutcomeWithoutTerminalizing()
        async throws
    {
        let fixture = try RelayCoordinatorFixture()
        defer { fixture.remove() }
        let pending = try await fixture.seedRequestedProvisioning(
            createWorktree: false
        )
        let target = URL(
            fileURLWithPath: pending.intent.targetWorkspacePath,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: target,
            withIntermediateDirectories: false
        )
        let sentinel = target.appendingPathComponent("preserve.txt")
        try Data("preserve\n".utf8).write(to: sentinel)
        let coordinator = RelayCoordinator(
            applicationSupportURL: fixture.applicationSupportURL
        )

        let recovered = try await coordinator.load()

        let projection = try XCTUnwrap(recovered.first)
        XCTAssertEqual(projection.status, .draft)
        XCTAssertEqual(
            projection.workspaceProvisioningIntent,
            pending.intent
        )
        XCTAssertNil(projection.workspace)
        XCTAssertEqual(
            try Data(contentsOf: sentinel),
            Data("preserve\n".utf8)
        )
    }
}

private final class RelayCoordinatorFixture {
    struct PendingProvisioning {
        let intent: RelayWorkspaceProvisioningIntent
        let workspace: RelayWorkspaceCustody?
    }

    let root: URL
    let applicationSupportURL: URL
    let repositoryURL: URL

    var draft: RelayIntakeDraft {
        RelayIntakeDraft(
            title: "Relay fixture",
            repositoryPath: repositoryURL.path,
            objective: "Change the fixture safely.",
            acceptanceCriteriaText: "Tests pass\nReview approves"
        )
    }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "parallax-relay-coordinator-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        applicationSupportURL = root.appendingPathComponent(
            "ApplicationSupport",
            isDirectory: true
        )
        repositoryURL = root.appendingPathComponent(
            "Source",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: applicationSupportURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: repositoryURL,
            withIntermediateDirectories: true
        )
        try runGit(["init", "--initial-branch=main"])
        try runGit(["config", "user.name", "Relay Fixture"])
        try runGit(["config", "user.email", "relay@example.invalid"])
        try Data("fixture\n".utf8).write(
            to: repositoryURL.appendingPathComponent("fixture.txt")
        )
        try runGit(["add", "fixture.txt"])
        try runGit(["commit", "-m", "fixture"])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func seedRequestedProvisioning(
        createWorktree: Bool
    ) async throws -> PendingProvisioning {
        let taskID = RelayTaskID()
        let instant = RelayInstant(rawValue: 1_000)
        let stageID = RelayStageID()
        let definition = RelayTaskDefinition(
            id: taskID,
            title: "Recovery fixture",
            objective: "Recover an exact durable provisioning request.",
            acceptanceCriteria: [
                RelayAcceptanceCriterion(
                    id: RelayAcceptanceCriterionID(),
                    statement: "The exact workspace is recovered.",
                    requiredEvidenceKinds: [.verification]
                )
            ],
            stages: [
                RelayStageDefinition(
                    id: stageID,
                    name: "Implement",
                    role: .implementer,
                    authority: .implementer
                )
            ],
            createdAt: instant
        )
        let parallaxRoot = applicationSupportURL.appendingPathComponent(
            "Parallax",
            isDirectory: true
        )
        let eventStore = RelayTaskEventStore(
            root: parallaxRoot
                .appendingPathComponent("Relay", isDirectory: true)
                .appendingPathComponent("Events", isDirectory: true)
        )
        try await eventStore.prepare()
        _ = try await eventStore.perform(
            taskID: taskID,
            command: .createTask(definition),
            at: instant
        )
        let admission = try RelayRepositoryCustodian().preflight(
            repositoryURL: repositoryURL
        )
        let custodian = RelayWorkspaceCustodian(
            managedRootURL: parallaxRoot.appendingPathComponent(
                "RelayWorkspaces",
                isDirectory: true
            )
        )
        let intent = try custodian.makeProvisioningIntent(
            taskID: taskID,
            repository: admission,
            requestedAt: instant
        )
        _ = try await eventStore.perform(
            taskID: taskID,
            command: .requestWorkspaceProvisioning(intent),
            at: instant
        )
        let workspace = createWorktree
            ? try custodian.provision(intent: intent, repository: admission)
            : nil
        return PendingProvisioning(intent: intent, workspace: workspace)
    }

    private func runGit(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = repositoryURL
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            throw NSError(
                domain: "RelayCoordinatorFixture",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        String(decoding: bytes, as: UTF8.self)
                ]
            )
        }
    }
}
