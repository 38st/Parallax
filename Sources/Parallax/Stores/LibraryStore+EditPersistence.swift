import AppKit
import Foundation
import Observation

extension LibraryStore {
  func persistApplicationEdit(
    _ application: ManagedApplication,
    expectedVersion: LibraryVersionToken
  ) throws -> (
    persisted: ManagedApplication,
    version: LibraryVersionToken
  ) {
    guard canMutateLibrary() else {
      throw LibraryEditPersistenceFailure(
        message: errorMessage ?? String(localized: "The library is read-only until its load or recovery problem is resolved.")
      )
    }
    guard
      let repository,
      let index = applications.firstIndex(where: {
        $0.id == application.id
          && $0.storageID == application.storageID
      })
    else {
      throw LibraryEditPersistenceFailure(
        message: String(
          localized:
            "Application edit persistence is unavailable."
        )
      )
    }
    var candidate = applications
    candidate[index] = application
    let snapshot: LibraryRepositorySnapshot
    do {
      snapshot = try repository.save(candidate, expectedVersion: expectedVersion)
    } catch {
      handleLibrarySaveFailure(error)
      if case LibraryRepositoryError.staleWriter = error, let errorMessage {
        throw LibraryEditPersistenceFailure(message: errorMessage)
      }
      throw error
    }
    applications = snapshot.applications
    libraryVersionToken = snapshot.versionToken
    sceneCoordinator.synchronize(with: applications)
    loadState = .loaded
    publishLibraryChange()
    return (
      snapshot.applications[index],
      snapshot.versionToken
    )
  }

  func persistProfileEdit(
    _ profile: LaunchProfile,
    applicationID: UUID,
    expectedVersion: LibraryVersionToken
  ) throws -> (
    persisted: LaunchProfile,
    version: LibraryVersionToken
  ) {
    guard canMutateLibrary() else {
      throw LibraryEditPersistenceFailure(
        message: errorMessage ?? String(localized: "The library is read-only until its load or recovery problem is resolved.")
      )
    }
    guard
      let repository,
      let applicationIndex = applications.firstIndex(where: {
        $0.id == applicationID
      }),
      let profileIndex = applications[applicationIndex]
        .profiles.firstIndex(where: {
          $0.id == profile.id
            && $0.storageID == profile.storageID
        })
    else {
      throw LibraryEditPersistenceFailure(
        message: String(
          localized:
            "Profile edit persistence is unavailable."
        )
      )
    }
    var candidate = applications
    candidate[applicationIndex].profiles[profileIndex] = profile
    let snapshot: LibraryRepositorySnapshot
    do {
      snapshot = try repository.save(candidate, expectedVersion: expectedVersion)
    } catch {
      handleLibrarySaveFailure(error)
      if case LibraryRepositoryError.staleWriter = error, let errorMessage {
        throw LibraryEditPersistenceFailure(message: errorMessage)
      }
      throw error
    }
    applications = snapshot.applications
    libraryVersionToken = snapshot.versionToken
    sceneCoordinator.synchronize(with: applications)
    loadState = .loaded
    publishLibraryChange()
    return (
      snapshot.applications[applicationIndex].profiles[profileIndex],
      snapshot.versionToken
    )
  }

  func handleApplicationEditResult(
    _ result:
      LibraryEditApplyResult<ManagedApplicationEditField>
  ) -> Bool {
    switch result {
    case .applied, .noChanges:
      errorMessage = nil
      return true
    case .targetChanged:
      errorMessage = String(
        localized:
          "The application changed identity. Your draft was kept."
      )
    case .conflicts(let fields):
      errorMessage = String(
        localized:
          "Another window changed the same application fields: \(Self.editFieldList(fields.map(\.localizedLabel))). Your draft was kept."
      )
    case .persistenceFailed(let failure):
      errorMessage = failure.localizedDescription
    }
    return false
  }

  func handleProfileEditResult(
    _ result: LibraryEditApplyResult<LaunchProfileEditField>
  ) -> Bool {
    switch result {
    case .applied, .noChanges:
      errorMessage = nil
      return true
    case .targetChanged:
      errorMessage = String(
        localized:
          "The space changed identity. Your draft was kept."
      )
    case .conflicts(let fields):
      errorMessage = String(
        localized:
          "Another window changed the same profile fields: \(Self.editFieldList(fields.map(\.localizedLabel))). Your draft was kept."
      )
    case .persistenceFailed(let failure):
      errorMessage = failure.localizedDescription
    }
    return false
  }

  static func editFieldList(_ fields: [String]) -> String {
    LibraryLocalizedList.string(from: fields.sorted())
  }

}
