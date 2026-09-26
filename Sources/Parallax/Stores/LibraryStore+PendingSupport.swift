import AppKit
import Foundation
import Observation

// MARK: - Pending launch support

extension LibraryStore {
  static let launchTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.timeStyle = .short
    return formatter
  }()

  struct PendingImportedLaunch {
    let applicationID: UUID
    let profileID: UUID
    let review: ImportedLaunchReview
  }

  struct PendingLaunchDiagnosticRequest {
    let source: LaunchConfigurationSource
    let profileName: String
    let fingerprint: LaunchConfigurationFingerprint
    let diagnostics: [LaunchCompilerDiagnostic]
  }

  struct PendingConcurrentLaunchRequest {
    let source: LaunchConfigurationSource
    let profileName: String
    let fingerprint: LaunchConfigurationFingerprint
  }

}

// MARK: - Recovery under an existing library lock

// These entry points reuse startup's capability. The legacy recovery bodies are
// currently unlocked; when adding exclusion to their standalone entry points,
// keep the recovery implementation on this capability-taking path.
extension StorageRelocationCoordinator {
  func recoverAll(
    repository: any LibraryRepositoryPersisting,
    access: LibraryExclusiveAccess
  ) throws -> [StorageRelocationRecoveryOutcome] {
    try access.validate(for: repository)
    return try recoverAll(repository: repository)
  }

  func recover(
    transactionID: UUID,
    repository: any LibraryRepositoryPersisting,
    access: LibraryExclusiveAccess
  ) throws -> StorageRelocationRecoveryOutcome {
    try access.validate(for: repository)
    return try recover(transactionID: transactionID, repository: repository)
  }
}

extension ProfileDataTransactionCoordinator {
  func recover(
    transactionID: UUID,
    repository: any LibraryRepositoryPersisting,
    access: LibraryExclusiveAccess
  ) throws -> ProfileDataTransactionOutcome {
    try access.validate(for: repository)
    return try recover(transactionID: transactionID, repository: repository)
  }
}

extension ApplicationRemovalTransactionCoordinator {
  func recover(
    transactionID: UUID,
    repository: any LibraryRepositoryPersisting,
    access: LibraryExclusiveAccess
  ) throws -> ApplicationRemovalTransactionOutcome {
    try access.validate(for: repository)
    return try recover(transactionID: transactionID, repository: repository)
  }
}
