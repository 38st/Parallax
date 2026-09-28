import Foundation
import XCTest
@testable import Parallax

final class LaunchPresentationAuditRegressionTests: XCTestCase {
    @MainActor
    func testChooseApplicationUsesSceneBindingWithoutApplicationOrTabSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = AppSettings()
        settings.defaultBaseStoragePath = root.appendingPathComponent("Profiles").path
        let store = LibraryStore(persistence: LibraryPersistence(applicationSupportURL: root),
                                 profileActivityRegistry: ProfileActivityRegistry(), settings: settings)
        let presentation = ContentView.applicationImporterPresentation(for: store)
        XCTAssertNil(store.selectedApplicationID)
        XCTAssertFalse(presentation.wrappedValue)
        store.beginAddingApplication()
        XCTAssertTrue(presentation.wrappedValue)
        XCTAssertNil(store.selectedApplicationID)
        presentation.wrappedValue = false
        XCTAssertFalse(store.isShowingAppImporter)
    }

    @MainActor
    func testApplicationImporterStateIsSharedBySceneBindingsAndIsolatedBetweenScenes() throws {
        let first = try PresetIntegrationFixture(preset: .custom)
        let second = try PresetIntegrationFixture(preset: .custom)
        defer { first.remove(); second.remove() }
        first.store.selectedApplicationID = nil
        let controlCenterBinding = ContentView.applicationImporterPresentation(for: first.store)
        let localSpacesBinding = ContentView.applicationImporterPresentation(for: first.store)
        let otherSceneBinding = ContentView.applicationImporterPresentation(for: second.store)
        first.store.beginAddingApplication()
        XCTAssertTrue(controlCenterBinding.wrappedValue)
        XCTAssertTrue(localSpacesBinding.wrappedValue)
        XCTAssertFalse(otherSceneBinding.wrappedValue)
        XCTAssertNil(first.store.selectedApplicationID)
        localSpacesBinding.wrappedValue = false
        XCTAssertFalse(controlCenterBinding.wrappedValue)
    }

    func testRepeatedDiagnosticWarningsUseUniqueListIdentities() throws {
        let diagnostic = try XCTUnwrap(LaunchEnvironmentParser.parse("MODE=one\nMODE=two").diagnostics.first)
        let rows = LaunchWarningListItem.rows([diagnostic.message, diagnostic.message])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].message, rows[1].message)
        XCTAssertNotEqual(rows[0].id, rows[1].id)
    }

    func testUnobservedDataNoticeIsNeutralAndOnlyAppliesWhileRunning() {
        let running = LaunchStatusPresenter.presentation(applicationName: "Fixture", profileName: "Space",
            state: .running, openingDisposition: nil, isolationActivityUnobserved: true)
        XCTAssertEqual(running.tone, .success)
        XCTAssertEqual(running.listSummary, "Running now")
        let normal = LaunchStatusPresenter.presentation(applicationName: "Fixture", profileName: "Space",
            state: .running, openingDisposition: nil, isolationActivityUnobserved: false)
        XCTAssertEqual(normal.tone, .success)
        XCTAssertTrue(running.message.hasPrefix(normal.message))
        XCTAssertNotEqual(normal.message, running.message)
        let closed = LaunchStatusPresenter.presentation(applicationName: "Fixture", profileName: "Space",
            state: .terminated, openingDisposition: nil, isolationActivityUnobserved: true)
        XCTAssertNil(closed.listSummary)
        XCTAssertNotEqual(closed.message, running.message)
    }
}
