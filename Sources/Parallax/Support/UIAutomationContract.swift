import Foundation

/// Stable accessibility identifiers for release-gate UI automation.
///
/// Keep these independent from translated labels so automation can run under
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
