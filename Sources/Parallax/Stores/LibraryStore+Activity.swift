import AppKit
import Foundation
import Observation

// MARK: - Activity history, workarounds, and support export

extension LibraryStore {
  func dismissLibraryOperationStatus() {
    libraryOperationStatusMessage = nil
  }

  func compatibilityLabel(for application: ManagedApplication) -> String {
    Self.resolvedPreset(for: application).label
  }

  func compatibilityDetail(for application: ManagedApplication) -> String {
    let preset = Self.resolvedPreset(for: application)

    if preset.needsCodexHome {
      return String(localized: "Uses CODEX_HOME and --user-data-dir for separate account state.")
    }

    if preset.supportsUserDataDir {
      return String(localized: "Uses --user-data-dir when the app honors Chromium launch flags.")
    }

    return String(
      localized:
        "Review each space’s Advanced Settings to confirm what this app keeps separate."
    )
  }

  func warnings(for application: ManagedApplication, profile: LaunchProfile) -> [String] {
    var warnings: [String] = []
    let preset = Self.resolvedPreset(for: application)

    if preset.needsCodexHome, !hasCodexHomeConfigured(in: profile) {
      warnings.append(
        String(localized: "Codex spaces need CODEX_HOME to avoid sharing the signed-in account."))
    }

    if preset.supportsUserDataDir,
      !hasUserDataDirectoryConfigured(in: profile)
    {
      warnings.append(
        String(localized: "This app may share browser state unless --user-data-dir is set."))
    }

    let parsedArguments = LaunchArgumentParser.parse(
      profile.argumentsText
    )
    let optionDiagnostics = UserDataDirectoryOptionResolver.resolve(
      in: parsedArguments.tokens
    ).diagnostics
    let environmentDiagnostics = LaunchEnvironmentParser.parse(
      profile.environmentText
    ).diagnostics
    warnings.append(
      contentsOf: (parsedArguments.diagnostics
        + optionDiagnostics
        + environmentDiagnostics).map(\.message)
    )
    if profile.childEnvironmentPolicy == .inheritProcessEnvironment {
      warnings.append(
        String(
          localized:
            "Advanced environment inheritance can expose Parallax process variables to the launched application."
        )
      )
    }
    if profile.launchConfigurationTrust == .importedPendingReview {
      warnings.append(
        String(
          localized:
            "Review this imported launch configuration before opening this space."
        )
      )
    }
    return Array(Set(warnings)).sorted()
  }

  func hasCodexHomeConfigured(in profile: LaunchProfile) -> Bool {
    Self.environmentValue("CODEX_HOME", in: profile) != nil
  }

  func hasUserDataDirectoryConfigured(in profile: LaunchProfile) -> Bool {
    Self.userDataDirectoryArgumentValue(in: profile) != nil
  }

  func isSpaceRunning(
    application: ManagedApplication,
    profile: LaunchProfile
  ) -> Bool {
    _ = launchPresentationRevision
    return profileActivityRegistry.isActive(
      identity: ProfileActivityIdentity(
        applicationID: application.id,
        applicationStorageID: application.storageID,
        profileID: profile.id,
        profileStorageID: profile.storageID
      )
    )
  }

  func launchHistory(
    for application: ManagedApplication
  ) -> [LaunchHistoryEntry] {
    launchHistoryStore.entries(for: application)
  }

  func refreshLaunchHistory() {
    launchHistoryStore.refreshFromDisk()
  }

  var launchHistoryPersistenceErrorMessage: String? {
    launchHistoryStore.persistenceErrorMessage
  }

  var workaroundPersistenceErrorMessage: String? {
    managedAppWorkaroundStore.persistenceErrorMessage
  }

  var recoveryPersistenceErrorMessage: String? {
    managedAppRecoveryLedger.persistenceErrorMessage
  }

  func workaroundRecords(
    for application: ManagedApplication,
    profile: LaunchProfile? = nil
  ) -> [ManagedAppWorkaroundRecord] {
    managedAppWorkaroundStore.records(
      applicationStorageID: application.storageID,
      profileStorageID: profile?.storageID
    )
  }

  func recordPictureInPictureWorkaroundVerified(
    for application: ManagedApplication,
    profile: LaunchProfile,
    at date: Date = Date()
  ) {
    guard
      managedAppWorkaroundStore.upsert(
        ManagedAppWorkaroundRecord(
          applicationStorageID:
            application.storageID,
          profileStorageID: profile.storageID,
          workaroundID:
            "openai.remote-hosted-pip.hide.v1",
          displayName:
            "Hide remote Picture in Picture",
          definitionVersion: 1,
          configurationReference:
            "desktop.computerUseAlwaysHidePictureInPicture",
          state: .verified,
          updatedAt: date,
          operatorNote:
            "Recorded as externally applied and verified. Parallax did not mutate third-party settings."
        )
      )
    else {
      errorMessage =
        managedAppWorkaroundStore.persistenceErrorMessage
      return
    }
    libraryOperationStatusMessage = String(
      localized:
        "Recorded the verified crash workaround for \(profile.name)."
    )
  }

  func removePictureInPictureWorkaroundRecord(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) {
    guard
      managedAppWorkaroundStore.remove(
        applicationStorageID: application.storageID,
        profileStorageID: profile.storageID,
        workaroundID:
          "openai.remote-hosted-pip.hide.v1"
      )
    else {
      errorMessage =
        managedAppWorkaroundStore.persistenceErrorMessage
      return
    }
    libraryOperationStatusMessage = String(
      localized:
        "Removed the workaround record for \(profile.name). This did not change third-party app settings."
    )
  }

  func clearLaunchHistory(
    for application: ManagedApplication
  ) {
    launchHistoryStore.clearHistory(for: application)
    libraryOperationStatusMessage = String(
      localized:
        "Cleared recent activity for \(application.displayName)."
    )
  }

  func exportSanitizedSupportBundle(
    for application: ManagedApplication,
    crashReports: [UUID: ApplicationCrashReport]
  ) {
    guard canUseSettingsAuthority() else { return }
    let service = SanitizedSupportBundleService()
    let bundle = service.makeBundle(
      application: application,
      history: launchHistoryStore.entries(
        for: application
      ),
      crashReports: crashReports,
      workaroundRecords: workaroundRecords(
        for: application
      ),
      settings: AppSettingsSnapshot(
        automaticCrashRecoveryEnabled:
          settings.automaticallyRecoverCrashedApps,
        confirmBeforeLaunch:
          settings.confirmBeforeLaunch,
        appearance: settings.appearance.rawValue
      ),
      persistenceHealth: .init(
        libraryHistoryAvailable:
          launchHistoryPersistenceErrorMessage == nil,
        recoveryLedgerAvailable:
          recoveryPersistenceErrorMessage == nil,
        workaroundStateAvailable:
          workaroundPersistenceErrorMessage == nil
      )
    )
    let data: Data
    do {
      data = try service.encode(bundle)
    } catch {
      errorMessage = String(
        localized:
          "The sanitized support bundle could not be encoded. \(error.localizedDescription)"
      )
      return
    }

    let panel = NSSavePanel()
    panel.title = String(
      localized: "Export Sanitized Support Bundle"
    )
    panel.nameFieldStringValue =
      "Parallax-Sanitized-Support.json"
    panel.allowedContentTypes = [.json]
    panel.canCreateDirectories = true
    panel.begin { [weak self] response in
      guard response == .OK, let destination = panel.url else {
        return
      }
      Task { @MainActor [weak self] in
        do {
          try await Task.detached {
            try data.write(
              to: destination,
              options: .atomic
            )
            try FileManager.default.setAttributes(
              [
                .posixPermissions:
                  NSNumber(value: Int16(0o600))
              ],
              ofItemAtPath: destination.path
            )
          }.value
          self?.libraryOperationStatusMessage =
            String(
              localized:
                "Exported a sanitized support bundle with no profile names, paths, process IDs, arguments, environment values, notes, or raw crash reports."
            )
        } catch {
          self?.errorMessage = String(
            localized:
              "The sanitized support bundle could not be saved. \(error.localizedDescription)"
          )
        }
      }
    }
  }
}
