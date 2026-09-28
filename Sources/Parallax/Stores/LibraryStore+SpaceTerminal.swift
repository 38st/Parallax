import AppKit
import Foundation

extension LibraryStore {
  func canOpenTerminalInSpace(for application: ManagedApplication) -> Bool {
    SpaceTerminalService.supports(Self.resolvedPreset(for: application))
  }

  func openTerminalInSpace(
    for application: ManagedApplication,
    profile: LaunchProfile,
    reviewImportedConfiguration: @MainActor (ImportedLaunchReview) async -> Bool = { _ in false },
    prepareCommand: (@MainActor (LaunchConfigurationSource, AppPreset, String) async throws -> SpaceTerminalCommand)? = nil,
    openCommand: @MainActor (URL) async throws -> Void = SpaceTerminalOpener.open
  ) async {
    guard canMutateLibrary() else { return }
    guard applications.contains(where: { $0 == application && $0.profiles.contains(profile) }) else {
      errorMessage = SpaceTerminalError.changed.localizedDescription
      return
    }
    let fingerprint = recoveryFingerprint(application: application, profile: profile)
    let source = launchConfigurationSource(application: application, profile: profile, requestID: UUID())
    do {
      try validateTerminalTarget(application: application, profile: profile, fingerprint: fingerprint)
      if profile.launchConfigurationTrust.isImported {
        let analysis = await launchConfigurationCompiler.analyze(source)
        let trustSource = importedLaunchTrustSource(application: application, profile: profile,
          analysis: analysis, source: source)
        if case .reviewRequired(let review) = importedLaunchTrust.assessment(for: profile, source: trustSource) {
          guard await reviewImportedConfiguration(review) else { return }
          try Task.checkCancellation()
          try validateTerminalTarget(application: application, profile: profile, fingerprint: fingerprint)
          let currentAnalysis = await launchConfigurationCompiler.analyze(source)
          try validateTerminalTarget(application: application, profile: profile, fingerprint: fingerprint)
          try Task.checkCancellation()
          let approval = try importedLaunchTrust.approval(for: review,
            currentSource: importedLaunchTrustSource(application: application, profile: profile,
              analysis: currentAnalysis, source: source))
          guard canMutateLibrary(),
            let appIndex = applications.firstIndex(where: { $0.id == application.id }),
            let profileIndex = applications[appIndex].profiles.firstIndex(where: { $0.id == profile.id })
          else { return }
          var candidate = applications
          candidate[appIndex].profiles[profileIndex].approveImportedLaunch(using: approval)
          guard commit(candidate, selectedApplicationID: selectedApplicationID, selectedProfileID: selectedProfileID) else { return }
        }
      }
      guard canMutateLibrary() else { return }
      let command: SpaceTerminalCommand
      let preset = Self.resolvedPreset(for: application)
      if let prepareCommand {
        command = try await prepareCommand(source, preset, profile.name)
      } else {
        let service = SpaceTerminalService(activityRegistry: profileActivityRegistry)
        command = try await Task.detached {
          try service.prepare(source, preset: preset, profileName: profile.name)
        }.value
      }
      do {
        try Task.checkCancellation()
        guard canMutateLibrary() else {
          command.cleanup()
          return
        }
        try validateTerminalTarget(application: application, profile: profile, fingerprint: fingerprint)
        try await openCommand(command.url)
        command.finishHandoff()
      } catch {
        command.cleanup()
        throw error
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func validateTerminalTarget(
    application: ManagedApplication, profile: LaunchProfile, fingerprint: LaunchConfigurationFingerprint
  ) throws {
    guard let currentApplication = applications.first(where: { $0.id == application.id }),
      let currentProfile = currentApplication.profiles.first(where: { $0.id == profile.id }),
      currentApplication.displayName == application.displayName,
      Self.resolvedPreset(for: currentApplication) == Self.resolvedPreset(for: application),
      currentProfile.name == profile.name,
      recoveryFingerprint(application: currentApplication, profile: currentProfile) == fingerprint
    else { throw SpaceTerminalError.changed }
    if let pending = pendingProfileEditingDraft(applicationID: application.id, profileID: profile.id),
      pending.draft != pending.baseline {
      selectedApplicationID = application.id
      selectedProfileID = profile.id
      throw SpaceTerminalReviewError.unsavedChanges
    }
  }
}

private enum SpaceTerminalReviewError: LocalizedError {
  case unsavedChanges

  var errorDescription: String? {
    String(localized: "This space has unsaved changes. Save or discard them before opening Terminal.")
  }
}

enum SpaceTerminalOpener {
  static let systemTerminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app", isDirectory: true)

  static func validatedSystemTerminalURL(
    bundleIdentifier: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }
  ) throws -> URL {
    guard bundleIdentifier(systemTerminalURL) == "com.apple.Terminal" else {
      throw SpaceTerminalError.terminalUnavailable
    }
    return systemTerminalURL
  }

  @MainActor
  static func open(_ url: URL) async throws {
    let terminal = try validatedSystemTerminalURL()
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: configuration) { application, error in
        if let error {
          continuation.resume(throwing: error)
        } else if application != nil {
          continuation.resume()
        } else {
          continuation.resume(throwing: SpaceTerminalError.terminalUnavailable)
        }
      }
    }
  }
}
