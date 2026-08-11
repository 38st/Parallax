import AppKit
import Foundation
import Observation

// MARK: - Settings and data authority

extension LibraryStore {
  func canUseSettingsAuthority() -> Bool {
    guard settings.canProvideVerifiedSettings else {
      errorMessage = settings.hasPendingVersionedMutations
        ? String(
          localized:
            "Wait for the current settings change to finish before apps, imports, or spaces are changed or opened."
        )
        : String(
          localized:
            "Settings require recovery before apps, imports, or spaces can be changed or opened."
        )
      return false
    }
    return true
  }

  func externalDataHandling(
    for profile: LaunchProfile
  ) -> ProfileExternalDataHandling {
    var configuredKinds: [String] = []
    if profile.isolationOwnership.userData != .generated,
      hasUserDataDirectoryConfigured(in: profile)
    {
      configuredKinds.append("user-data-dir")
    }
    if profile.isolationOwnership.codexHome != .generated,
      hasCodexHomeConfigured(in: profile)
    {
      configuredKinds.append("CODEX_HOME")
    }
    return configuredKinds.isEmpty
      ? .notConfigured
      : .configurationOnly(configuredPaths: configuredKinds)
  }

  func canMutateLibrary() -> Bool {
    guard canUseSettingsAuthority() else { return false }
    guard !isProfileDataOperationRunning else {
      errorMessage = String(
        localized:
          "Wait for the current profile data operation to finish."
      )
      return false
    }
    guard case .loaded = loadState else {
      errorMessage = String(
        localized: "The library is read-only until its load or recovery problem is resolved."
      )
      return false
    }
    guard migrationRequiredLibrary == nil else {
      errorMessage = String(
        localized: "This legacy library is read-only until its profile data is migrated."
      )
      return false
    }
    return true
  }

  func revealManagedFolder(_ path: any ManagedMutationPath) -> Bool {
    do {
      let target = path.url.standardizedFileURL
      let revealURL: URL
      if fileSystem.fileExists(at: target) {
        let attributes = try fileSystem.attributesOfItem(at: target)
        guard attributes.kind == .directory else {
          throw ManagedPathError(.targetNotDirectory, path: target.path)
        }
        revealURL = target
      } else {
        var parent = target.deletingLastPathComponent()
        while !fileSystem.fileExists(at: parent),
          parent.path != "/"
        {
          parent.deleteLastPathComponent()
        }
        guard fileSystem.fileExists(at: parent) else {
          throw ManagedPathError(.baseRootUnavailable, path: target.path)
        }
        revealURL = parent
        launchStatusMessage = String(
          localized: "The managed folder does not exist. Revealed its nearest existing parent."
        )
      }
      NSWorkspace.shared.activateFileViewerSelecting([revealURL])
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func revealExternalFolder(_ path: ExternalIsolationPath) -> Bool {
    guard isDirectory(at: path.url) else {
      errorMessage = String(localized: "The external isolation folder does not exist.")
      return false
    }
    NSWorkspace.shared.activateFileViewerSelecting([path.url])
    return true
  }

  func archiveProfileData(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) throws -> ManagedArchiveEntryPath? {
    let paths = try managedPaths(for: application, profile: profile)
    guard fileSystem.fileExists(at: paths.profileRoot.url) else { return nil }
    return try moveToArchive(
      source: paths.profileRoot,
      archiveRoot: paths.archiveRoot
    )
  }

  func deleteProfileData(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) throws {
    let profileRoot = try managedPaths(
      for: application,
      profile: profile
    ).profileRoot
    guard fileSystem.fileExists(at: profileRoot.url) else { return }
    try removeManagedItem(at: profileRoot)
  }


  func moveToArchive(
    source: ManagedProfileRootPath,
    archiveRoot: ManagedArchiveRootPath
  ) throws -> ManagedArchiveEntryPath {
    var destination = archiveRoot.entry()
    while fileSystem.fileExists(at: destination.url) {
      destination = archiveRoot.entry()
    }
    let archiveDirectoryURL = try pathResolver.revalidateForMutation(archiveRoot)
    try fileSystem.createDirectory(
      at: archiveDirectoryURL,
      withIntermediateDirectories: true
    )
    try moveManagedItem(at: source, to: destination)
    return destination
  }

  func removeManagedItem(at path: any ManagedMutationPath) throws {
    let url = try pathResolver.revalidateForMutation(path)
    try fileSystem.removeItem(at: url)
  }

  func copyManagedItem(
    at source: any ManagedMutationPath,
    to destination: any ManagedMutationPath
  ) throws {
    let sourceURL = try pathResolver.revalidateForMutation(source)
    let destinationURL = try pathResolver.revalidateForMutation(destination)
    try fileSystem.copyItem(at: sourceURL, to: destinationURL)
  }

  func moveManagedItem(
    at source: any ManagedMutationPath,
    to destination: any ManagedMutationPath
  ) throws {
    let sourceURL = try pathResolver.revalidateForMutation(source)
    let destinationURL = try pathResolver.revalidateForMutation(destination)
    try fileSystem.moveItem(at: sourceURL, to: destinationURL)
  }

}
