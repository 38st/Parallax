import SwiftUI
import UniformTypeIdentifiers

// MARK: - Profile data and launch preview components

extension ProfileEditorView {
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
}
