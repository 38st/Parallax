import Foundation

/// Stable accessibility identifiers for the critical create, save-and-open,
/// and destructive-confirmation controls.
///
/// Two things consume these constants today. The SwiftUI views attach them to
/// the controls they name (`NewSpaceView`,
/// `ProfileEditorView+FooterComponents`, and
/// `ApplicationRemovalConfirmationView`), which exposes them to accessibility
/// clients such as VoiceOver and the Accessibility Inspector.
/// `UIAutomationContractTests` pins the exact strings and asserts that
/// `criticalJourneyIdentifiers` stays unique. Nothing else reads them:
/// `Package.swift` declares no UI test target, and a host-driven XCUITest
/// suite for these journeys does not exist yet.
///
/// Keep the values independent from translated labels and stable across
/// releases so a future host-driven suite can address these controls under
/// every supported locale.
enum UIAutomationContract {
    static let newSpaceName = "new-space.name"
    static let newSpacePurpose = "new-space.purpose"
    static let newSpaceError = "new-space.error"
    static let newSpaceCreate = "new-space.create"
    static let newSpaceCreateAndOpen = "new-space.create-and-open"
    static let editorValidationError = "space-editor.validation-error"
    static let editorSave = "space-editor.save"
    static let editorSaveAndOpen = "space-editor.save-and-open"
    static let applicationRemovalConfirm =
        "application-removal.confirm"

    static let criticalJourneyIdentifiers = [
        newSpaceName,
        newSpacePurpose,
        newSpaceError,
        newSpaceCreate,
        newSpaceCreateAndOpen,
        editorValidationError,
        editorSave,
        editorSaveAndOpen,
        applicationRemovalConfirm,
    ]
}
