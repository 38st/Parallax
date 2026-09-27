import SwiftUI
import UniformTypeIdentifiers

struct ApplicationSettingsActionPresentation: Equatable, Sendable {
    let isDirty: Bool
    let normalizedDisplayName: String?
    let nameValidationMessage: String?

    init(draft: ManagedApplication, baseline: ManagedApplication) {
        isDirty = draft != baseline
        let validation = DisplayNameValidator.validate(
            draft.displayName
        )
        let nameChanged = draft.displayName != baseline.displayName
        normalizedDisplayName = nameChanged ? validation.normalized : baseline.displayName
        nameValidationMessage = nameChanged
            ? validation.issue?.message(for: .application)
            : nil
    }

    var canSave: Bool {
        isDirty && normalizedDisplayName != nil
    }
}
