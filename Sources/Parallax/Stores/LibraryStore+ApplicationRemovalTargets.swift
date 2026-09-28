import AppKit
import Foundation
import Observation

extension LibraryStore {
  func currentApplicationRemovalTarget(
    for request: ApplicationRemovalRequest
  ) throws -> ApplicationRemovalCurrentTarget? {
    guard
      let libraryVersionToken,
      let application = applications.first(where: {
        $0.id == request.applicationID
          && $0.storageID
            == request.applicationStorageID
      })
    else {
      return nil
    }
    return ApplicationRemovalCurrentTarget(
      applicationID: application.id,
      applicationStorageID: application.storageID,
      applicationName: application.displayName,
      profiles: try applicationRemovalProfileTargets(
        application
      ),
      repositoryVersion: libraryVersionToken
    )
  }

  func applicationRemovalProfileTargets(
    _ application: ManagedApplication
  ) throws -> [ApplicationRemovalProfileTarget] {
    try application.profiles.map { profile in
      let paths = try managedPaths(
        for: application,
        profile: profile
      )
      let canonical = paths.profileRoot.url
      let canonicalForContainment = try pathResolver.resolveExternalPath(canonical.path).canonicalURL
      let identity =
        fileSystem.fileExists(at: canonical)
        ? try fileSystem.attributesOfItem(
          at: canonical
        ).identity
        : nil
      var externalPaths: [ApplicationRemovalExternalPath] = []
      func appendExternal(_ path: String?, role: ApplicationRemovalExternalPathRole) {
        guard let path,
          let resolved = try? pathResolver.resolveExternalPath(path).canonicalURL
        else { return }
        guard resolved.path != canonicalForContainment.path,
          !resolved.path.hasPrefix(canonicalForContainment.path + "/")
        else { return }
        externalPaths.append(ApplicationRemovalExternalPath(role: role, declaredPath: path))
      }
      let expander = PathSpecificTildeExpander(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
      )
      if let configured = Self.userDataDirectoryResolution(in: profile.argumentsText).resolvedValue {
        appendExternal(
          expander.argumentValue(configured, forOption: "--user-data-dir"),
          role: .userData
        )
      }
      for folder in PresetIsolationFolder.allCases {
        if let value = folder.resolve(in: profile.arguments).value {
          let expanded = value == "~" ? FileManager.default.homeDirectoryForCurrentUser.path
            : value.hasPrefix("~/") ? FileManager.default.homeDirectoryForCurrentUser.path + String(value.dropFirst()) : value
          appendExternal(expanded, role: folder == .firefoxProfile ? .firefoxProfile : .extensions)
        }
      }
      for (key, role) in [
        ("CODEX_HOME", ApplicationRemovalExternalPathRole.codexHome),
        ("CLAUDE_CONFIG_DIR", ApplicationRemovalExternalPathRole.claudeConfig),
        ("XRE_PROFILE_PATH", ApplicationRemovalExternalPathRole.firefoxProfile),
      ] {
        if let configured = Self.environmentValue(key, in: profile) {
          let expanded = key == "XRE_PROFILE_PATH"
            ? StorageRelocationIsolationField.firefoxProfile.expanded(configured, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
            : expander.environmentValue(configured, forKey: key)
          appendExternal(expanded, role: role)
        }
      }
      return ApplicationRemovalProfileTarget(
        profileID: profile.id,
        profileStorageID: profile.storageID,
        profileName: profile.name,
        managedProfileRoot:
          DestructiveActionPathSnapshot(
            canonicalURL: canonical,
            fileIdentity: identity
          ),
        externalPaths: externalPaths
      )
    }
  }
}
