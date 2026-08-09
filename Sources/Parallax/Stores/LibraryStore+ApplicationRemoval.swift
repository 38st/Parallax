import AppKit
import Foundation
import Observation

// MARK: - Application creation and removal

extension LibraryStore {
  func addApplication(at url: URL) {
    guard canMutateLibrary() else { return }
    guard url.pathExtension == "app" else {
      errorMessage = String(localized: "The selected item is not an application bundle.")
      return
    }

    guard fileSystem.fileExists(at: url), isDirectory(at: url) else {
      errorMessage = String(localized: "The selected application could not be found.")
      return
    }

    let appURL: URL
    do {
      appURL = try fileSystem.canonicalURL(for: url)
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    let bundle = Bundle(url: appURL)
    let proposedDisplayName =
      bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
      ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
      ?? appURL.deletingPathExtension().lastPathComponent
    let fallbackDisplayName =
      appURL.deletingPathExtension().lastPathComponent
    guard let displayName = DisplayNameValidator.normalized(
      proposedDisplayName
    ) ?? DisplayNameValidator.normalized(fallbackDisplayName) else {
      errorMessage = DisplayNameValidator.validate(
        proposedDisplayName
      ).issue?.message(for: .application)
      return
    }

    if let existingIndex = applications.firstIndex(where: {
      normalizedApplicationPath($0.appPath)
        == normalizedApplicationPath(appURL.path)
    }) {
      selectedApplicationID = applications[existingIndex].id
      selectedProfileID = applications[existingIndex].profiles.first?.id
      launchStatusMessage = String(localized: "\(displayName) is already in the library.")
      return
    }

    if let bundleIdentifier = bundle?.bundleIdentifier,
      let existing = applications.first(where: {
        $0.bundleIdentifier == bundleIdentifier
      })
    {
      if applicationNeedsRelink(existing) {
        assessApplicationRelink(
          existing,
          candidateURL: appURL
        )
      } else {
        errorMessage = String(
          localized:
            "Another stored application uses bundle identifier \(bundleIdentifier) at \(existing.appPath). Parallax did not merge the installations."
        )
      }
      return
    }

    let trimmedDefaultBase = settings.defaultBaseStoragePath.trimmingCharacters(
      in: .whitespacesAndNewlines)
    let resolvedBasePath = trimmedDefaultBase.isEmpty ? nil : trimmedDefaultBase
    var app = ManagedApplication(
      displayName: displayName,
      bundleIdentifier: bundle?.bundleIdentifier,
      appPath: appURL.path,
      preset: .automatic,
      baseStoragePath: resolvedBasePath,
      profiles: []
    )
    do {
      app.profiles = [try defaultProfile(for: app)]
    } catch {
      errorMessage = error.localizedDescription
      return
    }

    var candidate = applications
    candidate.append(app)
    _ = commit(
      candidate,
      selectedApplicationID: app.id,
      selectedProfileID: app.profiles.first?.id
    )
  }

  func removeSelectedApplication() {
    guard let application = selectedApplication else { return }
    beginApplicationRemoval(application)
  }

  func beginApplicationRemoval(
    _ application: ManagedApplication,
    dataChoice: ApplicationRemovalDataChoice = .keep
  ) {
    guard canMutateLibrary() else { return }
    do {
      pendingApplicationRemoval =
        try makeApplicationRemovalRequest(
          application,
          dataChoice: dataChoice
        )
      isShowingApplicationRemovalConfirmation = true
    } catch {
      pendingApplicationRemoval = nil
      isShowingApplicationRemovalConfirmation = false
      errorMessage = error.localizedDescription
    }
  }

  func updatePendingApplicationRemovalChoice(
    _ dataChoice: ApplicationRemovalDataChoice
  ) {
    guard
      let pendingApplicationRemoval,
      let application = applications.first(where: {
        $0.id == pendingApplicationRemoval.applicationID
          && $0.storageID
            == pendingApplicationRemoval
            .applicationStorageID
      })
    else {
      cancelApplicationRemoval()
      return
    }
    beginApplicationRemoval(
      application,
      dataChoice: dataChoice
    )
  }

  func cancelApplicationRemoval() {
    pendingApplicationRemoval = nil
    isShowingApplicationRemovalConfirmation = false
  }

  func confirmApplicationRemoval() {
    guard
      let request = pendingApplicationRemoval,
      let repository,
      let backupStore,
      let applicationRemovalTransactions
    else {
      cancelApplicationRemoval()
      errorMessage = String(
        localized:
          "Application removal is unavailable because its transaction or backup services could not be initialized."
      )
      return
    }

    do {
      let currentTarget = try currentApplicationRemovalTarget(
        for: request
      )
      let activity = ApplicationRemovalActivitySnapshot(
        profiles: request.profiles.map { profile in
          ApplicationRemovalProfileActivity(
            applicationID: request.applicationID,
            applicationStorageID:
              request.applicationStorageID,
            profileID: profile.profileID,
            profileStorageID:
              profile.profileStorageID,
            state:
              profileActivityRegistry
              .isStorageActive(
                applicationStorageID:
                  request
                  .applicationStorageID,
                profileStorageID:
                  profile.profileStorageID
              ) ? .active : .inactive
          )
        }
      )
      guard
        case .loaded(let snapshot) = repository.load(),
        snapshot.versionToken == request.repositoryVersion
      else {
        throw ApplicationRemovalRequestError(
          .staleRepositoryVersion
        )
      }
      let backupArtifact =
        try applicationRemovalBackupHook?(
          snapshot.originalBytes
        )
        ?? backupStore.createBackup(
          of: snapshot.originalBytes,
          reason: .destructiveRewrite
        )
      let priorBackup = try request.acceptPriorBackup(
        backupArtifact
      )
      let execution = try request.authorizeExecution(
        currentTarget: currentTarget,
        activity: activity,
        priorBackup: priorBackup
      )
      let candidate = applications.filter {
        !($0.id == request.applicationID
          && $0.storageID
            == request.applicationStorageID)
      }
      let prepared = try repository.prepare(
        candidate,
        expectedVersion: request.repositoryVersion
      )
      let outcome = try applicationRemovalTransactions.execute(
        ApplicationRemovalTransactionRequest(
          transactionID: UUID(),
          executionAuthorization: execution,
          profiles: request.profiles
        ),
        preparedCommit: prepared,
        repository: repository
      )
      guard
        outcome.completion == .committed,
        case .loaded(let updated) = repository.load()
      else {
        throw ApplicationRemovalRequestError(
          .managedDataActionFailed
        )
      }
      applications = updated.applications
      libraryVersionToken = updated.versionToken
      selectedApplicationID = applications.first?.id
      selectedProfileID =
        applications.first?.profiles.first?.id
      loadState = .loaded
      publishLibraryChange()
      errorMessage = nil
      launchStatusMessage =
        switch outcome.dataChoice {
        case .keep:
          String(
            localized:
              "Removed \(request.applicationName) and kept its managed profile data."
          )
        case .archive:
          String(
            localized:
              "Archived managed profile data and removed \(request.applicationName)."
          )
        case .delete:
          String(
            localized:
              "Deleted managed profile data and removed \(request.applicationName)."
          )
        }
      cancelApplicationRemoval()
    } catch {
      pendingApplicationRemoval = nil
      isShowingApplicationRemovalConfirmation = false
      errorMessage = error.localizedDescription
    }
  }

  func confirmApplicationRemovalAsync() async {
    guard !isProfileDataOperationRunning else {
      errorMessage = String(
        localized:
          "Wait for the current profile data operation to finish."
      )
      return
    }
    guard
      let request = pendingApplicationRemoval,
      let repository,
      let backupStore,
      let applicationRemovalTransactions
    else {
      cancelApplicationRemoval()
      errorMessage = String(
        localized:
          "Application removal is unavailable because its transaction or backup services could not be initialized."
      )
      return
    }

    do {
      let currentTarget = try currentApplicationRemovalTarget(
        for: request
      )
      let activity = ApplicationRemovalActivitySnapshot(
        profiles: request.profiles.map { profile in
          ApplicationRemovalProfileActivity(
            applicationID: request.applicationID,
            applicationStorageID:
              request.applicationStorageID,
            profileID: profile.profileID,
            profileStorageID:
              profile.profileStorageID,
            state:
              profileActivityRegistry
              .isStorageActive(
                applicationStorageID:
                  request.applicationStorageID,
                profileStorageID:
                  profile.profileStorageID
              ) ? .active : .inactive
          )
        }
      )
      guard
        case .loaded(let snapshot) = repository.load(),
        snapshot.versionToken == request.repositoryVersion
      else {
        throw ApplicationRemovalRequestError(
          .staleRepositoryVersion
        )
      }
      let backupArtifact =
        try applicationRemovalBackupHook?(
          snapshot.originalBytes
        )
        ?? backupStore.createBackup(
          of: snapshot.originalBytes,
          reason: .destructiveRewrite
        )
      let priorBackup = try request.acceptPriorBackup(
        backupArtifact
      )
      let execution = try request.authorizeExecution(
        currentTarget: currentTarget,
        activity: activity,
        priorBackup: priorBackup
      )
      let candidate = applications.filter {
        !($0.id == request.applicationID
          && $0.storageID
            == request.applicationStorageID)
      }
      let prepared = try repository.prepare(
        candidate,
        expectedVersion: request.repositoryVersion
      )
      let transactionRequest =
        ApplicationRemovalTransactionRequest(
          transactionID: UUID(),
          executionAuthorization: execution,
          profiles: request.profiles
        )
      isProfileDataOperationRunning = true
      defer { isProfileDataOperationRunning = false }
      let result = try await Task.detached(
        priority: .userInitiated
      ) {
        let outcome =
          try applicationRemovalTransactions.execute(
            transactionRequest,
            preparedCommit: prepared,
            repository: repository
          )
        return (outcome, repository.load())
      }.value
      guard
        result.0.completion == .committed,
        case .loaded(let updated) = result.1
      else {
        throw ApplicationRemovalRequestError(
          .managedDataActionFailed
        )
      }
      applications = updated.applications
      libraryVersionToken = updated.versionToken
      selectedApplicationID = applications.first?.id
      selectedProfileID =
        applications.first?.profiles.first?.id
      loadState = .loaded
      publishLibraryChange()
      errorMessage = nil
      launchStatusMessage =
        switch result.0.dataChoice {
        case .keep:
          String(
            localized:
              "Removed \(request.applicationName) and kept its managed profile data."
          )
        case .archive:
          String(
            localized:
              "Archived managed profile data and removed \(request.applicationName)."
          )
        case .delete:
          String(
            localized:
              "Deleted managed profile data and removed \(request.applicationName)."
          )
        }
      cancelApplicationRemoval()
    } catch {
      pendingApplicationRemoval = nil
      isShowingApplicationRemovalConfirmation = false
      errorMessage = error.localizedDescription
    }
  }

  func makeApplicationRemovalRequest(
    _ application: ManagedApplication,
    dataChoice: ApplicationRemovalDataChoice
  ) throws -> ApplicationRemovalRequest {
    guard
      let libraryVersionToken,
      applications.contains(where: {
        $0.id == application.id
          && $0.storageID == application.storageID
          && $0 == application
      })
    else {
      throw ApplicationRemovalRequestError(
        .targetRemoved
      )
    }
    return try ApplicationRemovalRequest(
      requestID: UUID(),
      sceneID: sceneID,
      applicationID: application.id,
      applicationStorageID: application.storageID,
      applicationName: application.displayName,
      profiles: try applicationRemovalProfileTargets(
        application
      ),
      dataChoice: dataChoice,
      repositoryVersion: libraryVersionToken
    )
  }

  func currentApplicationRemovalTarget(
    for request: ApplicationRemovalRequest
  ) throws -> ApplicationRemovalCurrentTarget? {
    guard
      let libraryVersionToken,
      let application = applications.first(where: {
        $0.id == request.applicationID
          && $0.storageID
            == request.applicationStorageID
      })
    else {
      return nil
    }
    return ApplicationRemovalCurrentTarget(
      applicationID: application.id,
      applicationStorageID: application.storageID,
      applicationName: application.displayName,
      profiles: try applicationRemovalProfileTargets(
        application
      ),
      repositoryVersion: libraryVersionToken
    )
  }

  func applicationRemovalProfileTargets(
    _ application: ManagedApplication
  ) throws -> [ApplicationRemovalProfileTarget] {
    try application.profiles.map { profile in
      let paths = try managedPaths(
        for: application,
        profile: profile
      )
      let root = paths.profileRoot.url
      let canonical =
        fileSystem.fileExists(at: root)
        ? try fileSystem.canonicalURL(for: root)
        : root.standardizedFileURL
      let identity =
        fileSystem.fileExists(at: canonical)
        ? try fileSystem.attributesOfItem(
          at: canonical
        ).identity
        : nil
      var externalPaths: [ApplicationRemovalExternalPath] = []
      if profile.isolationOwnership.userData
        != .generated,
        let path = userDataPath(
          for: application,
          profile: profile
        ),
        path != paths.userData.url.path
      {
        externalPaths.append(
          ApplicationRemovalExternalPath(
            role: .userData,
            declaredPath: path
          )
        )
      }
      if profile.isolationOwnership.codexHome
        != .generated,
        let path = codexHomePath(
          for: application,
          profile: profile
        ),
        path != paths.codexHome.url.path
      {
        externalPaths.append(
          ApplicationRemovalExternalPath(
            role: .codexHome,
            declaredPath: path
          )
        )
      }
      return ApplicationRemovalProfileTarget(
        profileID: profile.id,
        profileStorageID: profile.storageID,
        profileName: profile.name,
        managedProfileRoot:
          DestructiveActionPathSnapshot(
            canonicalURL: canonical,
            fileIdentity: identity
          ),
        externalPaths: externalPaths
      )
    }
  }
}
