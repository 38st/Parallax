import AppKit
import Foundation
import Observation

extension LibraryStore {
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
