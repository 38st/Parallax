import Foundation

// MARK: - Tracked Codex account spaces

extension LibraryStore {
  /// Creates one Local Space per signed-in Codex account and managed Codex
  /// application. The account session home is the durable link, so repeated
  /// startup and refresh passes are idempotent without claiming ownership of
  /// the credentials directory.
  @discardableResult
  func synchronizeCodexAccountSpaces(
    accounts: [TrackedAIAccount],
    codexHomeResolver: (UUID) throws -> URL = {
      try AIAccountConnectionService.codexHome(accountID: $0)
    }
  ) -> Int {
    guard canMutateLibrary() else { return 0 }
    let signedInAccounts = accounts.filter {
      $0.provider == .codex && $0.isSignedIn
    }
    guard !signedInAccounts.isEmpty else { return 0 }

    var candidate = applications
    var createdCount = 0
    do {
      for applicationIndex in candidate.indices
      where Self.resolvedPreset(for: candidate[applicationIndex]) == .codex {
        for account in signedInAccounts {
          let accountHome = try codexHomeResolver(account.id)
            .standardizedFileURL
          guard !candidate[applicationIndex].profiles.contains(where: {
            Self.codexHomePath(in: $0) == accountHome.path
          }) else {
            continue
          }
          let baseName = Self.codexAccountSpaceName(for: account)
          guard let profileName = Self.uniqueProfileName(
            basedOn: baseName,
            existingProfiles: candidate[applicationIndex].profiles
          ) else {
            throw CodexAccountSpaceSynchronizationError
              .uniqueNameUnavailable
          }
          var profile = try self.profile(
            named: profileName,
            template: nil,
            for: candidate[applicationIndex]
          )
          profile.environmentText = Self.settingEnvironmentValue(
            "CODEX_HOME",
            to: accountHome.path,
            in: profile.environmentText
          )
          profile.isolationOwnership.codexHome = .explicit
          candidate[applicationIndex].profiles.append(profile)
          createdCount += 1
        }
      }
    } catch {
      errorMessage = error.localizedDescription
      return 0
    }

    guard createdCount > 0 else { return 0 }
    guard commit(
      candidate,
      selectedApplicationID: selectedApplicationID,
      selectedProfileID: selectedProfileID
    ) else {
      return 0
    }
    return createdCount
  }

  private static func codexHomePath(in profile: LaunchProfile) -> String? {
    guard let path = environmentValue("CODEX_HOME", in: profile) else {
      return nil
    }
    return URL(fileURLWithPath: path).standardizedFileURL.path
  }

  private static func codexAccountSpaceName(
    for account: TrackedAIAccount
  ) -> String {
    let email = account.email.trimmingCharacters(
      in: .whitespacesAndNewlines
    )
    let localPart = email.split(
      separator: "@",
      maxSplits: 1,
      omittingEmptySubsequences: true
    ).first.map(String.init)
    for candidate in [localPart, account.label, email].compactMap({ $0 }) {
      if let normalized = DisplayNameValidator.normalized(candidate) {
        return normalized
      }
    }
    return String(localized: "Codex Account")
  }
}

private enum CodexAccountSpaceSynchronizationError: LocalizedError {
  case uniqueNameUnavailable

  var errorDescription: String? {
    String(
      localized:
        "Parallax could not create a unique valid space name for a signed-in Codex account."
    )
  }
}
