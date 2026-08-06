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
    let stagedApplication = child("Application", in: destinationStaging)
    let stagedArchives = child("Archives", in: destinationStaging)
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
      try removePublishedIfUnchanged(
        destination.applicationRoot,
        expected: preview.sourceApplicationFingerprint
      )
      try removePublishedIfUnchanged(
        destination.applicationArchiveRoot,
        expected: preview.sourceArchiveFingerprint
      )
      try removePublishedIfUnchanged(
        stagedApplication,
        expected: preview.sourceApplicationFingerprint
      )
      try removePublishedIfUnchanged(
        stagedArchives,
        expected: preview.sourceArchiveFingerprint
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
    external: [StorageRelocationExternalPath]
  ) {
    var relocated = application
    relocated.baseStoragePath = destinationBaseRoot
    var generated: [StorageRelocationGeneratedRewrite] = []
    var external: [StorageRelocationExternalPath] = []

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
        external.append(
          StorageRelocationExternalPath(
            profileID: profile.id,
            field: .userData,
            value: userDataValue
          )
        )
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
        profile.environmentText = settingEnvironmentValue(
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
        external.append(
          StorageRelocationExternalPath(
            profileID: profile.id,
            field: .codexHome,
            value: codexHomeValue
          )
        )
      }
      relocated.profiles[index] = profile
    }
    return (relocated, generated, external)
  }

}
