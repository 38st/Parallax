import XCTest
@testable import Parallax

final class SpacePresentationTests: XCTestCase {
    func testSeparationSummaryUsesEffectiveDraft() {
        let app = ManagedApplication(
            displayName: "Chrome",
            appPath: "/Applications/Chrome.app",
            preset: .chrome
        )
        let baseline = LaunchProfile(name: "Work")
        var draft = baseline
        draft.argumentsText = "--user-data-dir /tmp/work"

        XCTAssertEqual(
            SpaceSeparationSummary(
                application: app,
                profile: baseline
            ).kind,
            .custom
        )
        XCTAssertEqual(
            SpaceSeparationSummary(
                application: app,
                profile: draft
            ).kind,
            .browsingData
        )
    }

    func testEditorActionsDistinguishCleanDirtyAndInvalidDrafts() {
        let baseline = LaunchProfile(name: "Work")
        let clean = SpaceEditorActionPresentation(
            draft: baseline,
            baseline: baseline
        )
        var dirty = baseline
        dirty.name = "Renamed"
        let changed = SpaceEditorActionPresentation(
            draft: dirty,
            baseline: baseline
        )
        dirty.argumentsText = "\"unterminated"
        let invalid = SpaceEditorActionPresentation(
            draft: dirty,
            baseline: baseline
        )

        XCTAssertEqual(clean.primaryTitle, "Open Space")
        XCTAssertFalse(clean.showsSave)
        XCTAssertTrue(clean.canOpen)
        XCTAssertEqual(changed.primaryTitle, "Save & Open")
        XCTAssertTrue(changed.showsSave)
        XCTAssertTrue(changed.canOpen)
        XCTAssertTrue(invalid.hasParsingErrors)
        XCTAssertFalse(invalid.canOpen)
        XCTAssertNotNil(invalid.validationMessage)
    }

    func testNewSpaceDraftKeepsCustomNameWhenPurposeChanges() throws {
        let choices = NewSpaceChoice.available(
            templates: ProfileTemplate.defaults
        )
        var draft = NewSpaceDraft(choices: choices)
        let personal = try XCTUnwrap(
            choices.first { $0.title == "Personal" }
        )

        draft.name = "Client Work"
        draft.select(personal)

        XCTAssertEqual(draft.name, "Client Work")
        XCTAssertEqual(draft.choice, personal)
        XCTAssertTrue(draft.canCreate)
    }

    func testNewSpaceDraftUpdatesSuggestedNameAndIncludesBlank() throws {
        let choices = NewSpaceChoice.available(
            templates: ProfileTemplate.defaults
        )
        var draft = NewSpaceDraft(choices: choices)
        let blank = try XCTUnwrap(
            choices.first { $0.kind == .blank }
        )

        draft.select(blank)

        XCTAssertEqual(draft.name, "Blank")
        XCTAssertNil(draft.choice.templateID)
    }

    func testSaveAndOpenNeverOpensAfterFailedSave() {
        let baseline = LaunchProfile(name: "Work")
        var draft = baseline
        draft.name = "Renamed"
        var opened: LaunchProfile?

        let succeeded = SpaceEditorWorkflow.saveAndOpen(
            draft: draft,
            baseline: baseline,
            save: { nil },
            open: { opened = $0 }
        )

        XCTAssertFalse(succeeded)
        XCTAssertNil(opened)
    }

    func testSaveAndOpenUsesExactPersistedResult() {
        let baseline = LaunchProfile(name: "Work")
        var draft = baseline
        draft.name = "Renamed"
        var persisted = draft
        persisted.notes = "Merged non-conflicting note"
        var opened: LaunchProfile?

        let succeeded = SpaceEditorWorkflow.saveAndOpen(
            draft: draft,
            baseline: baseline,
            save: { persisted },
            open: { opened = $0 }
        )

        XCTAssertTrue(succeeded)
        XCTAssertEqual(opened, persisted)
    }
}
