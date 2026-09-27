import AppKit
import Foundation
import Observation

extension LibraryStore {
  func useCodexHome(_ url: URL, for profile: LaunchProfile) {
    guard canMutateLibrary() else { return }
    guard
      let appIndex = selectedApplicationIndex,
      let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
    else { return }

    do {
      var updated = applications[appIndex].profiles[profileIndex]
      updated.environmentText = try Self.settingEnvironmentValue(
        "CODEX_HOME",
        to: url.path,
        in: updated.environmentText
      )
      updated.isolationOwnership.codexHome = .explicit
      var candidate = applications
      candidate[appIndex].profiles[profileIndex] = updated
      _ = commit(
        candidate,
        selectedApplicationID: selectedApplicationID,
        selectedProfileID: updated.id
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func profileDraftUsingCodexHome(
    _ url: URL,
    profile: LaunchProfile
  ) -> LaunchProfile {
    do {
      var updated = profile
      updated.environmentText = try Self.settingEnvironmentValue(
        "CODEX_HOME",
        to: url.path,
        in: updated.environmentText
      )
      updated.isolationOwnership.codexHome = .explicit
      return updated
    } catch {
      errorMessage = error.localizedDescription
      return profile
    }
  }

  func profileDraftApplyingRecommendedSettings(
    _ profile: LaunchProfile,
    for application: ManagedApplication
  ) -> LaunchProfile? {
    do {
      return try applyingRecommendedSettings(
        to: profile,
        for: application,
        replacingExistingIsolation: false
      )
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func applyRecommendedSettings(to profile: LaunchProfile) {
    guard canMutateLibrary() else { return }
    guard
      let appIndex = selectedApplicationIndex,
      let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
    else { return }

    do {
      var candidate = applications
      candidate[appIndex].profiles[profileIndex] = try applyingRecommendedSettings(
        to: profile,
        for: applications[appIndex],
        replacingExistingIsolation: false
      )
      _ = commit(
        candidate,
        selectedApplicationID: selectedApplicationID,
        selectedProfileID: selectedProfileID
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }

}
