import AppKit
import Foundation
import Observation

// MARK: - Health inspection support

extension LibraryStore {
  func profileHealthInput(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> ProfileHealthInput {
    let needsClaudeConfig = Self.resolvedPreset(for: application).needsClaudeConfig
    let userData = Self.userDataDirectoryResolution(in: profile.argumentsText)
    let hasBlankUserData =
      userData.occurrences.count == 1
      && userData.occurrences.first?.form == .equals
      && userData.occurrences.first?.value
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
    let userDataOwnership: IsolationPathOwnership =
      (needsClaudeConfig && (userData.occurrences.isEmpty || hasBlankUserData))
      ? .generated : profile.isolationOwnership.userData
    let expander = PathSpecificTildeExpander(
      homeDirectory:
        FileManager.default.homeDirectoryForCurrentUser.path
    )
    var isolationPaths: [ProfileIsolationHealthInput] = []
    switch userDataOwnership {
    case .generated:
      isolationPaths.append(
        ProfileIsolationHealthInput(
          role: .managedUserData,
          source: .managedUserData
        )
      )
    case .explicit, .legacyUnknown:
      if let configured =
        Self
        .userDataDirectoryArgumentValue(in: profile)
      {
        isolationPaths.append(
          ProfileIsolationHealthInput(
            role: .externalUserData,
            source: .external(
              expander.argumentValue(
                configured,
                forOption: "--user-data-dir"
              )
            )
          )
        )
      }
    }
    switch profile.isolationOwnership.codexHome {
    case .generated:
      isolationPaths.append(
        ProfileIsolationHealthInput(
          role: .managedCodexHome,
          source: .managedCodexHome
        )
      )
    case .explicit, .legacyUnknown:
      if let configured = Self.environmentValue(
        "CODEX_HOME",
        in: profile
      ) {
        isolationPaths.append(
          ProfileIsolationHealthInput(
            role: .externalCodexHome,
            source: .external(
              expander.environmentValue(
                configured,
                forKey: "CODEX_HOME"
              )
            )
          )
        )
      }
    }
    if needsClaudeConfig {
      if let configured = Self.environmentValue("CLAUDE_CONFIG_DIR", in: profile) {
        isolationPaths.append(
          ProfileIsolationHealthInput(
            role: .externalClaudeConfig,
            source: .external(
              expander.environmentValue(configured, forKey: "CLAUDE_CONFIG_DIR")
            )
          )
        )
      } else {
        isolationPaths.append(
          ProfileIsolationHealthInput(
            role: .managedClaudeConfig,
            source: .managedClaudeConfig
          )
        )
      }
    }
    isolationPaths.append(contentsOf: LaunchIsolationAnalyzer.presetHealthPaths(
      preset: Self.resolvedPreset(for: application), argumentsText: profile.argumentsText,
      environmentText: profile.environmentText, ownership: profile.isolationOwnership,
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
    ))
    return ProfileHealthInput(
      applicationID: application.id,
      profileID: profile.id,
      applicationStorageID: application.storageID,
      profileStorageID: profile.storageID,
      configuredBaseRoot: configuredBaseRoot(for: application),
      isolationPaths: isolationPaths
    )
  }

  func healthInspectionSource(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> HealthInspectionSource {
    HealthInspectionSource(
      application: application,
      profile: profile,
      preset: Self.resolvedPreset(for: application),
      applicationInput: ApplicationHealthInput(
        applicationID: application.id,
        applicationURL: URL(fileURLWithPath: application.appPath),
        expectedBundleIdentifier: application.bundleIdentifier
      ),
      profileInputs: application.profiles.map {
        profileHealthInput(for: application, profile: $0.id == profile.id ? profile : $0)
      }
    )
  }

  nonisolated static func isHealthyPath(
    _ path: ProfileHealthPathReport
  ) -> Bool {
    path.state == .existingDirectory
      || path.state == .missingCreatable
  }


  func healthCacheKey(for application: ManagedApplication, profile: LaunchProfile) -> HealthCacheKey
  {
    HealthCacheKey(
      applicationID: application.id, profileID: profile.id,
      fingerprint: recoveryFingerprint(application: application, profile: profile),
      activeProfileStorageIDs: profileActivityRegistry.activeProfileStorageIDs(
        applicationStorageID: application.storageID,
        profileStorageIDs: Set(application.profiles.map(\.storageID)).union([profile.storageID])))
  }

  struct HealthCacheKey: Hashable {
    let applicationID: UUID
    let profileID: UUID
    let fingerprint: LaunchConfigurationFingerprint
    let activeProfileStorageIDs: Set<UUID>
  }

  struct HealthInspectionSource: Sendable {
    let application: ManagedApplication
    let profile: LaunchProfile
    let preset: AppPreset
    let applicationInput: ApplicationHealthInput
    let profileInputs: [ProfileHealthInput]
  }
}
