import AppKit
import Foundation
import Observation

extension LibraryStore {
  func addProfile() {
    addProfile(
      named: Self.nextProfileName(for: selectedApplication, templates: profileTemplateNames))
  }

  func addProfile(named name: String) {
    guard canMutateLibrary() else { return }
    guard let index = selectedApplicationIndex else { return }
    let validation = DisplayNameValidator.validate(name)
    guard let normalizedName = validation.normalized else {
      errorMessage = validation.issue?.message(for: .space)
      return
    }
    let template = profileTemplates.first {
      DisplayNameValidator.collisionKey($0.name)
        == DisplayNameValidator.collisionKey(normalizedName)
    }
    _ = addProfile(
      named: normalizedName,
      template: template,
      applicationIndex: index
    )
  }

  func addProfile(templateID: ProfileTemplate.ID) {
    guard canMutateLibrary() else { return }
    guard
      let index = selectedApplicationIndex,
      let template = profileTemplates.first(where: {
        $0.id == templateID
      })
    else {
      errorMessage = String(
        localized:
          "The selected space template no longer exists."
      )
      return
    }
    _ = addProfile(
      named: template.name,
      template: template,
      applicationIndex: index
    )
  }

  @discardableResult
  func createSpace(
    named name: String,
    templateID: ProfileTemplate.ID?,
    applicationID: ManagedApplication.ID
  ) -> LaunchProfile? {
    guard canMutateLibrary() else { return nil }
    guard
      let index = applications.firstIndex(where: {
        $0.id == applicationID
      })
    else {
      errorMessage = String(
        localized:
          "The selected app no longer exists. Your space was not created."
      )
      return nil
    }
    let validation = DisplayNameValidator.validate(name)
    guard let normalizedName = validation.normalized else {
      errorMessage = validation.issue?.message(for: .space)
      return nil
    }
    let template: ProfileTemplate?
    if let templateID {
      guard
        let resolved = profileTemplates.first(where: {
          $0.id == templateID
        })
      else {
        errorMessage = String(
          localized:
            "The selected space template no longer exists. Choose another option."
        )
        return nil
      }
      template = resolved
    } else {
      template = nil
    }
    return addProfile(
      named: normalizedName,
      template: template,
      applicationIndex: index
    )
  }

  @discardableResult
  func addProfile(
    named name: String,
    template: ProfileTemplate?,
    applicationIndex index: Int
  ) -> LaunchProfile? {
    let validation = DisplayNameValidator.validate(name)
    guard let normalizedName = validation.normalized else {
      errorMessage = validation.issue?.message(for: .space)
      return nil
    }
    guard let profileName = Self.uniqueProfileName(
      basedOn: normalizedName,
      existingProfiles: applications[index].profiles
    ) else {
      errorMessage = String(
        localized:
          "Parallax could not create a unique valid space name."
      )
      return nil
    }
    let profile: LaunchProfile
    do {
      profile = try self.profile(
        named: profileName,
        template: template,
        for: applications[index]
      )
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
    var candidate = applications
    candidate[index].profiles.append(profile)
    guard
      commit(
        candidate,
        selectedApplicationID: selectedApplicationID,
        selectedProfileID: profile.id
      )
    else {
      return nil
    }
    return profile
  }
}
