import Darwin
import Foundation

extension ProfileDataTransactionCoordinator {
  func classifyPrimary(
    _ outcome: LibraryRepositoryLoadOutcome,
    prior: LibraryVersionToken,
    target: LibraryVersionToken
  ) -> LibraryCommitPrimaryState {
    let actual: LibraryVersionToken?
    switch outcome {
    case .missing:
      actual = .missing
    case .loaded(let snapshot):
      actual = snapshot.versionToken
    case .migrationRequired, .recoveryRequired, .readOnly:
      actual = nil
    }
    if actual == prior { return .prior }
    if actual == target { return .target }
    return .neither
  }

  func committedMutation(for plan: Plan) -> ProfileDataMutation {
    guard plan.sourceSnapshot != nil else { return .noManagedData }
    switch plan.operation {
    case .archive, .clear:
      return .archivedManagedData
    case .delete:
      return .deletedManagedData
    case .duplicate:
      return .copiedManagedData
    case .relocate:
      return .relocatedManagedData
    }
  }

  func metadataBackupReason(
    for operation: ProfileDataTransactionOperation
  ) -> LibraryBackupReason? {
    switch operation {
    case .archive, .delete, .relocate:
      return .destructiveRewrite
    case .clear, .duplicate:
      return nil
    }
  }

  func outcome(
    from receipt: Receipt,
    plan: Plan
  ) -> ProfileDataTransactionOutcome {
    let archiveURL: URL?
    if receipt.completion == .committed,
      receipt.dataMutation == .archivedManagedData,
      let archive = plan.archivePath?.value
    {
      archiveURL = absoluteURL(archive, root: plan.sourceRoot)
    } else {
      archiveURL = nil
    }
    return ProfileDataTransactionOutcome(
      transactionID: plan.transactionID,
      operation: receipt.operation,
      dataMutation: receipt.dataMutation,
      externalDataHandling: receipt.externalDataHandling,
      didArchiveData: receipt.completion == .committed
        && receipt.dataMutation == .archivedManagedData,
      archiveURL: archiveURL,
      receiptURL: nil
    )
  }

  func preparedCommitIdentifier(
    request: ProfileDataTransactionRequest,
    preparedCommit: PreparedLibraryCommit
  ) -> String {
    let fields = [
      request.transactionID.uuidString.lowercased(),
      request.identity.applicationID.uuidString.lowercased(),
      request.identity.applicationStorageID.uuidString.lowercased(),
      request.identity.sourceProfileID.uuidString.lowercased(),
      request.identity.sourceProfileStorageID.uuidString.lowercased(),
      request.identity.destinationProfileID?.uuidString.lowercased() ?? "",
      request.identity.destinationProfileStorageID?.uuidString.lowercased()
        ?? "",
      request.operation.rawValue,
      String(preparedCommit.priorVersion.revision.rawValue),
      preparedCommit.priorVersion.primarySHA256 ?? "",
      String(preparedCommit.targetVersion.revision.rawValue),
      preparedCommit.targetVersion.primarySHA256 ?? "",
      LibraryPersistence.sha256(preparedCommit.targetBytes),
    ]
    return LibraryPersistence.sha256(Data(fields.joined(separator: "\n").utf8))
  }

  func validatePreparedCommit(
    _ prepared: PreparedLibraryCommit
  ) throws {
    guard
      prepared.targetVersion.primarySHA256
        == LibraryPersistence.sha256(prepared.targetBytes),
      prepared.targetVersion.revision.rawValue
        == prepared.priorVersion.revision.rawValue + 1
    else {
      throw ProfileDataTransactionError(.preparedCommitMismatch)
    }
  }

  func validateMetadataTransition(
    plan: Plan,
    priorApplications: [ManagedApplication],
    targetApplications: [ManagedApplication]
  ) throws {
    guard
      let priorApplication = priorApplications.first(where: {
        $0.id == plan.identity.applicationID
      }),
      let targetApplication = targetApplications.first(where: {
        $0.id == plan.identity.applicationID
      }),
      priorApplications.filter({
        $0.id == plan.identity.applicationID
      }).count == 1,
      targetApplications.filter({
        $0.id == plan.identity.applicationID
      }).count == 1,
      priorApplication.storageID
        == plan.identity.applicationStorageID,
      targetApplication.storageID
        == plan.identity.applicationStorageID,
      let priorSource = priorApplication.profiles.first(where: {
        $0.id == plan.identity.sourceProfileID
      }),
      priorSource.storageID
        == plan.identity.sourceProfileStorageID
    else {
      throw ProfileDataTransactionError(
        .preparedCommitMismatch,
        operation: plan.operation
      )
    }

    let targetSource = targetApplication.profiles.first {
      $0.id == plan.identity.sourceProfileID
    }
    let targetHasSource =
      targetSource?.storageID
      == plan.identity.sourceProfileStorageID
    switch plan.operation {
    case .archive, .delete:
      guard !targetHasSource else {
        throw ProfileDataTransactionError(
          .preparedCommitMismatch,
          operation: plan.operation
        )
      }
    case .clear:
      guard targetHasSource else {
        throw ProfileDataTransactionError(
          .preparedCommitMismatch,
          operation: plan.operation
        )
      }
    case .duplicate:
      guard
        targetHasSource,
        let destinationID = plan.identity.destinationProfileID,
        destinationID != plan.identity.sourceProfileID,
        !priorApplication.profiles.contains(where: {
          $0.id == destinationID
        }),
        let targetDestination = targetApplication.profiles.first(where: {
          $0.id == destinationID
        }),
        targetDestination.storageID
          == plan.identity.destinationProfileStorageID
      else {
        throw ProfileDataTransactionError(
          .preparedCommitMismatch,
          operation: plan.operation
        )
      }
    case .relocate:
      guard targetHasSource else {
        throw ProfileDataTransactionError(
          .preparedCommitMismatch,
          operation: plan.operation
        )
      }
    }
  }

}
