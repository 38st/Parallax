import AppKit
import Foundation
import Observation

// MARK: - Health inspection support

extension LibraryStore {
  func profileHealthInput(
    for application: ManagedApplication,
    profile: LaunchProfile
  ) -> ProfileHealthInput {
    let expander = PathSpecificTildeExpander(
      homeDirectory:
        FileManager.default.homeDirectoryForCurrentUser.path
    )
    var isolationPaths: [ProfileIsolationHealthInput] = []
    switch profile.isolationOwnership.userData {
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
        profileHealthInput(for: application, profile: $0)
      }
    )
  }

  nonisolated static func isHealthyPath(
    _ path: ProfileHealthPathReport
  ) -> Bool {
    path.state == .existingDirectory
      || path.state == .missingCreatable
  }


  struct HealthCacheKey: Hashable {
    let application: ManagedApplication
    let profileID: UUID
  }

  struct HealthInspectionSource: Sendable {
    let application: ManagedApplication
    let profile: LaunchProfile
    let preset: AppPreset
    let applicationInput: ApplicationHealthInput
    let profileInputs: [ProfileHealthInput]
  }
}
