import Foundation
import XCTest
@testable import Parallax

final class LaunchRequestCoordinatorTests: XCTestCase {
    func testConfirmationCanNeverRetargetRequestAToQueuedRequestB() {
        var coordinator = LaunchRequestCoordinator()
        let sceneID = fixedUUID("10000000-0000-4000-8000-000000000001")
        let requestA = request(
            sceneID: sceneID,
            requestID: fixedUUID(
                "20000000-0000-4000-8000-000000000001"
            ),
            applicationName: "Browser A",
            profileName: "Work A",
            argumentsText: "--target A"
        )
        let requestB = request(
            sceneID: sceneID,
            requestID: fixedUUID(
                "20000000-0000-4000-8000-000000000002"
            ),
            applicationName: "Browser B",
            profileName: "Work B",
            argumentsText: "--target B"
        )

        XCTAssertEqual(
            coordinator.submit(requestA, policy: .queue),
            .awaitingConfirmation(requestA.requestID)
        )
        XCTAssertEqual(
            coordinator.submit(requestB, policy: .queue),
            .queued(requestB.requestID, position: 1)
        )

        XCTAssertEqual(
            coordinator.confirm(
                sceneID: sceneID,
                requestID: requestB.requestID,
                currentTarget: .available(
                    applicationID: requestB.applicationID,
                    profileID: requestB.profileID,
                    configurationRevision: requestB.configurationRevision,
                    configurationFingerprint:
                        requestB.configurationFingerprint
                )
            ),
            .notPending(
                requestedID: requestB.requestID,
                activeRequestID: requestA.requestID
            )
        )

        let resolution = coordinator.confirm(
            sceneID: sceneID,
            requestID: requestA.requestID,
            currentTarget: availableTarget(for: requestA)
        )
        guard case .confirmed(let confirmed) = resolution else {
            return XCTFail("The exact pending request should confirm")
        }
        XCTAssertEqual(confirmed.requestID, requestA.requestID)
        XCTAssertEqual(confirmed.applicationName, "Browser A")
        XCTAssertEqual(confirmed.profileName, "Work A")
        XCTAssertEqual(
            confirmed.configurationSnapshot.argumentsText,
            "--target A"
        )
        XCTAssertEqual(
            coordinator.pendingConfirmation(in: sceneID)?.requestID,
            requestB.requestID
        )
    }

    func testConfigurationEditInvalidatesPendingRequestAndPromotesQueue() {
        var coordinator = LaunchRequestCoordinator()
        let sceneID = fixedUUID("10000000-0000-4000-8000-000000000002")
        let original = request(
            sceneID: sceneID,
            requestID: fixedUUID(
                "21000000-0000-4000-8000-000000000001"
            )
        )
        let queued = request(
            sceneID: sceneID,
            requestID: fixedUUID(
                "21000000-0000-4000-8000-000000000002"
            )
        )
        _ = coordinator.submit(original, policy: .queue)
        _ = coordinator.submit(queued, policy: .queue)

        let changedFingerprint = LaunchConfigurationFingerprint(
            digest: "changed"
        )
        let resolution = coordinator.confirm(
            sceneID: sceneID,
            requestID: original.requestID,
            currentTarget: .available(
                applicationID: original.applicationID,
                profileID: original.profileID,
                configurationRevision:
                    original.configurationRevision + 1,
                configurationFingerprint: changedFingerprint
            )
        )

        XCTAssertEqual(
            resolution,
            .invalidated(
                original.requestID,
                reason: .configurationChanged(
                    expectedRevision: original.configurationRevision,
                    currentRevision:
                        original.configurationRevision + 1
                )
            )
        )
        XCTAssertEqual(
            coordinator.status(for: original.requestID)?.state,
            .invalidated(
                .configurationChanged(
                    expectedRevision: original.configurationRevision,
                    currentRevision:
                        original.configurationRevision + 1
                )
            )
        )
        XCTAssertEqual(
            coordinator.pendingConfirmation(in: sceneID)?.requestID,
            queued.requestID
        )
        XCTAssertEqual(
            coordinator.status(for: queued.requestID)?.state,
            .awaitingConfirmation
        )
    }

    func testChangedSelectionCannotConfirmCapturedRequestAsAnotherTarget() {
        var coordinator = LaunchRequestCoordinator()
        let sceneID = fixedUUID("10000000-0000-4000-8000-000000000009")
        let requestA = request(
            sceneID: sceneID,
            requestID: fixedUUID(
                "26000000-0000-4000-8000-000000000001"
            )
        )
        let selectedApplicationB = fixedUUID(
            "30000000-0000-4000-8000-000000000099"
        )
        let selectedProfileB = fixedUUID(
            "50000000-0000-4000-8000-000000000099"
        )
        _ = coordinator.submit(requestA, policy: .rejectNew)

        XCTAssertEqual(
            coordinator.confirm(
                sceneID: sceneID,
                requestID: requestA.requestID,
                currentTarget: .available(
                    applicationID: selectedApplicationB,
                    profileID: selectedProfileB,
                    configurationRevision: requestA.configurationRevision,
                    configurationFingerprint:
                        requestA.configurationFingerprint
                )
            ),
            .invalidated(
                requestA.requestID,
                reason: .targetChanged(
                    expectedApplicationID: requestA.applicationID,
                    expectedProfileID: requestA.profileID,
                    currentApplicationID: selectedApplicationB,
                    currentProfileID: selectedProfileB
                )
            )
        )
    }

    func testRemovedApplicationAndProfileInvalidateWithActionableReasons() {
        let sceneID = fixedUUID("10000000-0000-4000-8000-000000000003")

        var applicationCoordinator = LaunchRequestCoordinator()
        let applicationRequest = request(
            sceneID: sceneID,
            requestID: fixedUUID(
                "22000000-0000-4000-8000-000000000001"
            ),
            applicationName: "Removed Browser",
            profileName: "Work"
        )
        _ = applicationCoordinator.submit(
            applicationRequest,
            policy: .rejectNew
        )
        XCTAssertEqual(
            applicationCoordinator.confirm(
                sceneID: sceneID,
                requestID: applicationRequest.requestID,
                currentTarget: .applicationRemoved
            ),
            .invalidated(
                applicationRequest.requestID,
                reason: .applicationRemoved(
                    applicationID: applicationRequest.applicationID,
                    applicationName: "Removed Browser"
                )
            )
        )

        var profileCoordinator = LaunchRequestCoordinator()
        let profileRequest = request(
            sceneID: sceneID,
            requestID: fixedUUID(
                "22000000-0000-4000-8000-000000000002"
            ),
            applicationName: "Browser",
            profileName: "Removed Work"
        )
        _ = profileCoordinator.submit(profileRequest, policy: .rejectNew)
        XCTAssertEqual(
            profileCoordinator.confirm(
                sceneID: sceneID,
                requestID: profileRequest.requestID,
                currentTarget: .profileRemoved
            ),
            .invalidated(
                profileRequest.requestID,
                reason: .profileRemoved(
                    profileID: profileRequest.profileID,
                    profileName: "Removed Work"
                )
            )
        )
    }

    func testPendingPolicyIsIndependentPerSceneAndCanReject() {
        var coordinator = LaunchRequestCoordinator()
        let firstScene = fixedUUID(
            "10000000-0000-4000-8000-000000000004"
        )
        let secondScene = fixedUUID(
            "10000000-0000-4000-8000-000000000005"
        )
        let first = request(
            sceneID: firstScene,
            requestID: fixedUUID(
                "23000000-0000-4000-8000-000000000001"
            )
        )
        let rejected = request(
            sceneID: firstScene,
            requestID: fixedUUID(
                "23000000-0000-4000-8000-000000000002"
            )
        )
        let independent = request(
            sceneID: secondScene,
            requestID: fixedUUID(
                "23000000-0000-4000-8000-000000000003"
            )
        )

        _ = coordinator.submit(first, policy: .rejectNew)
        XCTAssertEqual(
            coordinator.submit(rejected, policy: .rejectNew),
            .rejected(
                rejected.requestID,
                reason: .sceneAlreadyHasPendingConfirmation(
                    activeRequestID: first.requestID
                )
            )
        )
        XCTAssertEqual(
            coordinator.submit(independent, policy: .rejectNew),
            .awaitingConfirmation(independent.requestID)
        )
        XCTAssertEqual(
            coordinator.pendingConfirmation(in: firstScene)?.requestID,
            first.requestID
        )
        XCTAssertEqual(
            coordinator.pendingConfirmation(in: secondScene)?.requestID,
            independent.requestID
        )
    }

    func testCancellationIsRequestScopedAndPromotesNextConfirmation() {
        var coordinator = LaunchRequestCoordinator()
        let sceneID = fixedUUID("10000000-0000-4000-8000-000000000010")
        let first = request(
            sceneID: sceneID,
            requestID: fixedUUID(
                "27000000-0000-4000-8000-000000000001"
            )
        )
        let second = request(
            sceneID: sceneID,
            requestID: fixedUUID(
                "27000000-0000-4000-8000-000000000002"
            )
        )
        _ = coordinator.submit(first, policy: .queue)
        _ = coordinator.submit(second, policy: .queue)

        XCTAssertEqual(
            coordinator.cancelConfirmation(
                sceneID: sceneID,
                requestID: first.requestID
            ),
            .cancelled(first.requestID)
        )
        XCTAssertEqual(
            coordinator.status(for: first.requestID)?.state,
            .cancelled
        )
        XCTAssertEqual(
            coordinator.pendingConfirmation(in: sceneID)?.requestID,
            second.requestID
        )
    }

    func testReverseOrderCompletionsCannotOverwriteNewerAttempt() {
        var coordinator = LaunchRequestCoordinator()
        let sceneID = fixedUUID("10000000-0000-4000-8000-000000000006")
        let profileID = fixedUUID("50000000-0000-4000-8000-000000000001")
        let older = request(
            sceneID: sceneID,
            requestID: fixedUUID(
                "24000000-0000-4000-8000-000000000001"
            ),
            profileID: profileID
        )
        let newer = request(
            sceneID: sceneID,
            requestID: fixedUUID(
                "24000000-0000-4000-8000-000000000002"
            ),
            profileID: profileID
        )

        _ = coordinator.submit(older, policy: .queue)
        _ = coordinator.confirm(
            sceneID: sceneID,
            requestID: older.requestID,
            currentTarget: availableTarget(for: older)
        )
        XCTAssertTrue(
            coordinator.updateStatus(
                requestID: older.requestID,
                state: .running
            )
        )

        _ = coordinator.submit(newer, policy: .queue)
        XCTAssertEqual(
            coordinator.visibleStatus(
                sceneID: sceneID,
                profileID: profileID
            )?.state,
            .awaitingConfirmation,
            "Starting a new attempt must clear the older running success."
        )
        _ = coordinator.confirm(
            sceneID: sceneID,
            requestID: newer.requestID,
            currentTarget: availableTarget(for: newer)
        )
        _ = coordinator.updateStatus(
            requestID: newer.requestID,
            state: .failed("New launch failed")
        )
        _ = coordinator.updateStatus(
            requestID: older.requestID,
            state: .terminated
        )

        XCTAssertEqual(
            coordinator.visibleStatus(
                sceneID: sceneID,
                profileID: profileID
            )?.requestID,
            newer.requestID
        )
        XCTAssertEqual(
            coordinator.visibleStatus(
                sceneID: sceneID,
                profileID: profileID
            )?.state,
            .failed("New launch failed")
        )
        XCTAssertEqual(
            coordinator.status(for: older.requestID)?.state,
            .terminated,
            "Older request history remains request-scoped."
        )
    }

    func testStatusNeverAppearsUnderUnrelatedProfileOrScene() {
        var coordinator = LaunchRequestCoordinator()
        let sceneA = fixedUUID("10000000-0000-4000-8000-000000000007")
        let sceneB = fixedUUID("10000000-0000-4000-8000-000000000008")
        let profileA = fixedUUID("50000000-0000-4000-8000-000000000002")
        let profileB = fixedUUID("50000000-0000-4000-8000-000000000003")
        let requestA = request(
            sceneID: sceneA,
            requestID: fixedUUID(
                "25000000-0000-4000-8000-000000000001"
            ),
            profileID: profileA
        )
        let requestB = request(
            sceneID: sceneA,
            requestID: fixedUUID(
                "25000000-0000-4000-8000-000000000002"
            ),
            profileID: profileB
        )
        _ = coordinator.submit(requestA, policy: .queue)
        _ = coordinator.submit(requestB, policy: .queue)
        _ = coordinator.updateStatus(
            requestID: requestA.requestID,
            state: .failed("A failed")
        )

        XCTAssertEqual(
            coordinator.visibleStatus(
                sceneID: sceneA,
                profileID: profileA
            )?.requestID,
            requestA.requestID
        )
        XCTAssertEqual(
            coordinator.visibleStatus(
                sceneID: sceneA,
                profileID: profileB
            )?.requestID,
            requestB.requestID
        )
        XCTAssertNil(
            coordinator.visibleStatus(
                sceneID: sceneB,
                profileID: profileA
            )
        )
    }

    private func request(
        sceneID: UUID,
        requestID: UUID,
        applicationID: UUID = UUID(
            uuid: (
                0x30, 0, 0, 0, 0, 0x00, 0x40, 0,
                0x80, 0, 0, 0, 0, 0, 0, 1
            )
        ),
        profileID: UUID = UUID(
            uuid: (
                0x50, 0, 0, 0, 0, 0x00, 0x40, 0,
                0x80, 0, 0, 0, 0, 0, 0, 1
            )
        ),
        applicationName: String = "Browser",
        profileName: String = "Work",
        argumentsText: String = "--target work"
    ) -> ImmutableLaunchRequest {
        let source = LaunchConfigurationSource(
            requestID: requestID,
            applicationID: applicationID,
            applicationStorageID: fixedUUID(
                "40000000-0000-4000-8000-000000000001"
            ),
            profileID: profileID,
            profileStorageID: fixedUUID(
                "60000000-0000-4000-8000-000000000001"
            ),
            configurationRevision: 7,
            applicationURL: URL(
                fileURLWithPath: "/Applications/Browser.app",
                isDirectory: true
            ),
            expectedBundleIdentifier: "example.browser",
            configuredBaseRoot: "/tmp/parallax",
            argumentsText: argumentsText,
            environmentText: "MODE=work",
            isolationOwnership: .explicit,
            childEnvironmentPolicy: .safeDefault,
            sensitiveEnvironmentKeys: []
        )
        return ImmutableLaunchRequest(
            sceneID: sceneID,
            applicationName: applicationName,
            profileName: profileName,
            configurationSnapshot: source,
            configurationFingerprint: LaunchConfigurationFingerprint(
                digest: "\(requestID.uuidString)-fingerprint"
            )
        )
    }

    private func availableTarget(
        for request: ImmutableLaunchRequest
    ) -> LaunchRequestCurrentTarget {
        .available(
            applicationID: request.applicationID,
            profileID: request.profileID,
            configurationRevision: request.configurationRevision,
            configurationFingerprint: request.configurationFingerprint
        )
    }

    private func fixedUUID(_ value: String) -> UUID {
        UUID(uuidString: value) ?? UUID()
    }
}
