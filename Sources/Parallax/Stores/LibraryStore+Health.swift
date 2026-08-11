import Foundation

// MARK: - Launch health presentation

extension LibraryStore {
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
}
