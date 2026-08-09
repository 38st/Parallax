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
        keychainEnvironmentKey = ""
        keychainSecretValue = ""
        isAddingKeychainSecret = true
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
    guard
      let removal = store.profileDraftRemovingKeychainSecret(
        environmentKey: key,
        from: draft
      )
    else { return }

    draft = removal.profile
    if stagedKeychainReferences.remove(removal.reference) != nil {
      discardKeychainReferences([removal.reference])
    } else {
      pendingKeychainDeletionReferences.insert(removal.reference)
    }
    rememberDraft()
  }

  var profileDataSummary: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 3) {
          Text(
            store.profileFolderDisplayPath(
              for: application,
              profile: draft
            )
          )
          .font(.system(.caption, design: .monospaced))
          .lineLimit(1)
          .truncationMode(.middle)
          .textSelection(.enabled)

          Text(healthSummary)
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Spacer()

        profileDataMenu
      }

      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
        ForEach(store.healthItems(for: application, profile: draft), id: \.label) { item in
          GridRow {
            Image(systemName: item.isHealthy ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(item.isHealthy ? .green : .secondary)
              .accessibilityHidden(true)
            Text(item.label)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .combine)
          .accessibilityLabel(
            Text(
              item.isHealthy
                ? String(
                  localized:
                    "\(item.label): passing"
                )
                : String(
                  localized:
                    "\(item.label): not passing"
                )
            )
          )
        }
      }
    }
  }

  var profileDataMenu: some View {
    Menu {
      Button {
        store.revealProfileFolder(for: application, profile: draft)
      } label: {
        Label("Reveal Space Folder", systemImage: "folder")
      }

      if store.shouldShowCodexHomeActions(
        for: application,
        profile: draft
      ) {
        Button {
          store.revealCodexHome(for: application, profile: draft)
        } label: {
          Label("Reveal Codex Home", systemImage: "house")
        }

        Button {
          isImportingCodexHome = true
        } label: {
          Label("Use Existing Codex Home", systemImage: "square.and.arrow.down")
        }
      }

      if store.shouldShowUserDataActions(
        for: application,
        profile: draft
      ) {
        Button {
          store.revealUserData(for: application, profile: draft)
        } label: {
          Label("Reveal User Data", systemImage: "globe")
        }
      }

      Divider()

      Button(role: .destructive) {
        store.requestClearProfileData(
          for: application,
          profile: profile
        )
      } label: {
        Label("Clear Data", systemImage: "trash")
      }
    } label: {
      Label(
        "Browsing and App Data",
        systemImage: "ellipsis.circle"
      )
    }
    .menuStyle(.borderlessButton)
    .help("Browsing and App Data Actions")
  }

  var launchPreview: some View {
    VStack(alignment: .leading, spacing: 10) {
      LabeledContent("Arguments") {
        Text(argumentSummary)
          .foregroundStyle(.secondary)
      }

      LabeledContent("Environment") {
        Text(environmentSummary)
          .foregroundStyle(.secondary)
      }

      if environmentPreviewLines.contains(where: \.isRevealable) {
        Button {
          isRevealingSensitiveLiterals.toggle()
        } label: {
          Label(
            isRevealingSensitiveLiterals
              ? String(
                localized: "Hide Sensitive Literals"
              )
              : String(
                localized: "Reveal Sensitive Literals"
              ),
            systemImage: isRevealingSensitiveLiterals
              ? "eye.slash"
              : "eye"
          )
        }
        .buttonStyle(.link)
        .help(
          isRevealingSensitiveLiterals
            ? String(
              localized:
                "Hide sensitive literal values in this preview"
            )
            : String(
              localized:
                "Temporarily reveal sensitive literal values in this window"
            )
        )
      }

      DisclosureGroup("Details") {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(
            Array(argumentPreviewLines.enumerated()),
            id: \.offset
          ) { _, argument in
            Text(argument)
              .font(.system(.caption, design: .monospaced))
              .textSelection(.enabled)
          }

          ForEach(
            Array(environmentPreviewLines.enumerated()),
            id: \.offset
          ) { _, item in
            Text(item.text)
              .font(.system(.caption, design: .monospaced))
              .foregroundStyle(
                item.isSensitive ? .secondary : .primary
              )
              .textSelection(.enabled)
          }

          if argumentPreviewLines.isEmpty
            && environmentPreviewLines.isEmpty
          {
            Text("No launch configuration")
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Text(
            "Keychain references remain redacted and are resolved only when a launch is prepared."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
      }
    }
  }

  var healthSummary: String {
    let items = store.healthItems(for: application, profile: draft)
    let healthyCount = items.filter(\.isHealthy).count
    return String(
      localized:
        "\(healthyCount) of \(items.count) checks passing"
    )
  }

  var separationSummary: SpaceSeparationSummary {
    SpaceSeparationSummary(
      application: application,
      profile: draft
    )
  }

  var actionPresentation: SpaceEditorActionPresentation {
    SpaceEditorActionPresentation(
      draft: draft,
      baseline: baseline
    )
  }

  var argumentSummary: String {
    let count = argumentParseResult.tokens.count
    return count == 0
      ? String(localized: "None")
      : LocalizedCount.launchArguments(count)
  }

  var environmentSummary: String {
    let count = environmentParseResult.entries.count
    return count == 0
      ? String(localized: "None")
      : LocalizedCount.environmentOperations(count)
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

      if let launchStatusMessage =
        store.launchStatusMessage(
          for: application,
          profile: profile
        )
      {
        Text(launchStatusMessage)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
    }
  }
}
