import Foundation

// MARK: - Launch health presentation

extension LibraryStore {
  func healthItems(for application: ManagedApplication, profile: LaunchProfile) -> [(
    label: String, isHealthy: Bool
  )] {
    let key = healthCacheKey(for: application, profile: profile)
    if let cached = healthItemsCache[key] {
      return cached
    }
    if healthInspectionTasks[key] == nil {
      for (pendingKey, task) in healthInspectionTasks
      where pendingKey.applicationID == application.id
        && pendingKey.profileID == profile.id && pendingKey != key
      {
        task.cancel()
        healthInspectionTasks[pendingKey] = nil
      }
      let source = healthInspectionSource(
        for: application,
        profile: profile
      )
      let service = launchHealthService
      healthInspectionTasks[key] = Task { [weak self] in
        let items = await Task.detached {
          Self.inspectHealth(source, service: service)
        }.value
        guard !Task.isCancelled, let self else { return }
        self.healthItemsCache = self.healthItemsCache.filter {
          $0.key.applicationID != application.id
            || $0.key.profileID != profile.id
        }
        self.healthItemsCache[key] = items
        self.healthInspectionTasks[key] = nil
      }
    }
    if let prior = healthItemsCache.first(where: {
      $0.key.applicationID == application.id && $0.key.profileID == profile.id
    })?.value {
      return prior.map { item in
        item.label == String(localized: "Storage inactive")
          ? (item.label, !key.activeProfileStorageIDs.contains(profile.storageID)) : item
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
    let key = healthCacheKey(for: application, profile: profile)
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
      source.profileInputs, refreshActivity: false
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
    if preset.needsClaudeConfig {
      items.append(
        (
          String(localized: "Claude configuration folder"),
          (profileReport?.paths.first {
            $0.role == .managedClaudeConfig || $0.role == .externalClaudeConfig
          }.map(Self.isHealthyPath) ?? false)
            && profileReport?.issues.contains {
              !$0.claudeConfigCollisionProfileIDs.isEmpty
            } == false
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
