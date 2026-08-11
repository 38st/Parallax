import SwiftUI
import UniformTypeIdentifiers

// MARK: - Environment components

extension ProfileEditorView {
  @ViewBuilder
  var environmentSecurityControls: some View {
    HStack(spacing: 10) {
      if !environmentSensitivityOptions.isEmpty {
        Menu {
          ForEach(
            environmentSensitivityOptions,
            id: \.key
          ) { option in
            if option.isKeychainReference {
              Toggle(
                String(
                  localized:
                    "\(option.key) (Keychain reference)"
                ),
                isOn: .constant(true)
              )
              .disabled(true)
            } else if option.isAutomaticallySensitive {
              Toggle(
                String(
                  localized:
                    "\(option.key) (Automatically detected)"
                ),
                isOn: .constant(true)
              )
              .disabled(true)
            } else {
              Toggle(
                option.key,
                isOn: sensitiveKeyBinding(for: option.key)
              )
            }
          }
        } label: {
          Label("Redaction", systemImage: "eye.slash")
        }
        .help(
          "Choose environment values to redact in previews and exports"
        )
      }

      Button {
        session.beginAddingKeychainSecret()
      } label: {
        Label("Add Secret", systemImage: "key")
      }
    }
    .buttonStyle(.bordered)

    ForEach(
      environmentSensitivityOptions.filter(\.isKeychainReference),
      id: \.key
    ) { option in
      HStack {
        Label(option.key, systemImage: "key.fill")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button(role: .destructive) {
          removeKeychainSecret(for: option.key)
        } label: {
          Label("Remove", systemImage: "trash")
            .labelStyle(.iconOnly)
        }
        .buttonStyle(.borderless)
        .help("Remove \(option.key) from Keychain")
      }
    }
  }

  func removeKeychainSecret(for key: String) {
    session.removeKeychainSecret(for: key)
  }

  var argumentParseResult: LaunchArgumentParseResult {
    LaunchArgumentParser.parse(draft.argumentsText)
  }

  var environmentParseResult: LaunchEnvironmentParseResult {
    LaunchEnvironmentParser.parse(draft.environmentText)
  }

  var argumentPreviewLines: [String] {
    ProfileEditorSecurityPresentation.argumentPreview(
      for: draft.argumentsText
    )
  }

  var environmentPreviewLines: [ProfileEditorEnvironmentPreviewLine] {
    ProfileEditorSecurityPresentation.environmentPreview(
      for: draft.environmentText,
      explicitSensitiveKeys: Set(draft.sensitiveEnvironmentKeys),
      revealSensitiveLiterals: isRevealingSensitiveLiterals,
      childEnvironmentPolicy: draft.childEnvironmentPolicy,
      identity: .current,
      processEnvironment: ProcessInfo.processInfo.environment
    )
  }

  var environmentSensitivityOptions: [ProfileEditorEnvironmentSensitivityOption] {
    ProfileEditorSecurityPresentation.environmentSensitivityOptions(
      for: draft.environmentText
    )
  }

  var inheritsProcessEnvironment: Binding<Bool> {
    Binding(
      get: {
        draft.childEnvironmentPolicy == .inheritProcessEnvironment
      },
      set: { shouldInherit in
        draft.childEnvironmentPolicy =
          shouldInherit
          ? .inheritProcessEnvironment
          : .safeDefault
      }
    )
  }

  func sensitiveKeyBinding(for key: String) -> Binding<Bool> {
    Binding(
      get: {
        Set(draft.sensitiveEnvironmentKeys.map { $0.uppercased() })
          .contains(key.uppercased())
      },
      set: { isSensitive in
        draft.sensitiveEnvironmentKeys =
          ProfileEditorSecurityPresentation.updatingSensitiveKeys(
            draft.sensitiveEnvironmentKeys,
            key: key,
            isSensitive: isSensitive
          )
      }
    )
  }
}
