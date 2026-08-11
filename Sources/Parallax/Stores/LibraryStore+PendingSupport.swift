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
