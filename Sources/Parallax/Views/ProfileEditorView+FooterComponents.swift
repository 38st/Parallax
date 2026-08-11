import SwiftUI
import UniformTypeIdentifiers

// MARK: - Footer components

extension ProfileEditorView {
  @ViewBuilder
  func footerControls(axis: Axis) -> some View {
    let layout =
      axis == .horizontal
      ? AnyLayout(HStackLayout(spacing: 8))
      : AnyLayout(VStackLayout(alignment: .leading, spacing: 8))

    layout {
      Button("Discard Changes") {
        revertDraft()
      }
      .disabled(draft == baseline || isSavingKeychainSecret)
      .keyboardShortcut(.cancelAction)

      if axis == .horizontal {
        Spacer()
      }

      if let validationMessage =
        actionPresentation.validationMessage,
        actionPresentation.isDirty
      {
        Label(
          validationMessage,
          systemImage: "xmark.circle.fill"
        )
        .font(.caption)
        .foregroundStyle(.red)
        .accessibilityIdentifier(
          UIAutomationContract.editorValidationError
        )
      }

      if actionPresentation.showsSave {
        Button("Save") {
          applyDraft()
        }
        .disabled(
          !actionPresentation.canSave
            || isSavingKeychainSecret
        )
        .keyboardShortcut("s", modifiers: .command)
        .accessibilityIdentifier(
          UIAutomationContract.editorSave
        )
      }

      Button {
        saveAndOpen()
      } label: {
        Label(
          actionPresentation.primaryTitle,
          systemImage: "arrow.up.forward.app"
        )
      }
      .buttonStyle(.borderedProminent)
      .keyboardShortcut(.defaultAction)
      .disabled(
        !actionPresentation.canOpen
          || isSavingKeychainSecret
      )
      .accessibilityIdentifier(
        UIAutomationContract.editorSaveAndOpen
      )
      .accessibilityHint(
        Text(
          actionPresentation.isDirty
            ? "Save these changes, then open this exact space"
            : "Open this space in the selected app"
        )
      )

      if let launchStatus =
        store.launchStatusPresentation(
          for: application,
          profile: profile
        )
      {
        Label(
          launchStatus.message,
          systemImage: launchStatusSystemImage(
            for: launchStatus.tone
          )
        )
          .font(.caption)
          .foregroundStyle(
            launchStatusColor(for: launchStatus.tone)
          )
          .fixedSize(horizontal: false, vertical: true)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(launchStatus.accessibilityLabel)
          .accessibilityIdentifier(
            "space-editor.launch-status.\(profile.id.uuidString.lowercased())"
          )
      }
    }
  }

  private func launchStatusSystemImage(
    for tone: SpaceLaunchStatusTone
  ) -> String {
    switch tone {
    case .neutral: "info.circle"
    case .success: "checkmark.circle"
    case .warning: "exclamationmark.triangle.fill"
    case .failure: "xmark.octagon.fill"
    }
  }

  private func launchStatusColor(
    for tone: SpaceLaunchStatusTone
  ) -> Color {
    switch tone {
    case .neutral: .secondary
    case .success: .green
    case .warning: .orange
    case .failure: .red
    }
  }
}
