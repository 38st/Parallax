import Darwin
import Foundation

// MARK: - Receipt recovery

extension StorageRelocationCoordinator {
  func recover(
    _ preview: StorageRelocationPreview,
    receiptURL: URL,
    repository: any LibraryRepositoryPersisting
  ) throws -> StorageRelocationRecoveryOutcome {
    let receipt = try loadReceipt(at: receiptURL)
    guard
      receipt.transactionID == preview.requestID,
      receipt.applicationID == preview.applicationID,
      receipt.applicationStorageID == preview.applicationStorageID,
      receipt.priorVersion.libraryToken == preview.expectedVersion,
      receipt.priorVersion.revision.rawValue < UInt64.max,
      receipt.targetVersion.revision.rawValue
        == receipt.priorVersion.revision.rawValue + 1,
      receipt.targetVersion.primarySHA256 != nil,
      receipt.sourceBasePath
        == preview.source.canonicalBaseRootURL.path,
      receipt.destinationBasePath
        == preview.destination.canonicalBaseRootURL.path
    else {
      throw StorageRelocationError(
        .invalidReceipt,
        path: receiptURL.path
      )
    }

    let source = preview.source
    let destination = preview.destination
    let destinationStaging = destination.stagingRoot(
      transactionID: receipt.transactionID
    )
    let libraryOutcome = repository.load()
    let primary = classifyLibrary(
      libraryOutcome,
      prior: receipt.priorVersion.libraryToken,
      target: receipt.targetVersion.libraryToken
    )
    guard
      recoveryApplicationMatches(
        libraryOutcome,
        primary: primary,
        preview: preview
      )
    else {
      throw StorageRelocationError(
        .ambiguousLibraryState,
        path: receiptURL.path
      )
    }
    switch primary {
    case .target:
      try requireRecoveryDestination(
        destination.applicationRoot,
        expected: preview.sourceApplicationFingerprint
      )
      try requireRecoveryDestination(
        destination.applicationArchiveRoot,
        expected: preview.sourceArchiveFingerprint
      )
      try removeOriginalOwned(
        source.applicationRoot,
        snapshot: preview.sourceApplicationSnapshot,
        allowMissing: true
      )
      try removeOriginalOwned(
        source.applicationArchiveRoot,
        snapshot: preview.sourceArchiveSnapshot,
        allowMissing: true
      )
      try removeIfPresent(destinationStaging)
      return .committed(
        StorageRelocationOutcome(
          transactionID: receipt.transactionID,
          application: preview.relocatedApplication,
          versionToken: receipt.targetVersion.libraryToken,
          receiptURL: nil
        )
      )
    case .prior:
      try requireRecoverySource(
        source.applicationRoot,
        expected: preview.sourceApplicationFingerprint
      )
      try requireRecoverySource(
        source.applicationArchiveRoot,
        expected: preview.sourceArchiveFingerprint
      )
      try removeRecoveryCopyIfPresent(
        destination.applicationRoot,
        snapshot: preview.sourceApplicationSnapshot
      )
      try removeRecoveryCopyIfPresent(
        destination.applicationArchiveRoot,
        snapshot: preview.sourceArchiveSnapshot
      )
      try removeIfPresent(destinationStaging)
      return .rolledBack
    case .neither:
      throw StorageRelocationError(
        .ambiguousLibraryState,
        path: receiptURL.path
      )
    }
  }

  func recoveryApplicationMatches(
    _ outcome: LibraryRepositoryLoadOutcome,
    primary: LibraryCommitPrimaryState,
    preview: StorageRelocationPreview
  ) -> Bool {
    guard case .loaded(let snapshot) = outcome else {
      return false
    }
    let matches = snapshot.applications.filter {
      $0.id == preview.applicationID
    }
    guard matches.count == 1 else { return false }
    switch primary {
    case .prior:
      return matches[0] == preview.originalApplication
    case .target:
      return matches[0] == preview.relocatedApplication
    case .neither:
      return true
    }
  }

  func requireRecoveryDestination(
    _ path: any ManagedMutationPath,
    expected: String?
  ) throws {
    if expected == nil {
      guard !exists(path) else {
        throw StorageRelocationError(
          .rollbackRequired,
          path: path.url.path
        )
      }
      return
    }
    do {
      try requireFingerprint(path, expected: expected)
    } catch {
      throw StorageRelocationError(
        .rollbackRequired,
        path: path.url.path,
        detail: error.localizedDescription
      )
    }
  }

  func requireRecoverySource(
    _ path: any ManagedMutationPath,
    expected: String?
  ) throws {
    if expected == nil {
      guard !exists(path) else {
        throw StorageRelocationError(
          .rollbackRequired,
          path: path.url.path
        )
      }
      return
    }
    do {
      try requireFingerprint(path, expected: expected)
    } catch {
      throw StorageRelocationError(
        .rollbackRequired,
        path: path.url.path,
        detail: error.localizedDescription
      )
    }
  }

  func relocatedApplication(
    _ application: ManagedApplication,
    sourceBaseRoot: String,
    destinationBaseRoot: String
  ) throws -> (
    application: ManagedApplication,
    generated: [StorageRelocationGeneratedRewrite],
    external: [StorageRelocationExternalPath],
    blockers: [StorageRelocationBlocker]
  ) {
    var relocated = application
    relocated.baseStoragePath = destinationBaseRoot
    var generated: [StorageRelocationGeneratedRewrite] = []
    var external: [StorageRelocationExternalPath] = []
    var blockers: [StorageRelocationBlocker] = []
    let source = try pathResolver.resolveApplication(
      configuredBaseRoot: sourceBaseRoot, applicationStorageID: application.storageID)
    let sourceApplicationRoot = try pathResolver.resolveExternalPath(source.applicationRoot.url.path).canonicalURL
    let sourceArchiveRoot = try pathResolver.resolveExternalPath(source.applicationArchiveRoot.url.path).canonicalURL
    func recordConfiguredPath(_ value: String, field: StorageRelocationIsolationField, profileID: UUID) throws {
      let expanded = field.expanded(value, homeDirectory: homeDirectory.path)
      let path: URL
      do { path = try pathResolver.resolveExternalPath(expanded).canonicalURL }
      catch {
        let profileName = application.profiles.first(where: { $0.id == profileID })?.name ?? ""
        blockers.append(.profileConfiguration(applicationName: application.displayName,
          profileName: profileName, problem: error.localizedDescription))
        return
      }
      if isPrefix(sourceApplicationRoot.pathComponents, of: path.pathComponents)
        || isPrefix(sourceArchiveRoot.pathComponents, of: path.pathComponents)
      {
        if !blockers.contains(.configuredPathInsideManagedStorage) {
          blockers.append(.configuredPathInsideManagedStorage)
        }
      } else {
        external.append(StorageRelocationExternalPath(profileID: profileID, field: field, value: value))
      }
    }

    for index in relocated.profiles.indices {
      var profile = relocated.profiles[index]
      let sourcePaths = try pathResolver.resolve(
        configuredBaseRoot: sourceBaseRoot,
        applicationStorageID: application.storageID,
        profileStorageID: profile.storageID
      )
      let destinationPaths = try pathResolver.resolve(
        configuredBaseRoot: destinationBaseRoot,
        applicationStorageID: application.storageID,
        profileStorageID: profile.storageID
      )

      let parsedArguments = LaunchArgumentParser.parse(profile.argumentsText)
      let resolution = UserDataDirectoryOptionResolver.resolve(in: parsedArguments.tokens)
      let diagnostics = parsedArguments.diagnostics + resolution.diagnostics
        + LaunchEnvironmentParser.parse(profile.environmentText).diagnostics
      let errors = diagnostics.filter { $0.severity == .error }
      if !errors.isEmpty {
        blockers += errors.map { .profileConfiguration(applicationName: application.displayName,
          profileName: profile.name, problem: $0.message) }
        continue
      }
      let userDataValue = userDataValue(in: profile)
      let userDataOwnership = resolvedOwnership(
        profile.isolationOwnership.userData,
        configuredValue: userDataValue,
        generatedURL: sourcePaths.userData.url
      )
      profile.isolationOwnership.userData = userDataOwnership
      if userDataOwnership == .generated {
        profile.argumentsText = settingUserDataValue(
          destinationPaths.userData.url.path,
          in: profile.argumentsText
        )
        generated.append(
          StorageRelocationGeneratedRewrite(
            profileID: profile.id,
            field: .userData,
            oldURL: sourcePaths.userData.url,
            newURL: destinationPaths.userData.url
          )
        )
      } else if let userDataValue {
        try recordConfiguredPath(userDataValue, field: .userData, profileID: profile.id)
      }

      let codexHomeValue = environmentValue(
        "CODEX_HOME",
        in: profile.environmentText
      )
      let codexOwnership = resolvedOwnership(
        profile.isolationOwnership.codexHome,
        configuredValue: codexHomeValue,
        generatedURL: sourcePaths.codexHome.url
      )
      profile.isolationOwnership.codexHome = codexOwnership
      if codexOwnership == .generated {
        profile.environmentText = try settingEnvironmentValue(
          "CODEX_HOME",
          to: destinationPaths.codexHome.url.path,
          in: profile.environmentText
        )
        generated.append(
          StorageRelocationGeneratedRewrite(
            profileID: profile.id,
            field: .codexHome,
            oldURL: sourcePaths.codexHome.url,
            newURL: destinationPaths.codexHome.url
          )
        )
      } else if let codexHomeValue {
        try recordConfiguredPath(codexHomeValue, field: .codexHome, profileID: profile.id)
      }
      if let claudeConfig = environmentValue("CLAUDE_CONFIG_DIR", in: profile.environmentText) {
        try recordConfiguredPath(claudeConfig, field: .claudeConfig, profileID: profile.id)
      }
      if let firefoxProfile = environmentValue("XRE_PROFILE_PATH", in: profile.environmentText) {
        try recordConfiguredPath(firefoxProfile, field: .firefoxProfile, profileID: profile.id)
      }
      for folder in PresetIsolationFolder.allCases {
        let parsed = LaunchArgumentParser.parse(profile.argumentsText)
        if let diagnostic = folder.diagnostic(in: parsed) {
          blockers.append(.profileConfiguration(applicationName: application.displayName,
            profileName: profile.name, problem: diagnostic.message))
          continue
        }
        guard let value = folder.resolve(in: parsed.words).value else { continue }
        let field: StorageRelocationIsolationField = folder == .firefoxProfile ? .firefoxProfile : .extensions
        if folder.ownership(in: profile.isolationOwnership) == .generated {
          let oldURL = folder.managedPath(in: sourcePaths).url
          let newURL = folder.managedPath(in: destinationPaths).url
          profile.argumentsText = try folder.setting(newURL.path, in: profile.argumentsText, includingNoRemote: false)
          profile.isolationOwnership[keyPath: folder.ownershipKeyPath] = .generated
          generated.append(StorageRelocationGeneratedRewrite(profileID: profile.id, field: field, oldURL: oldURL, newURL: newURL))
        } else {
          try recordConfiguredPath(value, field: field, profileID: profile.id)
        }
      }
      relocated.profiles[index] = profile
    }
    return (relocated, generated, external, blockers)
  }

  func dependentProfileBlockers(
    in applications: [ManagedApplication], moving application: ManagedApplication,
    source: ResolvedApplicationStoragePaths
  ) throws -> [StorageRelocationBlocker] {
    let roots = try [source.applicationRoot.url, source.applicationArchiveRoot.url].map {
      try pathResolver.resolveExternalPath($0.path).canonicalURL.pathComponents
    }
    var blockers: [StorageRelocationBlocker] = []
    for other in applications where other.id != application.id {
      for profile in other.profiles {
        let values: [(StorageRelocationIsolationField, String?)] = [
          (.userData, userDataValue(in: profile)),
          (.firefoxProfile, PresetIsolationFolder.firefoxProfile.resolve(in: profile.arguments).value),
          (.firefoxProfile, environmentValue("XRE_PROFILE_PATH", in: profile.environmentText)),
          (.extensions, PresetIsolationFolder.extensions.resolve(in: profile.arguments).value),
          (.codexHome, environmentValue("CODEX_HOME", in: profile.environmentText)),
          (.claudeConfig, environmentValue("CLAUDE_CONFIG_DIR", in: profile.environmentText))]
        for (field, value) in values {
          guard let value else { continue }
          let expanded = field.expanded(value, homeDirectory: homeDirectory.path)
          guard let path = try? pathResolver.resolveExternalPath(expanded).canonicalURL else { continue }
          if roots.contains(where: { isPrefix($0, of: path.pathComponents) }) {
            blockers.append(.dependentProfile(applicationName: other.displayName,
              profileName: profile.name, path: path.path))
          }
        }
      }
    }
    return blockers
  }

}
