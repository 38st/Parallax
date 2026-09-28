import Foundation

extension LibraryStore {
  func validateStorageEnrollment(applicationStorageID: UUID, profileStorageID: UUID, configuredBaseRoot: String) async throws {
    let resolver = pathResolver
    try await Task.detached {
      _ = try resolver.resolve(configuredBaseRoot: configuredBaseRoot,
        applicationStorageID: applicationStorageID, profileStorageID: profileStorageID)
    }.value
  }

  func enrollPreparedStorageIfCurrent(_ source: LaunchConfigurationSource, paths: ResolvedProfilePaths) async {
    guard let repository, let application = applications.first(where: {
      $0.id == source.applicationID && $0.storageID == source.applicationStorageID
    }), configuredBaseRoot(for: application) == source.configuredBaseRoot else { return }
    let resolver = pathResolver
    let defaultRoot = Self.defaultProfilesRootPath
    await Task.detached {
      do {
        _ = try repository.tryWithExclusiveAccess { _ in
          guard case .loaded(let snapshot) = repository.load(),
            let current = snapshot.applications.first(where: {
              $0.id == source.applicationID && $0.storageID == source.applicationStorageID
            }) else { return }
          let configured = current.baseStoragePath ?? ""
          let currentRoot = configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultRoot : configured
          guard currentRoot == source.configuredBaseRoot else { return }
          try resolver.enroll(paths, applicationStorageID: source.applicationStorageID)
        }
      } catch { AppLog.persistence.error("Prepared launch volume enrollment failed: \(error.localizedDescription)") }
    }.value
  }
}
