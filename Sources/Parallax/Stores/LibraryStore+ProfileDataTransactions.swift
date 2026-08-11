import AppKit
import Foundation
import Observation

// MARK: - Profile data transactions

extension LibraryStore {
  func executeProfileDataTransaction(
    operation: ProfileDataTransactionOperation,
    application: ManagedApplication,
    sourceProfile: LaunchProfile,
    destinationProfile: LaunchProfile?,
    candidate: [ManagedApplication],
    selectedProfileID candidateProfileID: LaunchProfile.ID?,
    externalDataHandling: ProfileExternalDataHandling
  ) -> ProfileDataTransactionOutcome? {
    guard
      let profileDataTransactions,
      let repository,
      let libraryVersionToken
    else {
      return nil
    }
    let priorVersionToken = libraryVersionToken

    do {
      let prepared = try prepareProfileDataTransaction(
        operation: operation,
        application: application,
        sourceProfile: sourceProfile,
        destinationProfile: destinationProfile,
        candidate: candidate,
        externalDataHandling: externalDataHandling,
        expectedVersion: libraryVersionToken,
        repository: repository
      )
      let outcome = try profileDataTransactions.execute(
        prepared.request,
        preparedCommit: prepared.commit,
        repository: repository
      )
      applyProfileDataTransactionSuccess(
        candidate: candidate,
        applicationID: application.id,
        selectedProfileID: candidateProfileID,
        targetVersion: prepared.commit.targetVersion
      )
      return outcome
    } catch {
      reconcileAfterProfileDataTransactionFailure(
        error,
        repository: repository,
        priorVersionToken: priorVersionToken,
        profileDataTransactions: profileDataTransactions
      )
      return nil
    }
  }

  func executeProfileDataTransactionAsync(
    operation: ProfileDataTransactionOperation,
    application: ManagedApplication,
    sourceProfile: LaunchProfile,
    destinationProfile: LaunchProfile?,
    candidate: [ManagedApplication],
    selectedProfileID candidateProfileID: LaunchProfile.ID?,
    externalDataHandling: ProfileExternalDataHandling
  ) async -> ProfileDataTransactionOutcome? {
    guard
      let profileDataTransactions,
      let repository,
      let libraryVersionToken
    else {
      return nil
    }
    let priorVersionToken = libraryVersionToken

    do {
      let prepared = try prepareProfileDataTransaction(
        operation: operation,
        application: application,
        sourceProfile: sourceProfile,
        destinationProfile: destinationProfile,
        candidate: candidate,
        externalDataHandling: externalDataHandling,
        expectedVersion: libraryVersionToken,
        repository: repository
      )
      let outcome = try await Task.detached(
        priority: .userInitiated
      ) {
        try profileDataTransactions.execute(
          prepared.request,
          preparedCommit: prepared.commit,
          repository: repository
        )
      }.value
      applyProfileDataTransactionSuccess(
        candidate: candidate,
        applicationID: application.id,
        selectedProfileID: candidateProfileID,
        targetVersion: prepared.commit.targetVersion
      )
      return outcome
    } catch {
      reconcileAfterProfileDataTransactionFailure(
        error,
        repository: repository,
        priorVersionToken: priorVersionToken,
        profileDataTransactions: profileDataTransactions
      )
      return nil
    }
  }

  private struct PreparedProfileDataTransactionExecution: Sendable {
    let request: ProfileDataTransactionRequest
    let commit: PreparedLibraryCommit
  }

  private func prepareProfileDataTransaction(
    operation: ProfileDataTransactionOperation,
    application: ManagedApplication,
    sourceProfile: LaunchProfile,
    destinationProfile: LaunchProfile?,
    candidate: [ManagedApplication],
    externalDataHandling: ProfileExternalDataHandling,
    expectedVersion: LibraryVersionToken,
    repository: any LibraryRepositoryPersisting
  ) throws -> PreparedProfileDataTransactionExecution {
    let source = try managedPaths(
      for: application,
      profile: sourceProfile
    )
    let destination = try destinationProfile.map {
      try managedPaths(for: application, profile: $0)
    }
    let commit = try repository.prepare(
      candidate,
      expectedVersion: expectedVersion
    )
    let request = ProfileDataTransactionRequest(
      transactionID: UUID(),
      identity: ProfileDataTransactionIdentity(
        applicationID: application.id,
        applicationStorageID: application.storageID,
        sourceProfileID: sourceProfile.id,
        sourceProfileStorageID: sourceProfile.storageID,
        destinationProfileID: destinationProfile?.id,
        destinationProfileStorageID: destinationProfile?.storageID
      ),
      operation: operation,
      source: source,
      destination: destination,
      externalDataHandling: externalDataHandling
    )
    return PreparedProfileDataTransactionExecution(
      request: request,
      commit: commit
    )
  }

  private func applyProfileDataTransactionSuccess(
    candidate: [ManagedApplication],
    applicationID: ManagedApplication.ID,
    selectedProfileID candidateProfileID: LaunchProfile.ID?,
    targetVersion: LibraryVersionToken
  ) {
    applications = candidate
    selectedApplicationID = applicationID
    selectedProfileID = candidateProfileID
    libraryVersionToken = targetVersion
    loadState = .loaded
    publishLibraryChange()
  }

  private func reconcileAfterProfileDataTransactionFailure(
    _ error: Error,
    repository: any LibraryRepositoryPersisting,
    priorVersionToken: LibraryVersionToken,
    profileDataTransactions: ProfileDataTransactionCoordinator
  ) {
    AppLog.profiles.error(
      "Profile data transaction failed: \(error.localizedDescription)"
    )
    errorMessage = error.localizedDescription
    switch repository.load() {
    case .loaded(let snapshot):
      let previousApplicationID = selectedApplicationID
      let previousProfileID = selectedProfileID
      applications = snapshot.applications
      libraryVersionToken = snapshot.versionToken
      selectedApplicationID =
        applications.contains {
          $0.id == previousApplicationID
        } ? previousApplicationID : applications.first?.id
      if let selectedApplication = applications.first(where: {
        $0.id == selectedApplicationID
      }) {
        selectedProfileID =
          selectedApplication.profiles.contains {
            $0.id == previousProfileID
          } ? previousProfileID : selectedApplication.profiles.first?.id
      } else {
        selectedProfileID = nil
      }
      if snapshot.versionToken == priorVersionToken {
        loadState = .loaded
      } else {
        loadState = .recoveryRequired(
          originalBytes: nil,
          message: error.localizedDescription
        )
      }
    case .recoveryRequired(let failure),
      .readOnly(let failure):
      loadState = .recoveryRequired(
        originalBytes: failure.originalBytes,
        message: error.localizedDescription
      )
    case .missing, .migrationRequired:
      loadState = .recoveryRequired(
        originalBytes: nil,
        message: error.localizedDescription
      )
    }
    if (try? profileDataTransactions.pendingTransactions().isEmpty) == false {
      loadState = .recoveryRequired(
        originalBytes: failedPrimaryBytes,
        message: error.localizedDescription
      )
    }
  }
}
