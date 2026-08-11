import AppKit
import Foundation
import Observation

// MARK: - Import, export, and recovery

enum LibraryPortableExportAuthorityError: LocalizedError, Equatable {
  case settingsUnverified

  var errorDescription: String? {
    String(
      localized:
        "Wait for settings to finish saving or resolve settings recovery before exporting settings."
    )
  }
}

extension LibraryStore {
  func exportLibrary() {
    exportPortable(.libraryMetadata)
  }

  func exportPortable(_ kind: LibraryPortableExportKind) {
    guard canExportPortable(kind) else {
      errorMessage = LibraryPortableExportAuthorityError
        .settingsUnverified.localizedDescription
      return
    }
    var sensitivePolicy = SensitiveLiteralExportPolicy.omit
    if portableExportContainsSensitiveLiterals(kind: kind) {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = String(
        localized:
          "Export plaintext sensitive environment values?"
      )
      alert.informativeText = String(
        localized:
          "This library contains environment values classified as sensitive. Choose whether to omit, redact, or explicitly include those literals. Keychain-backed secrets remain references."
      )
      alert.addButton(
        withTitle: String(localized: "Omit Sensitive Values")
      )
      alert.addButton(
        withTitle: String(localized: "Redact Sensitive Values")
      )
      alert.addButton(
        withTitle: String(localized: "Include Sensitive Values")
      )
      alert.addButton(withTitle: String(localized: "Cancel"))
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        sensitivePolicy = .omit
      case .alertSecondButtonReturn:
        sensitivePolicy = .redact
      case .alertThirdButtonReturn:
        sensitivePolicy =
          .includeAfterExplicitConfirmation
      default:
        return
      }
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue =
      switch kind {
      case .libraryMetadata:
        String(localized: "Parallax Library Metadata.json")
      case .settingsAndTemplates:
        String(
          localized:
            "Parallax Settings and Templates.json"
        )
      case .portableConfiguration:
        String(
          localized:
            "Parallax Portable Configuration.json"
        )
      }
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let data = try portableExportData(
        kind: kind,
        sensitivePolicy: sensitivePolicy
      )
      try fileSystem.writeDataAtomically(data, to: url)
      launchStatusMessage =
        switch kind {
        case .libraryMetadata:
          String(localized: "Exported library metadata")
        case .settingsAndTemplates:
          String(localized: "Exported settings and templates")
        case .portableConfiguration:
          String(localized: "Exported portable configuration")
        }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func portableExportData(
    kind: LibraryPortableExportKind,
    sensitivePolicy: SensitiveLiteralExportPolicy
  ) throws -> Data {
    let library = LibraryDocument(
      applications: applications
    )
    switch kind {
    case .libraryMetadata:
      return try portableConfiguration.encode(
        portableConfiguration.makeLibraryMetadataExport(
          library: library,
          sensitiveLiteralPolicy: sensitivePolicy
        )
      )
    case .settingsAndTemplates:
      guard settings.canProvideVerifiedSettings else {
        throw LibraryPortableExportAuthorityError.settingsUnverified
      }
      let settingsSnapshot = portableSettingsSnapshot()
      return try portableConfiguration.encode(
        portableConfiguration
          .makeSettingsAndTemplatesExport(
            settings: settingsSnapshot,
            sensitiveLiteralPolicy:
              sensitivePolicy
          )
      )
    case .portableConfiguration:
      guard settings.canProvideVerifiedSettings else {
        throw LibraryPortableExportAuthorityError.settingsUnverified
      }
      let settingsSnapshot = portableSettingsSnapshot()
      return try portableConfiguration.encode(
        portableConfiguration
          .makePortableConfigurationExport(
            library: library,
            settings: settingsSnapshot,
            sensitiveLiteralPolicy:
              sensitivePolicy
          )
      )
    }
  }

  func canExportPortable(_ kind: LibraryPortableExportKind) -> Bool {
    switch kind {
    case .libraryMetadata:
      return true
    case .settingsAndTemplates, .portableConfiguration:
      return settings.canProvideVerifiedSettings
    }
  }

  private func portableSettingsSnapshot() -> PortableSettingsSnapshot {
    PortableSettingsSnapshot(
      profileTemplates: settings.profileTemplates,
      defaultBaseStoragePath: settings.defaultBaseStoragePath,
      confirmBeforeLaunch: settings.confirmBeforeLaunch,
      appearance: settings.appearance
    )
  }

  func portableExportContainsSensitiveLiterals(
    kind: LibraryPortableExportKind
  ) -> Bool {
    let includesLibrary = kind != .settingsAndTemplates
    let includesSettings = kind != .libraryMetadata
    return
      (includesLibrary
      && libraryExportContainsSensitiveLiterals())
      || (includesSettings
        && settings.profileTemplates.contains {
          Self.environmentContainsSensitiveLiterals(
            $0.environmentText,
            explicitSensitiveKeys: []
          )
        })
  }

  func libraryExportContainsSensitiveLiterals() -> Bool {
    applications.contains { application in
      application.profiles.contains { profile in
        Self.environmentContainsSensitiveLiterals(
          profile.environmentText,
          explicitSensitiveKeys:
            Set(profile.sensitiveEnvironmentKeys)
        )
      }
    }
  }

  static func environmentContainsSensitiveLiterals(
    _ environmentText: String,
    explicitSensitiveKeys: Set<String>
  ) -> Bool {
    do {
      return try SensitiveConfigurationTextSanitizer()
        .sanitizeEnvironment(
          environmentText,
          explicitSensitiveKeys: explicitSensitiveKeys,
          policy: .includeAfterExplicitConfirmation
        ).containsSensitiveContent
    } catch {
      // Invalid configuration text must still trigger the guarded export path.
      return true
    }
  }

  func libraryDocumentForExport(
    sensitivePolicy: LibraryExportSensitivePolicy
  ) -> LibraryDocument {
    let exportedApplications = applications.map { application in
      var exported = application
      exported.profiles = application.profiles.map { profile in
        var exportedProfile = profile
        exportedProfile.environmentText =
          Self.exportEnvironmentText(
            profile,
            sensitivePolicy: sensitivePolicy
          )
        return exportedProfile
      }
      return exported
    }
    return LibraryDocument(applications: exportedApplications)
  }

  static func exportEnvironmentText(
    _ profile: LaunchProfile,
    sensitivePolicy: LibraryExportSensitivePolicy
  ) -> String {
    let policy: SensitiveConfigurationTextSanitizationPolicy =
      switch sensitivePolicy {
      case .omit:
        .omit
      case .redact:
        .redact
      case .include:
        .includeAfterExplicitConfirmation
      }
    do {
      return try SensitiveConfigurationTextSanitizer()
        .sanitizeEnvironment(
          profile.environmentText,
          explicitSensitiveKeys:
            Set(profile.sensitiveEnvironmentKeys),
          policy: policy
        ).text
    } catch {
      // This compatibility path cannot surface an error. Empty output is the
      // only fail-closed result that cannot disclose malformed source text.
      return ""
    }
  }

}
