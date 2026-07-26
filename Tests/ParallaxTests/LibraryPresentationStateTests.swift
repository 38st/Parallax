import Foundation
import SwiftUI
import XCTest
@testable import Parallax

final class LibraryPresentationStateTests: XCTestCase {
    func testAppearanceMapsConsistentlyForEveryScene() {
        XCTAssertNil(appColorScheme(for: .system))
        XCTAssertEqual(appColorScheme(for: .light), .light)
        XCTAssertEqual(appColorScheme(for: .dark), .dark)
    }

    @MainActor
    func testNewLibraryFailureClearsStaleOperationSuccess() {
        let store = LibraryStore(
            persistence: LibraryPersistence(
                applicationSupportURL:
                    FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
            )
        )
        store.launchStatusMessage = "Old success"

        store.errorMessage = "New failure"

        XCTAssertNil(store.libraryOperationStatusMessage)
        XCTAssertEqual(store.errorMessage, "New failure")
    }

    func testEmptyLoadedLibraryIsDistinctFromLoading() {
        XCTAssertEqual(
            classify(loadState: .loading),
            .loading
        )
        XCTAssertEqual(
            classify(loadState: .loaded),
            .emptyLibrary
        )
    }

    func testApplicationsWithExplicitNilSelectionDoNotFallBackToFirst() {
        let application = makeApplication(profileCount: 1)

        XCTAssertEqual(
            classify(
                applications: [application],
                selectedApplicationID: nil,
                selectedProfileID: nil
            ),
            .noApplicationSelected
        )
    }

    func testSelectedApplicationWithNoProfilesHasCreationState() {
        let application = makeApplication(profileCount: 0)

        XCTAssertEqual(
            classify(
                applications: [application],
                selectedApplicationID: application.id,
                selectedProfileID: nil
            ),
            .selectedApplicationHasNoProfiles(
                applicationID: application.id
            )
        )
    }

    func testExistingProfilesWithExplicitNilSelectionHaveSelectionState() {
        let application = makeApplication(profileCount: 2)

        XCTAssertEqual(
            classify(
                applications: [application],
                selectedApplicationID: application.id,
                selectedProfileID: nil
            ),
            .noProfileSelected(applicationID: application.id)
        )
    }

    func testValidProfileSelectionProducesContentState() throws {
        let application = makeApplication(profileCount: 1)
        let profile = try XCTUnwrap(application.profiles.first)

        XCTAssertEqual(
            classify(
                applications: [application],
                selectedApplicationID: application.id,
                selectedProfileID: profile.id
            ),
            .profileSelected(
                applicationID: application.id,
                profileID: profile.id
            )
        )
    }

    func testStaleApplicationAndProfileSelectionsNeverResolveAnotherItem() {
        let application = makeApplication(profileCount: 1)

        XCTAssertEqual(
            classify(
                applications: [application],
                selectedApplicationID: UUID(),
                selectedProfileID: application.profiles.first?.id
            ),
            .noApplicationSelected
        )
        XCTAssertEqual(
            classify(
                applications: [application],
                selectedApplicationID: application.id,
                selectedProfileID: UUID()
            ),
            .noProfileSelected(applicationID: application.id)
        )
    }

    func testUnavailableLibraryStatesRemainDistinctAndKeepRecoveryCapability() {
        XCTAssertEqual(
            classify(
                loadState: .recoveryRequired(
                    message: "Corrupt library",
                    canAttemptRecovery: true
                )
            ),
            .recoveryRequired(
                message: "Corrupt library",
                canAttemptRecovery: true
            )
        )
        XCTAssertEqual(
            classify(
                loadState: .readOnlyNewerVersion(
                    message: "Version 99",
                    canAttemptRecovery: false
                )
            ),
            .readOnlyNewerVersion(
                message: "Version 99",
                canAttemptRecovery: false
            )
        )
        XCTAssertEqual(
            classify(
                loadState: .unrecoverable(
                    message: "No valid document",
                    canAttemptRecovery: true
                )
            ),
            .unrecoverable(
                message: "No valid document",
                canAttemptRecovery: true
            )
        )
    }

    private func classify(
        loadState: LibraryPresentationLoadState = .loaded,
        applications: [ManagedApplication] = [],
        selectedApplicationID: UUID? = nil,
        selectedProfileID: UUID? = nil
    ) -> LibraryPresentationState {
        LibraryPresentationClassifier.classify(
            loadState: loadState,
            applications: applications,
            selectedApplicationID: selectedApplicationID,
            selectedProfileID: selectedProfileID
        )
    }

    private func makeApplication(
        profileCount: Int
    ) -> ManagedApplication {
        ManagedApplication(
            displayName: "Browser",
            appPath: "/Applications/Browser.app",
            profiles: (0..<profileCount).map { index in
                LaunchProfile(name: "Profile \(index + 1)")
            }
        )
    }
}
