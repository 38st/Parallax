import AppKit
import Foundation
import Observation

extension LibraryStore {
  func validateApplicationRemovalDependents(
    _ application: ManagedApplication,
    dataChoice: ApplicationRemovalDataChoice
  ) throws {
    guard dataChoice != .keep else { return }
    let source = try pathResolver.resolveApplication(
      configuredBaseRoot: configuredBaseRoot(for: application),
      applicationStorageID: application.storageID
    )
    let roots = try [source.applicationRoot.url, source.applicationArchiveRoot.url].map {
      try pathResolver.resolveExternalPath($0.path).canonicalURL.pathComponents
    }
    for other in applications where other.id != application.id {
      for profile in other.profiles {
        let values: [(StorageRelocationIsolationField, String?)] = [
          (.userData, Self.userDataDirectoryResolution(in: profile.argumentsText).resolvedValue),
          (.firefoxProfile, PresetIsolationFolder.firefoxProfile.resolve(in: profile.arguments).value),
          (.extensions, PresetIsolationFolder.extensions.resolve(in: profile.arguments).value),
          (.firefoxProfile, Self.environmentValue("XRE_PROFILE_PATH", in: profile)),
          (.codexHome, Self.environmentValue("CODEX_HOME", in: profile)),
          (.claudeConfig, Self.environmentValue("CLAUDE_CONFIG_DIR", in: profile))
        ]
        for (field, value) in values {
          guard let value else { continue }
          let expanded = field.expanded(value, homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
          guard let path = try? pathResolver.resolveExternalPath(expanded).canonicalURL else { continue }
          if roots.contains(where: { path.pathComponents.starts(with: $0) }) {
            throw ApplicationRemovalRequestError(.dependentProfileData)
          }
        }
      }
    }
  }

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
        application, dataChoice: request.dataChoice
      ),
      repositoryVersion: libraryVersionToken
    )
  }

  func applicationRemovalProfileTargets(
    _ application: ManagedApplication,
    dataChoice: ApplicationRemovalDataChoice = .delete
  ) throws -> [ApplicationRemovalProfileTarget] {
    try application.profiles.map { profile in
      var storageUnavailable = false
      let canonical: URL
      let identity: FileSystemObjectIdentity?
      do {
        let resolved = try managedPaths(for: application, profile: profile).profileRoot.url
        let resolvedIdentity = fileSystem.fileExists(at: resolved)
          ? try fileSystem.attributesOfItem(at: resolved).identity : nil
        canonical = resolved
        identity = resolvedIdentity
      } catch let error as ManagedPathError where dataChoice == .keep && error.code == .baseRootUnavailable {
        // Keep records the configured location without claiming access to the missing volume.
        canonical = URL(fileURLWithPath: profileFolderDisplayPath(for: application, profile: profile), isDirectory: true)
        identity = nil
        storageUnavailable = true
      }
      let canonicalForContainment = storageUnavailable ? canonical.standardizedFileURL
        : try pathResolver.resolveExternalPath(canonical.path).canonicalURL
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
