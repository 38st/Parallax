import AppKit
import Foundation
import Observation

extension LibraryStore {
  func stageKeychainSecret(
    _ secret: String,
    environmentKey: String,
    in profile: LaunchProfile
  ) async -> StagedProfileKeychainSecret? {
    let key = environmentKey.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let validation = LaunchEnvironmentParser.parse("\(key)=")
    guard
      validation.diagnostics.isEmpty,
      validation.entries.first?.name == key
    else {
      errorMessage = String(
        localized:
          "Enter a valid environment variable name."
      )
      return nil
    }
    guard !secret.isEmpty else {
      errorMessage = String(
        localized: "The Keychain secret cannot be empty."
      )
      return nil
    }

    let reference = EnvironmentSecretReference()
    do {
      var updated = profile
      updated.environmentText = try Self.settingEnvironmentValue(
        key,
        to: reference.token,
        in: updated.environmentText
      )
      try await secretStore.store(
        SecretValue(secret),
        for: reference
      )
      updated.sensitiveEnvironmentKeys = Array(
        Set(
          updated.sensitiveEnvironmentKeys
            + [key.uppercased()]
        )
      ).sorted()
      updated.isolationOwnership.codexHome =
        key == "CODEX_HOME"
        ? .explicit
        : updated.isolationOwnership.codexHome
      return StagedProfileKeychainSecret(
        profile: updated,
        reference: reference
      )
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  func profileDraftRemovingKeychainSecret(
    environmentKey: String,
    from profile: LaunchProfile
  ) -> (
    profile: LaunchProfile,
    reference: EnvironmentSecretReference
  )? {
    let key = environmentKey.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    guard
      let storedText = LaunchEnvironmentParser.parse(
        profile.environmentText
      ).effectiveValues[key],
      case .secretReference(let reference) =
        StoredEnvironmentValue(storedText: storedText)
    else {
      errorMessage = String(
        localized:
          "This environment value is not a Keychain reference."
      )
      return nil
    }
    do {
      var updated = profile
      updated.environmentText = try Self.settingEnvironmentValue(
        key,
        to: "",
        in: updated.environmentText
      )
      return (updated, reference)
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  @discardableResult
  func discardKeychainSecret(
    _ reference: EnvironmentSecretReference
  ) async -> Bool {
    do {
      try await secretStore.remove(reference)
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func storeKeychainSecret(
    _ secret: String,
    environmentKey: String,
    for profile: LaunchProfile
  ) async -> Bool {
    guard canMutateLibrary() else { return false }
    let key = environmentKey.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let validation = LaunchEnvironmentParser.parse("\(key)=")
    guard
      validation.diagnostics.isEmpty,
      validation.entries.first?.name == key
    else {
      errorMessage = String(
        localized:
          "Enter a valid environment variable name."
      )
      return false
    }
    guard !secret.isEmpty else {
      errorMessage = String(
        localized: "The Keychain secret cannot be empty."
      )
      return false
    }
    let reference = EnvironmentSecretReference()
    var attemptedSecretWrite = false
    do {
      guard let current = applications.flatMap(\.profiles).first(where: {
        $0.id == profile.id && $0.storageID == profile.storageID
      }) else {
        errorMessage = String(localized: "This space no longer exists.")
        return false
      }
      _ = try Self.settingEnvironmentValue(key, to: reference.token, in: current.environmentText)
      attemptedSecretWrite = true
      try await secretStore.store(
        SecretValue(secret),
        for: reference
      )
      guard
        let appIndex = applications.firstIndex(where: {
          $0.profiles.contains { $0.id == profile.id }
        }),
        let profileIndex = applications[appIndex].profiles
          .firstIndex(where: { $0.id == profile.id && $0.storageID == profile.storageID })
      else {
        _ = await discardUnreferencedKeychainSecret(reference)
        errorMessage = String(localized: "This space no longer exists.")
        return false
      }
      var candidate = applications
      var updated = candidate[appIndex].profiles[profileIndex]
      updated.environmentText = try Self.settingEnvironmentValue(
        key,
        to: reference.token,
        in: updated.environmentText
      )
      updated.sensitiveEnvironmentKeys = Array(
        Set(
          updated.sensitiveEnvironmentKeys
            + [key.uppercased()]
        )
      ).sorted()
      updated.isolationOwnership.codexHome =
        key == "CODEX_HOME"
        ? .explicit
        : updated.isolationOwnership.codexHome
      candidate[appIndex].profiles[profileIndex] = updated
      let priorApplications = applications
      guard
        commit(
          candidate,
          selectedApplicationID: selectedApplicationID,
          selectedProfileID: selectedProfileID
        )
      else {
        // A fresh, valid library without this reference proves it was not
        // published, including a stale writer rejected before any write.
        let referenceIsAbsent: Bool
        if let repository {
          if case .loaded(let snapshot) = repository.load() {
            referenceIsAbsent = !snapshot.applications.flatMap(\.profiles).contains {
              $0.environmentText.contains(reference.token) || $0.argumentsText.contains(reference.token)
            }
          } else {
            referenceIsAbsent = false
          }
        } else {
          referenceIsAbsent = (try? persistence.load()) == priorApplications
        }
        if referenceIsAbsent { _ = await discardUnreferencedKeychainSecret(reference) }
        return false
      }
      return true
    } catch {
      if attemptedSecretWrite {
        _ = await discardUnreferencedKeychainSecret(reference)
      }
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func removeKeychainSecret(
    environmentKey: String,
    for profile: LaunchProfile
  ) async -> Bool {
    guard canMutateLibrary() else { return false }
    guard
      let appIndex = applications.firstIndex(where: {
        $0.profiles.contains { $0.id == profile.id && $0.storageID == profile.storageID }
      }),
      let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id }),
      let removal = profileDraftRemovingKeychainSecret(
        environmentKey: environmentKey, from: applications[appIndex].profiles[profileIndex])
    else { return false }
    let original = applications[appIndex].profiles[profileIndex]
    var candidate = applications
    candidate[appIndex].profiles[profileIndex] = removal.profile
    guard commit(candidate, selectedApplicationID: selectedApplicationID, selectedProfileID: selectedProfileID)
    else { return false }
    if editorDraftRegistry.isRetained(removal.reference, by: self) {
      return true
    }
    if await discardUnreferencedKeychainSecret(removal.reference) { return true }
    if editorDraftRegistry.isRetained(removal.reference, by: self) { return true }
    let deletionError = errorMessage
    if let currentApp = applications.firstIndex(where: { $0.id == candidate[appIndex].id }),
      let currentProfile = applications[currentApp].profiles.firstIndex(where: {
        $0.id == original.id && $0.storageID == original.storageID
      }),
      !applications[currentApp].profiles[currentProfile].environmentText.contains(removal.reference.token),
      !applications[currentApp].profiles[currentProfile].argumentsText.contains(removal.reference.token)
    {
      var restored = applications
      do {
        var updated = restored[currentApp].profiles[currentProfile]
        let key = environmentKey.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.environmentText = try Self.settingEnvironmentValue(
          key, to: removal.reference.token, in: updated.environmentText)
        updated.sensitiveEnvironmentKeys = Array(Set(updated.sensitiveEnvironmentKeys + [key.uppercased()])).sorted()
        if key == "CODEX_HOME" {
          updated.isolationOwnership.codexHome = original.isolationOwnership.codexHome
        }
        restored[currentApp].profiles[currentProfile] = updated
      } catch {
        errorMessage = error.localizedDescription
        return false
      }
      guard commit(
        restored,
        selectedApplicationID: selectedApplicationID,
        selectedProfileID: selectedProfileID
      ) else { return false }
    }
    errorMessage = deletionError
    return false
  }
}
