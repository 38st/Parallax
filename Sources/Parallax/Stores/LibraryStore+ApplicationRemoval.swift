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
      if !applications[existingIndex].profiles.contains(where: { $0.id == selectedProfileID }) {
        selectedProfileID = nil
      }
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
    let initialProfile: LaunchProfile
    do {
      initialProfile = try defaultProfile(for: app)
      app.profiles = [initialProfile]
    } catch {
      errorMessage = error.localizedDescription
      return
    }

    var candidate = applications
    candidate.append(app)
    _ = commit(
      candidate,
      selectedApplicationID: app.id,
      selectedProfileID: initialProfile.id
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

  private struct ApplicationRemovalExecutionContext {
    let request: ApplicationRemovalRequest
    let repository: any LibraryRepositoryPersisting
    let backupStore: LibraryBackupStore
    let transactions: ApplicationRemovalTransactionCoordinator
  }

  private struct PreparedApplicationRemoval: Sendable {
    let transactionRequest: ApplicationRemovalTransactionRequest
    let commit: PreparedLibraryCommit
    let repository: any LibraryRepositoryPersisting
    let transactions: ApplicationRemovalTransactionCoordinator

    func execute() throws -> (
      ApplicationRemovalTransactionOutcome,
      LibraryRepositoryLoadOutcome
    ) {
      let outcome = try transactions.execute(
        transactionRequest,
        preparedCommit: commit,
        repository: repository
      )
      return (outcome, repository.load())
    }
  }

  func confirmApplicationRemoval() {
    guard canMutateLibrary() else { return }
    guard let context = applicationRemovalExecutionContext() else {
      finalizeUnavailableApplicationRemoval()
      return
    }

    var transactionID: UUID?
    var reservation: ProfileActivityReservation?
    defer { reservation?.release() }
    do {
      let acquired = try reserveApplicationRemoval(context.request)
      reservation = acquired
      let prepared = try prepareApplicationRemoval(context, reservation: acquired)
      transactionID = prepared.transactionRequest.transactionID
      let outcome = try prepared.transactions.execute(
        prepared.transactionRequest,
        preparedCommit: prepared.commit,
        repository: prepared.repository
      )
      try applyApplicationRemovalResult(
        outcome,
        repositoryOutcome: { prepared.repository.load() },
        request: context.request
      )
    } catch {
      finalizeApplicationRemovalFailure(error, request: context.request, transactionID: transactionID)
    }
  }

  func confirmApplicationRemovalAsync() async {
    guard canMutateLibrary() else { return }
    guard let context = applicationRemovalExecutionContext() else {
      finalizeUnavailableApplicationRemoval()
      return
    }

    var transactionID: UUID?
    var reservation: ProfileActivityReservation?
    defer { reservation?.release() }
    do {
      let acquired = try reserveApplicationRemoval(context.request)
      reservation = acquired
      let prepared = try prepareApplicationRemoval(context, reservation: acquired)
      transactionID = prepared.transactionRequest.transactionID
      isProfileDataOperationRunning = true
      defer { isProfileDataOperationRunning = false }
      let result = try await Task.detached(
        priority: .userInitiated
      ) {
        try prepared.execute()
      }.value
      try applyApplicationRemovalResult(
        result.0,
        repositoryOutcome: { result.1 },
        request: context.request
      )
    } catch {
      finalizeApplicationRemovalFailure(error, request: context.request, transactionID: transactionID)
    }
  }

  private func applicationRemovalExecutionContext()
    -> ApplicationRemovalExecutionContext?
  {
    guard
      let request = pendingApplicationRemoval,
      let repository,
      let backupStore,
      let applicationRemovalTransactions
    else {
      return nil
    }
    return ApplicationRemovalExecutionContext(
      request: request,
      repository: repository,
      backupStore: backupStore,
      transactions: applicationRemovalTransactions
    )
  }

  private func reserveApplicationRemoval(
    _ request: ApplicationRemovalRequest
  ) throws -> ProfileActivityReservation {
    do {
      return try profileActivityRegistry.acquireDataOperationLease(
        identities: Set(request.profiles.map { profile in
          ProfileActivityIdentity(
            applicationID: request.applicationID,
            applicationStorageID: request.applicationStorageID,
            profileID: profile.profileID,
            profileStorageID: profile.profileStorageID
          )
        })
      )
    } catch ProfileActivityRegistryError.profileAlreadyActive {
      throw ApplicationRemovalRequestError(.activeProfileData)
    }
  }

  private func prepareApplicationRemoval(
    _ context: ApplicationRemovalExecutionContext,
    reservation: ProfileActivityReservation
  ) throws -> PreparedApplicationRemoval {
    let request = context.request
    let currentTarget = try currentApplicationRemovalTarget(
      for: request
    )
    let activity = ApplicationRemovalActivitySnapshot(
      profiles: request.profiles.map { profile in
        ApplicationRemovalProfileActivity(
          applicationID: request.applicationID,
          applicationStorageID: request.applicationStorageID,
          profileID: profile.profileID,
          profileStorageID: profile.profileStorageID,
          state:
            profileActivityRegistry.isStorageActive(
              applicationStorageID: request.applicationStorageID,
              profileStorageID: profile.profileStorageID,
              excluding: reservation
            ) ? .active : .inactive
        )
      }
    )
    guard
      case .loaded(let snapshot) = context.repository.load(),
      snapshot.versionToken == request.repositoryVersion
    else {
      throw ApplicationRemovalRequestError(
        .staleRepositoryVersion
      )
    }
    _ = try request.validateExecutionTarget(
      currentTarget: currentTarget,
      activity: activity
    )
    let backupArtifact =
      try applicationRemovalBackupHook?(
        snapshot.originalBytes
      )
      ?? context.backupStore.createBackup(
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
        && $0.storageID == request.applicationStorageID)
    }
    let commit = try context.repository.prepare(
      candidate,
      expectedVersion: request.repositoryVersion
    )
    return PreparedApplicationRemoval(
      transactionRequest: ApplicationRemovalTransactionRequest(
        transactionID: UUID(),
        executionAuthorization: execution,
        profiles: request.profiles
      ),
      commit: commit,
      repository: context.repository,
      transactions: context.transactions
    )
  }

  private func applyApplicationRemovalResult(
    _ outcome: ApplicationRemovalTransactionOutcome,
    repositoryOutcome: () -> LibraryRepositoryLoadOutcome,
    request: ApplicationRemovalRequest
  ) throws {
    guard
      outcome.completion == .committed,
      case .loaded(let updated) = repositoryOutcome()
    else {
      throw ApplicationRemovalRequestError(
        .managedDataActionFailed
      )
    }
    applications = updated.applications
    libraryVersionToken = updated.versionToken
    sceneCoordinator.synchronize(with: applications)
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
  }

  private func finalizeUnavailableApplicationRemoval() {
    cancelApplicationRemoval()
    errorMessage = String(
      localized:
        "Application removal is unavailable because its transaction or backup services could not be initialized."
    )
  }

  private func finalizeApplicationRemovalFailure(
    _ error: Error,
    request: ApplicationRemovalRequest,
    transactionID: UUID?
  ) {
    let needsRecovery: Bool
    if let transactionID, let applicationRemovalTransactions {
      needsRecovery = (try? applicationRemovalTransactions.pendingTransactions().contains(transactionID)) ?? true
    } else {
      needsRecovery = false
    }
    var metadataChanged = false
    if let repository, case .loaded(let snapshot) = repository.load() {
      if snapshot.versionToken != libraryVersionToken,
         !snapshot.applications.contains(where: {
           $0.id == request.applicationID || $0.storageID == request.applicationStorageID
         }) {
        applications = snapshot.applications
        libraryVersionToken = snapshot.versionToken
        sceneCoordinator.synchronize(with: applications)
        loadState = .loaded
        metadataChanged = true
      }
    }
    if needsRecovery {
      if let repository, case .loaded(let snapshot) = repository.load() {
        presentPendingApplicationRemovalRecovery(error, loadedLibrary: snapshot)
      }
      libraryChangeBroadcaster?.publish(sourceSceneID: sceneID)
    } else if metadataChanged {
      publishLibraryChange()
    }
    pendingApplicationRemoval = nil
    isShowingApplicationRemovalConfirmation = needsRecovery
    errorMessage = error.localizedDescription
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
      let canonical = paths.profileRoot.url
      let canonicalForContainment = try pathResolver.resolveExternalPath(canonical.path).canonicalURL
      let identity =
        fileSystem.fileExists(at: canonical)
        ? try fileSystem.attributesOfItem(
          at: canonical
        ).identity
        : nil
      var externalPaths: [ApplicationRemovalExternalPath] = []
      func appendExternal(_ path: String?, role: ApplicationRemovalExternalPathRole) {
        guard let path,
          let resolved = try? pathResolver.resolveExternalPath(path).canonicalURL
        else { return }
        guard resolved.path != canonicalForContainment.path,
          !resolved.path.hasPrefix(canonicalForContainment.path + "/")
        else { return }
        externalPaths.append(ApplicationRemovalExternalPath(role: role, declaredPath: path))
      }
      let expander = PathSpecificTildeExpander(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path
      )
      if let configured = Self.userDataDirectoryResolution(in: profile.argumentsText).resolvedValue {
        appendExternal(
          expander.argumentValue(configured, forOption: "--user-data-dir"),
          role: .userData
        )
      }
      for (key, role) in [
        ("CODEX_HOME", ApplicationRemovalExternalPathRole.codexHome),
        ("CLAUDE_CONFIG_DIR", ApplicationRemovalExternalPathRole.claudeConfig),
      ] {
        if let configured = Self.environmentValue(key, in: profile) {
          appendExternal(expander.environmentValue(configured, forKey: key), role: role)
        }
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
  /// Startup calls this only after application-removal recovery fails against
  /// a loaded library. The library itself is healthy; Start Over cannot help.
  @discardableResult
  func presentPendingApplicationRemovalRecovery(
    _ error: any Error,
    loadedLibrary _: LibraryRepositorySnapshot
  ) -> Bool {
    guard infrastructureFailureMessage == nil,
      let applicationRemovalTransactions
    else { return false }
    invalidateApplicationRemovalRecoveryReviews()
    applicationRemovalTransactions.recoveryPresentation.pendingSceneMessages[sceneID] = error.localizedDescription
    applications = []
    sceneCoordinator.synchronize(with: applications)
    libraryVersionToken = nil
    migrationRequiredLibrary = nil
    migrationBlockers = []
    loadState = .recoveryRequired(originalBytes: nil, message: error.localizedDescription)
    pendingApplicationRemoval = nil
    errorMessage = error.localizedDescription
    Task { await refreshApplicationRemovalRecoveryReviews() }
    return true
  }

  /// Call before applying a new load outcome so an unrelated recovery failure
  /// cannot inherit the previous application-removal reason.
  func clearPendingApplicationRemovalRecoveryReason() {
    applicationRemovalTransactions?.recoveryPresentation.pendingSceneMessages.removeValue(forKey: sceneID)
  }

  var isPendingApplicationRemovalRecovery: Bool {
    guard infrastructureFailureMessage == nil,
      case .recoveryRequired(_, let message) = loadState
    else { return false }
    return applicationRemovalTransactions?.recoveryPresentation.pendingSceneMessages[sceneID] == message
  }

  var applicationRemovalRecoveryDetail: String? {
    guard isPendingApplicationRemovalRecovery else { return nil }
    return String(localized: "The library is intact, but an application removal still needs recovery. Reconnect unavailable storage and retry, or review the recorded file locations. Keep Files and Continue leaves every file in place and stops recovery for only the confirmed removal.")
  }

  var applicationRemovalRecoveryJournals: [ApplicationRemovalRecoveryJournalReview] {
    guard infrastructureFailureMessage == nil else { return [] }
    return applicationRemovalTransactions?.recoveryPresentation.inventory.pending ?? []
  }

  var pendingApplicationRemovalRecoveries: [ApplicationRemovalRecoveryReview] {
    applicationRemovalRecoveryJournals.compactMap(\.review)
  }

  var preservedApplicationRemovalFiles: [ApplicationRemovalPreservedFiles] {
    applicationRemovalTransactions?.recoveryPresentation.inventory.preserved ?? []
  }

  var applicationRemovalRecoveryListingError: String? {
    applicationRemovalTransactions?.recoveryPresentation.listingError
  }

  var isRefreshingApplicationRemovalRecovery: Bool {
    applicationRemovalTransactions?.recoveryPresentation.isRefreshing ?? false
  }

  func refreshApplicationRemovalRecoveryReviews() async {
    guard infrastructureFailureMessage == nil,
      let applicationRemovalTransactions
    else { return }
    let presentation = applicationRemovalTransactions.recoveryPresentation
    let task: Task<Result<ApplicationRemovalRecoveryInventory, Error>, Never>
    if let running = presentation.refreshTask {
      task = running
    } else {
      presentation.refreshGeneration &+= 1
      presentation.isRefreshing = true
      task = Task.detached(priority: .utility) {
        Result { try applicationRemovalTransactions.recoveryInventory() }
      }
      presentation.refreshTask = task
    }
    let generation = presentation.refreshGeneration
    let result = await task.value
    guard presentation.refreshGeneration == generation else { return }
    presentation.refreshTask = nil
    presentation.isRefreshing = false
    switch result {
    case .success(let inventory):
      presentation.inventory = inventory
      presentation.listingError = nil
    case .failure(let error):
      presentation.listingError = error.localizedDescription
    }
  }

  private func invalidateApplicationRemovalRecoveryReviews() {
    guard let presentation = applicationRemovalTransactions?.recoveryPresentation else { return }
    presentation.refreshGeneration &+= 1
    presentation.refreshTask = nil
  }

  func retryApplicationRemovalRecovery() {
    guard infrastructureFailureMessage == nil, let repository else { return }
    invalidateApplicationRemovalRecoveryReviews()
    reloadAfterApplicationRemovalRecovery(from: repository)
    Task { await refreshApplicationRemovalRecoveryReviews() }
  }

  private func reloadAfterApplicationRemovalRecovery(from repository: any LibraryRepositoryPersisting) {
    clearPendingApplicationRemovalRecoveryReason()
    errorMessage = nil
    load(from: repository)
    // Startup integration uses the same entry point for passive peer reloads.
    if case .recoveryRequired(_, let message) = loadState,
      applicationRemovalTransactions?.recoveryAttempts.contains(message: message) == true,
      case .loaded(let snapshot) = repository.load()
    {
      presentPendingApplicationRemovalRecovery(
        ApplicationRemovalRecoveryMessage(message: message), loadedLibrary: snapshot
      )
    }
  }

  func keepApplicationRemovalFilesAndContinue(_ review: ApplicationRemovalRecoveryReview) {
    guard infrastructureFailureMessage == nil,
      case .recoveryRequired = loadState,
      let repository, let applicationRemovalTransactions
    else { return }
    do {
      let result = try repository.tryWithExclusiveAccess { access in
        switch repository.load() {
        case .loaded, .missing: break
        default: throw ApplicationRemovalTransactionError(code: .libraryUnavailable)
        }
        try applicationRemovalTransactions.keepFilesAndContinue(
          review, repository: repository, access: access
        )
      }
      switch result {
      case .busy:
        errorMessage = LibraryOperationInProgressError().localizedDescription
      case .acquired:
        invalidateApplicationRemovalRecoveryReviews()
        reloadAfterApplicationRemovalRecovery(from: repository)
        pendingApplicationRemoval = nil
        isShowingApplicationRemovalConfirmation = true
        let locations: String = review.locations.map(\.path).joined(separator: "\n")
        libraryOperationStatusMessage = String(localized: "Recovery stopped for the confirmed removal. Files may remain at these locations: \(locations). Staged or archived files were not restored. If the application is still listed, opening its spaces may create empty data folders. Reopen Remove Application to review Preserved Files before using those spaces.")
        libraryChangeBroadcaster?.publish(sourceSceneID: sceneID)
        Task { await refreshApplicationRemovalRecoveryReviews() }
      }
    } catch {
      errorMessage = error.localizedDescription
      Task { await refreshApplicationRemovalRecoveryReviews() }
    }
  }

}
