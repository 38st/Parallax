import AppKit
import Foundation
import Observation

// MARK: - Application lifecycle

extension LibraryStore {
  func beginAddingApplication() {
    guard canMutateLibrary() else { return }
    isShowingAppImporter = true
  }

  func applicationNeedsRelink(
    _ application: ManagedApplication
  ) -> Bool {
    !fileSystem.fileExists(
      at: URL(
        fileURLWithPath: application.appPath,
        isDirectory: true
      )
    )
  }

  func assessApplicationRelink(
    _ application: ManagedApplication,
    candidateURL: URL
  ) {
    guard canMutateLibrary() else { return }
    guard let baselineVersion = libraryVersionToken else {
      errorMessage = String(
        localized:
          "Application relink is unavailable until the library is loaded."
      )
      return
    }
    let request = ApplicationRelinkRequest(
      targetApplication: application,
      candidateURL: candidateURL,
      otherApplications: applications
    )
    let coordinator = ApplicationRelinkCoordinator(
      fileSystem: fileSystem
    )
    Task { [weak self] in
      let assessment = await coordinator.assess(request)
      guard let self else { return }
      guard
        libraryVersionToken == baselineVersion,
        applications.first(where: {
          $0.id == application.id
        }) == application
      else {
        errorMessage = String(
          localized:
            "The application changed while its new location was being verified. Try again."
        )
        return
      }
      guard let proposal = assessment.proposal else {
        let conflictNames = assessment.conflicts
          .map(\.applicationName)
          .joined(separator: ", ")
        errorMessage =
          conflictNames.isEmpty
          ? String(
            localized:
              "The selected application cannot repair this record because its bundle identity or path did not match."
          )
          : String.localizedStringWithFormat(
            String(localized: "application-relink-conflict-count", defaultValue: "The selected application conflicts with %lld existing records: %@. No application was changed.", bundle: PackagedRuntimeResources.bundle),
            Int64(assessment.conflicts.count), conflictNames
          )
        return
      }
      pendingApplicationRelink = PendingApplicationRelink(
        proposal: proposal,
        baselineVersion: baselineVersion
      )
      isShowingApplicationRelinkConfirmation = true
    }
  }

  func cancelApplicationRelink() {
    pendingApplicationRelink = nil
    isShowingApplicationRelinkConfirmation = false
  }

  func confirmApplicationRelink() {
    guard let pendingApplicationRelink else {
      cancelApplicationRelink()
      return
    }
    let proposal = pendingApplicationRelink.proposal
    guard
      applyApplicationEdit(
        draft: proposal.application,
        baseline: proposal.originalApplication,
        baselineVersion:
          pendingApplicationRelink.baselineVersion
      )
    else {
      isShowingApplicationRelinkConfirmation = false
      self.pendingApplicationRelink = nil
      return
    }
    selectedApplicationID = proposal.application.id
    launchStatusMessage = String(
      localized:
        "Updated the application location for \(proposal.application.displayName)."
    )
    cancelApplicationRelink()
  }

  func storagePath(for application: ManagedApplication) -> String {
    configuredBaseRoot(for: application)
  }

  func prepareStorageRelocation(
    for application: ManagedApplication,
    to destinationBaseRoot: URL
  ) {
    guard canMutateLibrary() else { return }
    guard
      let storageRelocationCoordinator,
      let libraryVersionToken
    else {
      errorMessage = String(
        localized:
          "Storage relocation is unavailable because its transaction services could not be initialized."
      )
      return
    }

    guard !isStorageRelocationRunning else {
      errorMessage = StorageRelocationError(.preparationInProgress).localizedDescription
      return
    }
    guard let application = applications.first(where: { $0.id == application.id }) else {
      errorMessage = StorageRelocationError(.stalePreview).localizedDescription
      return
    }
    guard canChangeSharedHistoryData(application: application) else { return }
    let preparing: StorageRelocationPreview
    do {
      preparing = try storageRelocationCoordinator.preparingPreview(application: application,
        destinationBaseRoot: destinationBaseRoot.path, expectedVersion: libraryVersionToken)
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    let cancellation = StorageRelocationCancellation()
    var coordinator = storageRelocationCoordinator
    coordinator.preparationCancellation = cancellation
    let preparationCoordinator = coordinator
    let currentApplications = applications
    storageRelocationCancellation = cancellation
    storageRelocationPreview = preparing
    errorMessage = nil
    storageRelocationProgress = .preparing
    storageRelocationTask = Task { [weak self] in
      let result = await Task.detached(priority: .userInitiated) {
        Result {
          try preparationCoordinator.prepare(
            application: application,
            destinationBaseRoot: destinationBaseRoot.path,
            expectedVersion: libraryVersionToken,
            applications: currentApplications, requestID: preparing.requestID
          )
        }
      }.value
      guard let self, self.storageRelocationCancellation === cancellation else { return }
      self.storageRelocationTask = nil
      self.storageRelocationCancellation = nil
      self.storageRelocationProgress = nil
      guard !cancellation.isCancelled else { return }
      guard self.libraryVersionToken == libraryVersionToken,
        self.applications.first(where: { $0.id == application.id }) == application
      else {
        self.storageRelocationPreview = nil
        self.errorMessage = StorageRelocationError(.stalePreview).localizedDescription
        return
      }
      switch result {
      case .success(let preview): self.storageRelocationPreview = preview
      case .failure(let error):
        self.storageRelocationPreview = nil
        self.errorMessage = error.localizedDescription
      }
    }
  }

  func cancelStorageRelocation(_ preview: StorageRelocationPreview) {
    guard storageRelocationPreview?.requestID == preview.requestID else {
      return
    }
    if let storageRelocationCancellation {
      storageRelocationCancellation.cancel()
      if preview.isPreparing {
        self.storageRelocationCancellation = nil
        storageRelocationTask = nil
        storageRelocationPreview = nil
        storageRelocationProgress = nil
      }
      return
    }
    storageRelocationPreview = nil
    storageRelocationProgress = nil
  }

  func beginStorageRelocation(_ preview: StorageRelocationPreview) {
    guard !isStorageRelocationRunning else { return }
    guard canMutateLibrary() else { return }
    guard
      storageRelocationPreview?.requestID == preview.requestID,
      let storageRelocationCoordinator,
      let repository,
      let libraryVersionToken,
      libraryVersionToken == preview.expectedVersion,
      let applicationIndex = applications.firstIndex(where: {
        $0.id == preview.applicationID
      })
    else {
      errorMessage = String(
        localized: "The storage relocation preview is stale. Review the destination again."
      )
      return
    }

    guard canChangeSharedHistoryData(application: applications[applicationIndex]) else { return }
    var candidate = applications
    candidate[applicationIndex] = preview.relocatedApplication
    let prepared: PreparedLibraryCommit
    do {
      prepared = try repository.prepare(
        candidate,
        expectedVersion: libraryVersionToken
      )
    } catch {
      errorMessage = error.localizedDescription
      return
    }

    let reservation: ProfileActivityReservation
    do {
      reservation = try profileActivityRegistry.acquireDataOperationLease(
        identities: storageRelocationCoordinator.activityIdentities(preview.originalApplication)
      )
    } catch {
      errorMessage = error.localizedDescription
      return
    }
    let coordinator = storageRelocationCoordinator.excluding(reservation)
    let cancellation = StorageRelocationCancellation()
    storageRelocationCancellation = cancellation
    storageRelocationProgress = .preparing
    errorMessage = nil
    storageRelocationTask = Task { [weak self] in
      let result = await Task.detached(
        priority: .userInitiated
      ) {
        do {
          let outcome = try coordinator.execute(
            preview,
            preparedCommit: prepared,
            repository: repository,
            cancellation: cancellation
          ) { progress in
            Task { @MainActor [weak self] in
              guard
                self?.storageRelocationPreview?.requestID
                  == preview.requestID,
                self?.storageRelocationCancellation
                  === cancellation
              else { return }
              self?.storageRelocationProgress = progress
            }
          }
          return
            BackgroundStorageRelocationResult
            .succeeded(outcome)
        } catch {
          return BackgroundStorageRelocationResult.failed(
            code: (error as? StorageRelocationError)?.code,
            message: error.localizedDescription
          )
        }
      }.value

      guard let self else {
        await Task.detached(priority: .userInitiated) { reservation.release() }.value
        return
      }
      switch result {
      case .succeeded(let outcome):
        self.applications = candidate
        self.applications[applicationIndex] = outcome.application
        self.libraryVersionToken = outcome.versionToken
        self.preserveStorageRelocationSelection()
        self.storageRelocationPreview = nil
        self.storageRelocationProgress = .completed
        self.publishLibraryChange()
        let applicationName: String = outcome.application.displayName
        self.launchStatusMessage = String(
          localized: "Moved managed storage for \(applicationName)."
        )
      case .failed(let code, let message):
        self.finishFailedStorageRelocation(
          preview,
          code: code,
          operationMessage: message,
          coordinator: coordinator,
          repository: repository
        )
      }
      await Task.detached(priority: .userInitiated) { reservation.release() }.value
      self.storageRelocationTask = nil
      self.storageRelocationCancellation = nil
    }
  }

  @discardableResult
  func confirmStorageRelocation(
    _ preview: StorageRelocationPreview
  ) -> Bool {
    guard canMutateLibrary() else { return false }
    guard !preview.isPreparing else { return false }
    guard
      storageRelocationPreview?.requestID == preview.requestID,
      let storageRelocationCoordinator,
      let repository,
      let libraryVersionToken,
      libraryVersionToken == preview.expectedVersion,
      let applicationIndex = applications.firstIndex(where: {
        $0.id == preview.applicationID
      })
    else {
      errorMessage = String(
        localized: "The storage relocation preview is stale. Review the destination again."
      )
      return false
    }

    guard canChangeSharedHistoryData(application: applications[applicationIndex]) else { return false }
    var candidate = applications
    candidate[applicationIndex] = preview.relocatedApplication

    var reservation: ProfileActivityReservation?
    var coordinator = storageRelocationCoordinator
    defer { reservation?.release() }
    do {
      let acquired = try profileActivityRegistry.acquireDataOperationLease(
        identities: coordinator.activityIdentities(preview.originalApplication)
      )
      reservation = acquired
      coordinator = coordinator.excluding(acquired)
      let prepared = try repository.prepare(
        candidate,
        expectedVersion: libraryVersionToken
      )
      let outcome = try coordinator.execute(
        preview,
        preparedCommit: prepared,
        repository: repository
      ) { [weak self] progress in
        self?.storageRelocationProgress = progress
      }
      applications = candidate
      applications[applicationIndex] = outcome.application
      self.libraryVersionToken = outcome.versionToken
      preserveStorageRelocationSelection()
      storageRelocationPreview = nil
      storageRelocationProgress = .completed
      publishLibraryChange()
      let applicationName: String = outcome.application.displayName
      launchStatusMessage = String(
        localized: "Moved managed storage for \(applicationName)."
      )
      return true
    } catch {
      return finishFailedStorageRelocation(
        preview, code: (error as? StorageRelocationError)?.code,
        operationMessage: error.localizedDescription,
        coordinator: coordinator, repository: repository
      )
    }
  }

  @discardableResult
  func finishFailedStorageRelocation(
    _ preview: StorageRelocationPreview,
    code: StorageRelocationError.Code?,
    operationMessage: String,
    coordinator: StorageRelocationCoordinator,
    repository: any LibraryRepositoryPersisting
  ) -> Bool {
    errorMessage = operationMessage
    storageRelocationProgress = nil
    // A plan/receipt belongs to one attempt. A retry must prepare a new one.
    storageRelocationPreview = nil
    let recovered: StorageRelocationRecoveryOutcome?
    do {
      let result = try repository.tryWithExclusiveAccess { access in
        let path = try coordinator.controlPlanPath(preview.requestID)
        guard try coordinator.control.itemState(at: path) != .missing else {
          return Optional<StorageRelocationRecoveryOutcome>.none
        }
        return try coordinator.recover(
          transactionID: preview.requestID, repository: repository, access: access
        )
      }
      switch result {
      case .busy:
        // Another live operation owns the journals. Do not recover its work.
        if case .loaded(let snapshot) = repository.load() {
          adoptStorageRelocationSnapshot(snapshot)
          if code == .rollbackRequired || code == .ambiguousLibraryState {
            loadState = .recoveryRequired(originalBytes: snapshot.originalBytes, message: operationMessage)
          }
        }
        return false
      case .acquired(let outcome): recovered = outcome
      }
    } catch is LibraryOperationInProgressError {
      if case .loaded(let snapshot) = repository.load() { adoptStorageRelocationSnapshot(snapshot) }
      loadState = .loaded
      isLibraryOperationInProgress = true
      libraryOperationStatusMessage = LibraryOperationInProgressError().localizedDescription
      scheduleLibraryReloadRetry()
      return false
    } catch {
      let recoveryError = error
      let originalBytes: Data?
      switch repository.load() {
      case .loaded(let snapshot):
        adoptStorageRelocationSnapshot(snapshot)
        originalBytes = snapshot.originalBytes
      case .recoveryRequired(let failure), .readOnly(let failure):
        originalBytes = failure.originalBytes
      case .migrationRequired(let snapshot):
        originalBytes = snapshot.originalBytes
      case .missing:
        originalBytes = nil
      }
      errorMessage = String(
        localized: "\(operationMessage) Recovery could not finish: \(recoveryError.localizedDescription)"
      )
      loadState = .recoveryRequired(
        originalBytes: originalBytes, message: errorMessage ?? recoveryError.localizedDescription
      )
      return false
    }

    switch repository.load() {
    case .loaded(let snapshot):
      adoptStorageRelocationSnapshot(snapshot)
      loadState = .loaded
      if case .committed(let outcome) = recovered {
        errorMessage = nil
        launchStatusMessage = storageRelocationCompletionMessage(outcome)
        return true
      } else if code == .cancelled {
        errorMessage = nil
        launchStatusMessage = String(
          localized: "Storage relocation was cancelled. Managed data remains at its original location."
        )
      }
    case .recoveryRequired(let failure), .readOnly(let failure):
      loadState = .recoveryRequired(originalBytes: failure.originalBytes, message: operationMessage)
    case .missing, .migrationRequired:
      loadState = .recoveryRequired(originalBytes: nil, message: operationMessage)
    }
    return false
  }

  func storageRelocationCompletionMessage(_ outcome: StorageRelocationOutcome) -> String {
    guard !outcome.leftoverSourcePaths.isEmpty else {
      return String(localized: "Recovered and completed the storage move.")
    }
    let paths: String = outcome.leftoverSourcePaths.joined(separator: "\n")
    visibleRelocationNoticeIDs = [outcome.transactionID]
    presentedRelocationNoticeIDs.insert(outcome.transactionID)
    let message = String(localized: "The storage move is committed. Original data was left in place or could not be checked at: \(paths)")
    relocationNoticeMessage = message
    return message
  }

  func preserveStorageRelocationSelection() {
    if !applications.contains(where: { $0.id == selectedApplicationID }) {
      selectedApplicationID = nil
    }
    if applications.first(where: { $0.id == selectedApplicationID })?
      .profiles.contains(where: { $0.id == selectedProfileID }) != true
    {
      selectedProfileID = nil
    }
  }

  func adoptStorageRelocationSnapshot(_ snapshot: LibraryRepositorySnapshot) {
    let changed = libraryVersionToken != snapshot.versionToken
    applications = snapshot.applications
    libraryVersionToken = snapshot.versionToken
    preserveStorageRelocationSelection()
    if changed { publishLibraryChange() }
  }
}
