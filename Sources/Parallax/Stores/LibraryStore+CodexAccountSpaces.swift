import Foundation

// MARK: - Tracked Codex account spaces

extension LibraryStore {
  /// Creates one Local Space per signed-in Codex account and managed Codex
  /// application. The account session home is the durable link, so repeated
  /// startup and refresh passes are idempotent without claiming ownership of
  /// the credentials directory. Persisted link receipts prevent automatic
  /// recreation after removal; `recreateRemovedSpaces` is for explicit requests.
  @discardableResult
  func synchronizeCodexAccountSpaces(
    accounts: [TrackedAIAccount],
    synchronizationDefaults: UserDefaults = .standard,
    recreateRemovedSpaces: Bool = false,
    codexHomeResolver: (UUID) throws -> URL = {
      try AIAccountConnectionService.codexHome(accountID: $0)
    }
  ) -> Int {
    let codexAccounts = accounts.filter { $0.provider == .codex }

    let receiptKey = "codex.account-spaces.v1"
    let previousReceipts = Set(synchronizationDefaults.stringArray(forKey: receiptKey) ?? [])
    let accountIDs = Set(codexAccounts.map { $0.id.uuidString })
    var receipts = previousReceipts.filter {
      $0.split(separator: ":").last.map { accountIDs.contains(String($0)) } == true
    }
    defer {
      if receipts != previousReceipts {
        synchronizationDefaults.set(receipts.sorted(), forKey: receiptKey)
      }
    }
    var createdReceipts: Set<String> = []
    var candidate = applications
    var createdCount = 0
    do {
      for applicationIndex in candidate.indices
      where Self.resolvedPreset(for: candidate[applicationIndex]) == .codex {
        for account in codexAccounts {
          let receipt = candidate[applicationIndex].storageID.uuidString
            + ":" + account.id.uuidString
          // A removed link does not need its provider directory resolved.
          guard !receipts.contains(receipt) || recreateRemovedSpaces else {
            continue
          }
          let accountHome = try codexHomeResolver(account.id)
            .standardizedFileURL
          if candidate[applicationIndex].profiles.contains(where: {
            Self.codexHomePath(in: $0) == accountHome.path
          }) {
            // Adopt links created by previous builds as well as this build.
            receipts.insert(receipt)
            continue
          }
          guard account.isSignedIn else { continue }
          guard settings.canProvideVerifiedSettings,
            !isProfileDataOperationRunning,
            case .loaded = loadState,
            migrationRequiredLibrary == nil
          else { continue }
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
          profile.environmentText = try Self.settingEnvironmentValue(
            "CODEX_HOME",
            to: accountHome.path,
            in: profile.environmentText
          )
          profile.isolationOwnership.codexHome = .explicit
          profile.accountLink = SpaceAccountLink(expectedEmail: account.email, trackingAccountID: account.id)
          candidate[applicationIndex].profiles.append(profile)
          createdCount += 1
          createdReceipts.insert(receipt)
        }
      }
    } catch {
      errorMessage = error.localizedDescription
      return 0
    }

    if createdCount > 0 {
      guard commit(
        candidate,
        selectedApplicationID: selectedApplicationID,
        selectedProfileID: selectedProfileID
      ) else { return 0 }
    }
    receipts.formUnion(createdReceipts)
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
