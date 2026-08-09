import AppKit
import Foundation
import Observation

// MARK: - Activity, health, and managed paths

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

  @discardableResult
  func reopen(
    _ entry: LaunchHistoryEntry,
    from application: ManagedApplication
  ) -> Bool {
    guard
      entry.applicationID == application.id,
      entry.applicationStorageID == application.storageID,
      let profile = application.profiles.first(where: {
        $0.id == entry.profileID
          && $0.storageID == entry.profileStorageID
      })
    else {
      errorMessage = String(
        localized:
          "This space is no longer available in \(application.displayName)."
      )
      return false
    }
    launch(profile)
    return true
  }

  func runningApplicationInstances(
    for application: ManagedApplication
  ) -> [ManagedApplicationInstance] {
    _ = launchPresentationRevision
    return applicationInstanceController.instances(
      for: application,
      trackedProcesses:
        profileActivityRegistry.runningProcesses(
          applicationStorageID: application.storageID
        )
    ).map { instance in
      guard instance.hasTrackedAttribution else {
        return instance.presenting(.outsideParallax)
      }
      guard
        exactRunningTrackedLaunch(
          for: instance,
          application: application
        ) != nil
      else {
        return instance.presenting(.verificationUnavailable)
      }
      return instance.presenting(.verifiedParallaxInstance)
    }
  }

  @discardableResult
  func requestQuit(
    _ instance: ManagedApplicationInstance,
    from application: ManagedApplication
  ) -> Bool {
    let trackedLaunch = authoritativeTrackedLaunch(
      for: instance,
      application: application
    )
    do {
      guard let trackedLaunch else {
        throw ApplicationInstanceControllerError.unmanagedInstance(
          instance.processIdentifier
        )
      }
      try trackedLaunch.performTerminationRequest {
        try applicationInstanceController.requestQuit(
          instance,
          from: application
        )
      }
      libraryOperationStatusMessage = String(
        localized:
          "Asked \(instance.displayName) to quit."
      )
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  private func authoritativeTrackedLaunch(
    for instance: ManagedApplicationInstance,
    application: ManagedApplication
  ) -> TrackedApplicationLaunch? {
    guard instance.isActionable else { return nil }
    return exactRunningTrackedLaunch(
      for: instance,
      application: application
    )
  }

  private func exactRunningTrackedLaunch(
    for instance: ManagedApplicationInstance,
    application: ManagedApplication
  ) -> TrackedApplicationLaunch? {
    guard
      instance.hasTrackedAttribution,
      let requestID = instance.requestID,
      let profileID = instance.profileID,
      let profileStorageID = instance.profileStorageID,
      let launch = activeTrackedLaunches[requestID],
      let profile = application.profiles.first(where: {
        $0.id == profileID && $0.storageID == profileStorageID
      })
    else {
      return nil
    }
    let lifecycle = launch.currentLifecycle
    let expectedActivity = ProfileActivityIdentity(
      applicationID: application.id,
      applicationStorageID: application.storageID,
      profileID: profile.id,
      profileStorageID: profile.storageID
    )
    guard
      lifecycle.requestID == requestID,
      lifecycle.identity == expectedActivity,
      lifecycle.processIdentity == instance.processIdentity,
      launch.isSupervising(instance.processIdentity)
    else {
      return nil
    }
    switch lifecycle.state {
    case .running(let processIdentifier),
      .runningDegraded(let processIdentifier, _):
      return processIdentifier == instance.processIdentifier
        ? launch
        : nil
    case .requested, .launching, .terminating, .terminated, .failed:
      return nil
    }
  }

  @discardableResult
  func requestActivate(
    _ instance: ManagedApplicationInstance,
    from application: ManagedApplication
  ) -> Bool {
    do {
      guard
        authoritativeTrackedLaunch(
          for: instance,
          application: application
        ) != nil
      else {
        throw ApplicationInstanceControllerError.unmanagedInstance(
          instance.processIdentifier
        )
      }
      try applicationInstanceController.requestActivate(
        instance,
        from: application
      )
      errorMessage = nil
      libraryOperationStatusMessage = String(
        localized:
          "Brought \(instance.displayName) forward."
      )
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func healthItems(for application: ManagedApplication, profile: LaunchProfile) -> [(
    label: String, isHealthy: Bool
  )] {
    let key = HealthCacheKey(
      application: application,
      profileID: profile.id
    )
    if let cached = healthItemsCache[key] {
      return cached
    }
    if healthInspectionTasks[key] == nil {
      let source = healthInspectionSource(
        for: application,
        profile: profile
      )
      let service = launchHealthService
      healthInspectionTasks[key] = Task { [weak self] in
        let items = await Task.detached {
          Self.inspectHealth(source, service: service)
        }.value
        guard let self else { return }
        self.healthItemsCache = self.healthItemsCache.filter {
          $0.key.application.id != application.id
            || $0.key.profileID != profile.id
        }
        self.healthItemsCache[key] = items
        self.healthInspectionTasks[key] = nil
      }
    }
    return [
      (
        String(localized: "Health inspection"),
        false
      )
    ]
  }

  @discardableResult
  func refreshHealthItems(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) async -> [(label: String, isHealthy: Bool)] {
    let key = HealthCacheKey(
      application: application,
      profileID: profile.id
    )
    let source = healthInspectionSource(
      for: application,
      profile: profile
    )
    let service = launchHealthService
    let items = await Task.detached {
      Self.inspectHealth(source, service: service)
    }.value
    healthItemsCache[key] = items
    return items
  }

  nonisolated static func inspectHealth(
    _ source: HealthInspectionSource,
    service: LaunchHealthService
  ) -> [(label: String, isHealthy: Bool)] {
    let preset = source.preset
    let applicationReport = service.inspectApplication(
      source.applicationInput
    )
    let profileReport = service.inspectProfiles(
      source.profileInputs
    ).first { $0.profileID == source.profile.id }
    var items: [(label: String, isHealthy: Bool)] = [
      (
        String(localized: "Application bundle"),
        applicationReport.isHealthy
      ),
      (
        String(localized: "Space folder"),
        profileReport?.paths.first {
          $0.role == .managedProfileRoot
        }.map(Self.isHealthyPath) ?? false
      ),
    ]

    if preset.supportsUserDataDir {
      let hasUserDataDir =
        userDataDirectoryArgumentValue(in: source.profile) != nil
      items.append((String(localized: "User data flag"), hasUserDataDir))
      items.append(
        (
          String(localized: "User data folder"),
          hasUserDataDir
            && (profileReport?.paths.first {
              $0.role == .managedUserData
                || $0.role == .externalUserData
            }.map(Self.isHealthyPath) ?? false)
        ))
    }

    if preset.needsCodexHome {
      let hasCodexHome =
        environmentValue("CODEX_HOME", in: source.profile) != nil
      items.append(("CODEX_HOME", hasCodexHome))
      items.append(
        (
          String(localized: "Codex home folder"),
          hasCodexHome
            && (profileReport?.paths.first {
              $0.role == .managedCodexHome
                || $0.role == .externalCodexHome
            }.map(Self.isHealthyPath) ?? false)
        ))
    }
    items.append(
      (
        String(localized: "Storage inactive"),
        profileReport?.isActive == false
      ))
    items.append(
      (
        String(localized: "No storage collisions"),
        profileReport?.issues.contains {
          $0.code == .canonicalPathCollision
            || $0.code == .fileIdentityCollision
        } == false
      ))

    return items
  }

  func resolvedArguments(for profile: LaunchProfile) -> [String] {
    let parsed = LaunchArgumentParser.parse(profile.argumentsText)
    var arguments = parsed.words
    let resolution = UserDataDirectoryOptionResolver.resolve(
      in: parsed.tokens
    )
    guard let configured = resolution.resolvedValue else {
      return arguments
    }
    let expanded = PathSpecificTildeExpander(
      homeDirectory:
        FileManager.default.homeDirectoryForCurrentUser.path
    ).argumentValue(configured, forOption: "--user-data-dir")
    for index in arguments.indices {
      if arguments[index].hasPrefix("--user-data-dir=") {
        arguments[index] = "--user-data-dir=\(expanded)"
        return arguments
      }
      if arguments[index] == "--user-data-dir",
        arguments.indices.contains(index + 1)
      {
        arguments[index + 1] = expanded
        return arguments
      }
    }
    return arguments
  }

  func resolvedEnvironment(for profile: LaunchProfile) -> [(key: String, value: String)] {
    let entries = LaunchEnvironmentParser.parse(
      profile.environmentText
    ).entries
    var effective: [String: (index: Int, value: String?)] = [:]
    for (index, entry) in entries.enumerated() {
      switch entry.operation {
      case .set(let value):
        effective[entry.name] = (index, value)
      case .unset:
        effective[entry.name] = (index, nil)
      }
    }
    let expander = PathSpecificTildeExpander(
      homeDirectory:
        FileManager.default.homeDirectoryForCurrentUser.path
    )
    return
      effective
      .compactMap { key, indexed -> (key: String, value: String, index: Int)? in
        guard let value = indexed.value else { return nil }
        return (
          key,
          expander.environmentValue(value, forKey: key),
          indexed.index
        )
      }
      .sorted { $0.index < $1.index }
      .map { (key: $0.key, value: $0.value) }
  }

  func profileFolderPath(for application: ManagedApplication, profile: LaunchProfile) -> String {
    do {
      return try managedPaths(for: application, profile: profile).profileRoot.url.path
    } catch {
      errorMessage = error.localizedDescription
      return ""
    }
  }

  func profileFolderDisplayPath(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> String {
    ManagedPathResolver.profileRootURL(
      baseRootURL: URL(
        fileURLWithPath: configuredBaseRoot(for: application),
        isDirectory: true
      ),
      applicationStorageID: application.storageID,
      profileStorageID: profile.storageID
    ).path
  }

  func shouldShowCodexHomeActions(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> Bool {
    Self.resolvedPreset(for: application).needsCodexHome
      && (profile.isolationOwnership.codexHome == .generated
        || Self.environmentValue(
          "CODEX_HOME",
          in: profile
        ) != nil)
  }

  func shouldShowUserDataActions(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> Bool {
    Self.resolvedPreset(for: application).supportsUserDataDir
      && (profile.isolationOwnership.userData == .generated
        || Self.userDataDirectoryArgumentValue(
          in: profile
        ) != nil)
  }

  func managedPaths(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) throws -> ResolvedProfilePaths {
    try pathResolver.resolve(
      configuredBaseRoot: configuredBaseRoot(for: application),
      applicationStorageID: application.storageID,
      profileStorageID: profile.storageID
    )
  }

  func codexHomePath(for application: ManagedApplication, profile: LaunchProfile) -> String? {
    guard Self.resolvedPreset(for: application).needsCodexHome else { return nil }
    do {
      if let configured = Self.environmentValue("CODEX_HOME", in: profile) {
        let expanded = PathSpecificTildeExpander(
          homeDirectory:
            FileManager.default.homeDirectoryForCurrentUser.path
        ).environmentValue(configured, forKey: "CODEX_HOME")
        return try pathResolver.resolveExternalPath(expanded).url.path
      }
      guard profile.isolationOwnership.codexHome == .generated else {
        return nil
      }
      return try managedPaths(
        for: application,
        profile: profile
      ).codexHome.url.path
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func userDataPath(for application: ManagedApplication, profile: LaunchProfile) -> String? {
    guard Self.resolvedPreset(for: application).supportsUserDataDir else { return nil }
    do {
      let resolution = Self.userDataDirectoryResolution(
        in: profile.argumentsText
      )
      if let configured = resolution.resolvedValue {
        let expanded = PathSpecificTildeExpander(
          homeDirectory:
            FileManager.default.homeDirectoryForCurrentUser.path
        ).argumentValue(
          configured,
          forOption: "--user-data-dir"
        )
        return try pathResolver.resolveExternalPath(expanded).url.path
      }
      if !resolution.occurrences.isEmpty {
        errorMessage = resolution.diagnostics
          .map(\.message)
          .joined(separator: "\n")
        return nil
      }
      guard profile.isolationOwnership.userData == .generated else {
        return nil
      }
      return try managedPaths(for: application, profile: profile).userData.url.path
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  @discardableResult
  func revealProfileFolder(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> Bool {
    do {
      return revealManagedFolder(
        try managedPaths(for: application, profile: profile).profileRoot
      )
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func revealCodexHome(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> Bool {
    do {
      let paths = try managedPaths(for: application, profile: profile)
      if let configured = Self.environmentValue("CODEX_HOME", in: profile) {
        let expanded = PathSpecificTildeExpander(
          homeDirectory:
            FileManager.default.homeDirectoryForCurrentUser.path
        ).environmentValue(configured, forKey: "CODEX_HOME")
        let external = try pathResolver.resolveExternalPath(expanded)
        if external.url.path != paths.codexHome.url.path {
          return revealExternalFolder(external)
        }
      }
      guard profile.isolationOwnership.codexHome == .generated else {
        return false
      }
      return revealManagedFolder(paths.codexHome)
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func revealUserData(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> Bool {
    do {
      let paths = try managedPaths(for: application, profile: profile)
      let resolution = Self.userDataDirectoryResolution(
        in: profile.argumentsText
      )
      if let configured = resolution.resolvedValue {
        let expanded = PathSpecificTildeExpander(
          homeDirectory:
            FileManager.default.homeDirectoryForCurrentUser.path
        ).argumentValue(
          configured,
          forOption: "--user-data-dir"
        )
        let external = try pathResolver.resolveExternalPath(expanded)
        if external.url.path != paths.userData.url.path {
          return revealExternalFolder(external)
        }
      }
      if !resolution.occurrences.isEmpty {
        errorMessage = resolution.diagnostics
          .map(\.message)
          .joined(separator: "\n")
        return false
      }
      guard profile.isolationOwnership.userData == .generated else {
        return false
      }
      return revealManagedFolder(paths.userData)
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
