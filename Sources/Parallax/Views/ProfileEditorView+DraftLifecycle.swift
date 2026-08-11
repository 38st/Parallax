import SwiftUI
import UniformTypeIdentifiers

// MARK: - Draft lifecycle

extension ProfileEditorView {
  @discardableResult
  func applyDraft() -> LaunchProfile? {
    session.applyDraft()
  }

  func saveAndOpen() {
    session.saveAndOpen()
  }

  func revertDraft() {
    session.revertDraft()
  }

  func rememberDraft() {
    session.rememberDraft()
  }
}
