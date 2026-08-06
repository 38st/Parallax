import AppKit
import Foundation
import Observation

// MARK: - Application lifecycle

extension LibraryStore {
  func beginAddingApplication() {
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
          : String(
            localized:
              "The selected application conflicts with existing record(s): \(conflictNames). No application was changed."
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

    do {
      storageRelocationPreview = try storageRelocationCoordinator.prepare(
        application: application,
        destinationBaseRoot: destinationBaseRoot.path,
        expectedVersion: libraryVersionToken
      )
      storageRelocationProgress = nil
    } catch {
      storageRelocationPreview = nil
      storageRelocationProgress = nil
      errorMessage = error.localizedDescription
    }
  }

  func cancelStorageRelocation(_ preview: StorageRelocationPreview) {
    guard storageRelocationPreview?.requestID == preview.requestID else {
      return
    }
    if let storageRelocationCancellation {
      storageRelocationCancellation.cancel()
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

    let cancellation = StorageRelocationCancellation()
    storageRelocationCancellation = cancellation
    storageRelocationProgress = .preparing
    errorMessage = nil
    storageRelocationTask = Task { [weak self] in
      let result = await Task.detached(
        priority: .userInitiated
      ) {
        do {
          let outcome = try storageRelocationCoordinator.execute(
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

      guard let self else { return }
      self.storageRelocationTask = nil
      self.storageRelocationCancellation = nil
      switch result {
      case .succeeded(let outcome):
        self.applications = candidate
        self.applications[applicationIndex] = outcome.application
        self.libraryVersionToken = outcome.versionToken
        self.selectedApplicationID = outcome.application.id
        if !outcome.application.profiles.contains(where: {
          $0.id == self.selectedProfileID
        }) {
          self.selectedProfileID =
            outcome.application.profiles.first?.id
        }
        self.storageRelocationPreview = nil
        self.storageRelocationProgress = .completed
        self.publishLibraryChange()
        self.launchStatusMessage = String(
          localized: "Moved managed storage for \(outcome.application.displayName)."
        )
      case .failed(let code, let message):
        self.finishFailedStorageRelocation(
          preview,
          code: code,
          operationMessage: message,
          coordinator: storageRelocationCoordinator,
          repository: repository
        )
      }
    }
  }

  @discardableResult
  func confirmStorageRelocation(
    _ preview: StorageRelocationPreview
  ) -> Bool {
    guard canMutateLibrary() else { return false }
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

    var candidate = applications
    candidate[applicationIndex] = preview.relocatedApplication

    do {
      let prepared = try repository.prepare(
        candidate,
        expectedVersion: libraryVersionToken
      )
      let outcome = try storageRelocationCoordinator.execute(
        preview,
        preparedCommit: prepared,
        repository: repository
      ) { [weak self] progress in
        self?.storageRelocationProgress = progress
      }
      applications = candidate
      applications[applicationIndex] = outcome.application
      self.libraryVersionToken = outcome.versionToken
      selectedApplicationID = outcome.application.id
      if !outcome.application.profiles.contains(where: {
        $0.id == selectedProfileID
      }) {
        selectedProfileID = outcome.application.profiles.first?.id
      }
      storageRelocationPreview = nil
      storageRelocationProgress = .completed
      publishLibraryChange()
      launchStatusMessage = String(
        localized: "Moved managed storage for \(outcome.application.displayName)."
      )
      return true
    } catch {
      let operationError = error
      errorMessage = operationError.localizedDescription
      storageRelocationProgress = nil
      let recoveryOutcomes: [StorageRelocationRecoveryOutcome]
      do {
        recoveryOutcomes =
          try storageRelocationCoordinator.recoverAll(
            repository: repository
          )
        guard
          try storageRelocationCoordinator
            .pendingRelocations()
            .isEmpty
        else {
          throw StorageRelocationError(.rollbackRequired)
        }
      } catch {
        let recoveryError = error
        let originalBytes: Data? =
          switch repository.load() {
          case .loaded(let snapshot):
            snapshot.originalBytes
          case .recoveryRequired(let failure),
            .readOnly(let failure):
            failure.originalBytes
          case .migrationRequired(let snapshot):
            snapshot.originalBytes
          case .missing:
            nil
          }
        errorMessage = String(
          localized:
            "\(operationError.localizedDescription) Recovery could not finish: \(recoveryError.localizedDescription)"
        )
        loadState = .recoveryRequired(
          originalBytes: originalBytes,
          message: errorMessage
            ?? recoveryError.localizedDescription
        )
        return false
      }
      switch repository.load() {
      case .loaded(let snapshot):
        applications = snapshot.applications
        self.libraryVersionToken = snapshot.versionToken
        selectedApplicationID =
          applications.contains {
            $0.id == preview.applicationID
          } ? preview.applicationID : applications.first?.id
        selectedProfileID =
          applications.first(where: {
            $0.id == selectedApplicationID
          })?.profiles.first?.id
        loadState = .loaded
        if recoveryOutcomes.contains(where: {
          if case .committed(let outcome) = $0 {
            outcome.transactionID == preview.requestID
          } else {
            false
          }
        }) {
          storageRelocationPreview = nil
          publishLibraryChange()
          launchStatusMessage = String(
            localized: "Recovered and completed the storage move."
          )
          return true
        }
      case .recoveryRequired(let failure),
        .readOnly(let failure):
        loadState = .recoveryRequired(
          originalBytes: failure.originalBytes,
          message: operationError.localizedDescription
        )
      case .missing, .migrationRequired:
        loadState = .recoveryRequired(
          originalBytes: nil,
          message: operationError.localizedDescription
        )
      }
      return false
    }
  }

  func finishFailedStorageRelocation(
    _ preview: StorageRelocationPreview,
    code: StorageRelocationError.Code?,
    operationMessage: String,
    coordinator: StorageRelocationCoordinator,
    repository: any LibraryRepositoryPersisting
  ) {
    errorMessage = operationMessage
    storageRelocationProgress = nil
    let recoveryOutcomes: [StorageRelocationRecoveryOutcome]
    do {
      recoveryOutcomes = try coordinator.recoverAll(
        repository: repository
      )
      guard try coordinator.pendingRelocations().isEmpty else {
        throw StorageRelocationError(.rollbackRequired)
      }
    } catch {
      let recoveryError = error
      let originalBytes: Data? =
        switch repository.load() {
        case .loaded(let snapshot):
          snapshot.originalBytes
        case .recoveryRequired(let failure),
          .readOnly(let failure):
          failure.originalBytes
        case .migrationRequired(let snapshot):
          snapshot.originalBytes
        case .missing:
          nil
        }
      errorMessage = String(
        localized:
          "\(operationMessage) Recovery could not finish: \(recoveryError.localizedDescription)"
      )
      loadState = .recoveryRequired(
        originalBytes: originalBytes,
        message: errorMessage ?? recoveryError.localizedDescription
      )
      return
    }

    switch repository.load() {
    case .loaded(let snapshot):
      applications = snapshot.applications
      libraryVersionToken = snapshot.versionToken
      selectedApplicationID =
        applications.contains {
          $0.id == preview.applicationID
        } ? preview.applicationID : applications.first?.id
      selectedProfileID =
        applications.first(where: {
          $0.id == selectedApplicationID
        })?.profiles.first?.id
      loadState = .loaded
      if recoveryOutcomes.contains(where: {
        if case .committed(let outcome) = $0 {
          outcome.transactionID == preview.requestID
        } else {
          false
        }
      }) {
        storageRelocationPreview = nil
        errorMessage = nil
        publishLibraryChange()
        launchStatusMessage = String(
          localized: "Recovered and completed the storage move."
        )
      } else if code == .cancelled {
        errorMessage = nil
        launchStatusMessage = String(
          localized:
            "Storage relocation was cancelled. Managed data remains at its original location."
        )
      }
    case .recoveryRequired(let failure),
      .readOnly(let failure):
      loadState = .recoveryRequired(
        originalBytes: failure.originalBytes,
        message: operationMessage
      )
    case .missing, .migrationRequired:
      loadState = .recoveryRequired(
        originalBytes: nil,
        message: operationMessage
      )
    }
  }

}
