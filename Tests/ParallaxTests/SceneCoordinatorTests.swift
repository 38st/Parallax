import Foundation
import XCTest
@testable import Parallax

@MainActor
final class SceneCoordinatorTests: XCTestCase {
    func testTwoScenesKeepSelectionPresentationAndStatusIndependent() {
        let library = makeLibrary()
        let first = SceneCoordinator(sceneID: UUID())
        let second = SceneCoordinator(sceneID: UUID())
        let firstApp = library[0]
        let secondApp = library[1]
        let firstProfile = firstApp.profiles[0]
        let secondProfile = secondApp.profiles[0]

        first.selectApplication(firstApp.id, in: library)
        first.selectProfile(firstProfile.id, in: library)
        second.selectApplication(secondApp.id, in: library)
        second.selectProfile(secondProfile.id, in: library)

        let firstDialogID = UUID()
        let secondImporterID = UUID()
        first.presentDialog(
            SceneDialogPresentation(
                id: firstDialogID,
                kind: .launchConfirmation,
                requestID: UUID()
            )
        )
        second.presentImporter(
            SceneImporterPresentation(
                id: secondImporterID,
                kind: .library
            )
        )
        first.setTransientStatus(
            SceneTransientStatus(
                id: UUID(),
                kind: .progress,
                message: "Launching",
                applicationID: firstApp.id,
                profileID: firstProfile.id,
                requestID: UUID()
            )
        )

        XCTAssertEqual(first.selectedApplicationID, firstApp.id)
        XCTAssertEqual(first.selectedProfileID, firstProfile.id)
        XCTAssertEqual(second.selectedApplicationID, secondApp.id)
        XCTAssertEqual(second.selectedProfileID, secondProfile.id)
        XCTAssertEqual(first.presentedDialog?.id, firstDialogID)
        XCTAssertNil(second.presentedDialog)
        XCTAssertNil(first.presentedImporter)
        XCTAssertEqual(second.presentedImporter?.id, secondImporterID)
        XCTAssertNotNil(first.transientStatus)
        XCTAssertNil(second.transientStatus)
    }

    func testApplicationSwitchRestoresLastProfileAndPreservesExplicitNil() {
        let library = makeLibrary()
        let coordinator = SceneCoordinator()
        let firstApp = library[0]
        let secondApp = library[1]
        let firstProfile = firstApp.profiles[1]

        coordinator.selectApplication(firstApp.id, in: library)
        XCTAssertNil(coordinator.selectedProfileID)
        coordinator.selectProfile(firstProfile.id, in: library)

        coordinator.selectApplication(secondApp.id, in: library)
        XCTAssertNil(coordinator.selectedProfileID)
        coordinator.selectApplication(firstApp.id, in: library)
        XCTAssertEqual(coordinator.selectedProfileID, firstProfile.id)

        coordinator.selectProfile(nil, in: library)
        coordinator.selectApplication(secondApp.id, in: library)
        coordinator.selectApplication(firstApp.id, in: library)

        XCTAssertNil(coordinator.selectedProfileID)
        XCTAssertEqual(
            coordinator.rememberedProfileSelection(for: firstApp.id),
            .explicitlyNone
        )
    }

    func testSelectingProfileFromAnotherApplicationCannotCreateStalePair() {
        let library = makeLibrary()
        let coordinator = SceneCoordinator()
        let firstApp = library[0]
        let otherProfile = library[1].profiles[0]

        coordinator.selectApplication(firstApp.id, in: library)
        coordinator.selectProfile(otherProfile.id, in: library)

        XCTAssertEqual(coordinator.selectedApplicationID, firstApp.id)
        XCTAssertNil(coordinator.selectedProfileID)
        XCTAssertEqual(
            coordinator.rememberedProfileSelection(for: firstApp.id),
            .explicitlyNone
        )
    }

    func testSharedLibraryChangesSanitizeOnlyInvalidSelection() {
        var library = makeLibrary()
        let coordinator = SceneCoordinator()
        let selectedApp = library[0]
        let selectedProfile = selectedApp.profiles[0]
        let dialog = SceneDialogPresentation(
            id: UUID(),
            kind: .destructiveAction,
            requestID: UUID()
        )
        let importer = SceneImporterPresentation(
            id: UUID(),
            kind: .application
        )
        let status = SceneTransientStatus(
            id: UUID(),
            kind: .failure,
            message: "Operation failed",
            applicationID: selectedApp.id,
            profileID: selectedProfile.id,
            requestID: UUID()
        )

        coordinator.selectApplication(selectedApp.id, in: library)
        coordinator.selectProfile(selectedProfile.id, in: library)
        coordinator.presentDialog(dialog)
        coordinator.presentImporter(importer)
        coordinator.setPendingRequest(UUID(), for: .destructive)
        coordinator.setTransientStatus(status)

        library[0].displayName = "Renamed Shared App"
        library[1].profiles.append(LaunchProfile(name: "Added Elsewhere"))
        coordinator.synchronize(with: library)

        XCTAssertEqual(coordinator.selectedApplicationID, selectedApp.id)
        XCTAssertEqual(coordinator.selectedProfileID, selectedProfile.id)
        XCTAssertEqual(coordinator.presentedDialog, dialog)
        XCTAssertEqual(coordinator.presentedImporter, importer)
        XCTAssertEqual(coordinator.transientStatus, status)
        XCTAssertNotNil(coordinator.pendingRequestID(for: .destructive))

        library[0].profiles.removeAll { $0.id == selectedProfile.id }
        coordinator.synchronize(with: library)
        XCTAssertEqual(coordinator.selectedApplicationID, selectedApp.id)
        XCTAssertNil(coordinator.selectedProfileID)
        XCTAssertEqual(coordinator.presentedDialog, dialog)
        XCTAssertEqual(coordinator.transientStatus, status)

        library.removeAll { $0.id == selectedApp.id }
        coordinator.synchronize(with: library)
        XCTAssertNil(coordinator.selectedApplicationID)
        XCTAssertNil(coordinator.selectedProfileID)
        XCTAssertNil(
            coordinator.rememberedProfileSelection(for: selectedApp.id)
        )
        XCTAssertEqual(coordinator.presentedDialog, dialog)
    }

    func testFocusedRoutingUsesFocusOnlyWhenNoOriginIsCaptured() {
        let first = SceneCoordinator()
        let second = SceneCoordinator()
        let router = FocusedSceneRouter()
        router.register(first.sceneID)
        router.register(second.sceneID)
        router.setFocusedScene(first.sceneID)

        XCTAssertEqual(
            router.targetSceneID(
                for: SceneRoutingRequest(originatingSceneID: nil)
            ),
            first.sceneID
        )

        router.setFocusedScene(second.sceneID)
        XCTAssertEqual(
            router.targetSceneID(
                for: SceneRoutingRequest(
                    originatingSceneID: first.sceneID
                )
            ),
            first.sceneID
        )
        XCTAssertEqual(
            router.targetSceneID(
                for: SceneRoutingRequest(originatingSceneID: nil)
            ),
            second.sceneID
        )
    }

    func testMissingOriginNeverRetargetsConfirmationToFocusedScene() {
        let origin = SceneCoordinator()
        let focused = SceneCoordinator()
        let router = FocusedSceneRouter()
        router.register(origin.sceneID)
        router.register(focused.sceneID)
        router.setFocusedScene(focused.sceneID)
        let request = SceneRoutingRequest(
            originatingSceneID: origin.sceneID
        )

        XCTAssertEqual(router.targetSceneID(for: request), origin.sceneID)
        router.unregister(origin.sceneID)

        XCTAssertNil(router.targetSceneID(for: request))
        XCTAssertEqual(
            router.targetSceneID(
                for: SceneRoutingRequest(originatingSceneID: nil)
            ),
            focused.sceneID
        )
    }

    private func makeLibrary() -> [ManagedApplication] {
        [
            ManagedApplication(
                displayName: "First",
                appPath: "/Applications/First.app",
                profiles: [
                    LaunchProfile(name: "First A"),
                    LaunchProfile(name: "First B"),
                ]
            ),
            ManagedApplication(
                displayName: "Second",
                appPath: "/Applications/Second.app",
                profiles: [
                    LaunchProfile(name: "Second A")
                ]
            ),
        ]
    }
}
