import AppKit
import Foundation
import Observation

// MARK: - Profile construction and display names

extension LibraryStore {
  func defaultProfile(for application: ManagedApplication) throws -> LaunchProfile {
    let preset = Self.resolvedPreset(for: application)

    if preset.supportsUserDataDir {
      var profile = LaunchProfile(
        name: String(localized: "Personal")
      )
      let paths = try managedPaths(for: application, profile: profile)
      profile.argumentsText = ShellWordsParser.quote(
        "--user-data-dir=\(paths.userData.url.path)"
      )
      profile.environmentText =
        preset.needsCodexHome
        ? "CODEX_HOME=\(paths.codexHome.url.path)"
        : ""
      profile.isolationOwnership.userData = .generated
      if preset.needsCodexHome {
        profile.isolationOwnership.codexHome = .generated
      }
      return profile
    }

    return LaunchProfile(
      name: String(localized: "Default")
    )
  }


  static func uniqueImportedName(
    _ base: String,
    occupied: Set<String>
  ) -> String? {
    uniqueGeneratedDisplayName(
      basedOn: base,
      requiredSuffix:
        " \(String(localized: "Imported"))",
      occupied: occupied
    )
  }

  static func normalizedImportName(_ value: String) -> String {
    DisplayNameValidator.collisionKey(value)
  }

  static func resolvedPreset(for application: ManagedApplication) -> AppPreset {
    application.preset == .automatic
      ? AppPreset.detected(
        displayName: application.displayName, bundleIdentifier: application.bundleIdentifier)
      : application.preset
  }

  func configuredBaseRoot(for application: ManagedApplication) -> String {
    let trimmed = application.baseStoragePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return trimmed.isEmpty ? Self.defaultProfilesRootPath : application.baseStoragePath ?? ""
  }

  func profile(
    named name: String,
    template: ProfileTemplate?,
    for application: ManagedApplication
  ) throws -> LaunchProfile {
    var profile = LaunchProfile(
      name: name,
      argumentsText: template?.argumentsText ?? "",
      environmentText: template?.environmentText ?? "",
      notes: template?.notes ?? ""
    )
    profile = try applyingRecommendedSettings(
      to: profile,
      for: application
    )
    return profile
  }

  func applyingRecommendedSettings(
    to profile: LaunchProfile,
    for application: ManagedApplication,
    replacingExistingIsolation: Bool = false
  ) throws -> LaunchProfile {
    var migratedProfile = profile

    let preset = Self.resolvedPreset(for: application)
    let paths = try managedPaths(for: application, profile: migratedProfile)

    if preset.needsCodexHome,
      replacingExistingIsolation || Self.environmentValue("CODEX_HOME", in: profile) == nil
    {
      migratedProfile.environmentText = Self.settingEnvironmentValue(
        "CODEX_HOME",
        to: paths.codexHome.url.path,
        in: migratedProfile.environmentText
      )
      migratedProfile.isolationOwnership.codexHome = .generated
    }

    if preset.supportsUserDataDir,
      replacingExistingIsolation || Self.userDataDirectoryArgumentValue(in: profile) == nil
    {
      migratedProfile.argumentsText = Self.settingArgument(
        named: "--user-data-dir",
        to: paths.userData.url.path,
        in: migratedProfile.argumentsText
      )
      migratedProfile.isolationOwnership.userData = .generated
    }

    return migratedProfile
  }

  static func nextProfileName(for application: ManagedApplication?, templates: [String]) -> String {
    guard let application else {
      return String(localized: "New Space")
    }
    let existingNames = Set(application.profiles.map(\.name))

    if let templateName = templates.first(where: { !existingNames.contains($0) }) {
      return templateName
    }

    var index = 2
    while existingNames.contains(
      String(localized: "Space \(index)")
    ) {
      index += 1
    }
    return String(localized: "Space \(index)")
  }

  static func uniqueProfileName(
    basedOn name: String,
    existingProfiles: [LaunchProfile]
  ) -> String? {
    uniqueProfileName(
      basedOn: name,
      requiredSuffix: "",
      existingProfiles: existingProfiles
    )
  }

  private static func uniqueProfileName(
    basedOn name: String,
    requiredSuffix: String,
    existingProfiles: [LaunchProfile]
  ) -> String? {
    let occupied = Set(
      existingProfiles.map {
        DisplayNameValidator.collisionKey($0.name)
      }
    )
    return uniqueGeneratedDisplayName(
      basedOn: name,
      requiredSuffix: requiredSuffix,
      occupied: occupied
    )
  }

  private static func uniqueGeneratedDisplayName(
    basedOn name: String,
    requiredSuffix: String,
    occupied: Set<String>
  ) -> String? {
    guard
      let normalizedBase = DisplayNameValidator.normalized(
        name,
        maximumUTF8Bytes: .max
      )
    else {
      return nil
    }
    if let candidate = fittedProfileName(
      base: normalizedBase,
      suffix: requiredSuffix
    ), !occupied.contains(
      DisplayNameValidator.collisionKey(candidate)
    ) {
      return candidate
    }

    // At most one existing record can occupy each deterministic numeric
    // suffix, so count + 2 is a bounded collision-free search.
    for index in 2...(occupied.count + 2) {
      guard let candidate = fittedProfileName(
        base: normalizedBase,
        suffix: "\(requiredSuffix) \(index)"
      ) else {
        return nil
      }
      if !occupied.contains(
        DisplayNameValidator.collisionKey(candidate)
      ) {
        return candidate
      }
    }
    return nil
  }

  static func duplicateProfileName(
    basedOn sourceName: String,
    existingProfiles: [LaunchProfile]
  ) -> String? {
    let source = DisplayNameValidator.normalized(
      sourceName,
      maximumUTF8Bytes: .max
    )
    let copySuffix = " \(String(localized: "Copy"))"
    if let source,
      let generated = uniqueProfileName(
        basedOn: source,
        requiredSuffix: copySuffix,
        existingProfiles: existingProfiles
      )
    {
      return generated
    }
    return uniqueProfileName(
      basedOn: String(localized: "Space"),
      requiredSuffix: copySuffix,
      existingProfiles: existingProfiles
    )
  }

  private static func fittedProfileName(
    base: String,
    suffix: String
  ) -> String? {
    let byteLimit = DisplayNameValidator.maximumUTF8Bytes
    let suffixBytes = suffix.utf8.count
    guard suffixBytes < byteLimit else { return nil }

    var prefix = ""
    var prefixBytes = 0
    for character in base {
      let fragment = String(character)
      let fragmentBytes = fragment.utf8.count
      guard prefixBytes + fragmentBytes + suffixBytes
        <= byteLimit
      else { break }
      prefix.append(character)
      prefixBytes += fragmentBytes
    }
    let trimmedPrefix = prefix.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard !trimmedPrefix.isEmpty else { return nil }
    return DisplayNameValidator.normalized(
      trimmedPrefix + suffix
    )
  }

}
