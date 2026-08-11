import SwiftUI
import UniformTypeIdentifiers

// MARK: - Editor components

extension ProfileEditorView {
  func advancedSettingsCard<Content: View>(
    title: LocalizedStringKey,
    systemImage: String,
    description: LocalizedStringKey,
    @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 10) {
        Image(systemName: systemImage)
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(.tint)
          .frame(width: 22, height: 22)
          .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline)
          Text(description)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      VStack(alignment: .leading, spacing: 10) {
        content()
      }
      .padding(.leading, 32)
    }
    .padding(14)
    .background(
      Color.secondary.opacity(0.055),
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
    }
  }

  func configurationEditor(
    text: Binding<String>,
    accessibilityLabel: LocalizedStringKey,
    accessibilityIdentifier: String
  ) -> some View {
    TextEditor(text: text)
      .font(.system(.callout, design: .monospaced))
      .frame(minHeight: 82)
      .padding(6)
      .scrollContentBackground(.hidden)
      .background(
        Color(nsColor: .textBackgroundColor),
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
      }
      .accessibilityLabel(Text(accessibilityLabel))
      .accessibilityIdentifier(accessibilityIdentifier)
  }

  @ViewBuilder
  func parsingDiagnostics(
    _ diagnostics: [LaunchParsingDiagnostic]
  ) -> some View {
    ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
      VStack(alignment: .leading, spacing: 2) {
        Label(
          diagnostic.message,
          systemImage: diagnostic.severity == .error
            ? "xmark.circle.fill"
            : "exclamationmark.triangle.fill"
        )
        .foregroundStyle(
          diagnostic.severity == .error ? .red : .orange
        )

        Text(
          ProfileEditorSecurityPresentation.locationDescription(
            diagnostic.range
          )
        )
        .foregroundStyle(.secondary)

        if let relatedRange = diagnostic.relatedRange {
          Text(
            String(
              localized:
                "Related entry: \(ProfileEditorSecurityPresentation.locationDescription(relatedRange))"
            )
          )
          .foregroundStyle(.secondary)
        }
      }
      .font(.caption)
      .accessibilityElement(children: .combine)
    }
  }

}
