import Foundation

// MARK: - Managed folder paths and actions

extension LibraryStore {
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
