import AppKit
import Foundation
import Observation

extension LibraryStore {
  func startOverAuthorization() -> StartOverAuthorization? {
    // Start over cannot clear an infrastructure failure, so the destructive
    // affordance must not be offered while one is holding recovery open.
    guard infrastructureFailureMessage == nil else { return nil }
    guard let bytes = failedPrimaryBytes else { return nil }
    return StartOverAuthorization(
      failedPrimarySHA256: LibraryPersistence.sha256(bytes)
    )
  }

  @discardableResult
  func restoreLatestVerifiedBackup() -> Bool {
    guard infrastructureFailureMessage == nil else {
      errorMessage = String(
        localized:
          "Parallax cannot restore a backup while a startup problem is blocking it. Quit and reopen Parallax, then try again."
      )
      return false
    }
    guard
      let backupStore,
      let libraryPrimaryURL,
      let expectedBytes = failedPrimaryBytes
    else {
      errorMessage = String(localized: "No failed library is available to restore.")
      return false
    }

    do {
      let restore = try backupStore.prepareLatestBackupRestore()
      _ = try backupStore.preparePrimaryRestore(
        from: restore.artifact,
        replacing: libraryPrimaryURL
      )
      try replaceFailedPrimary(
        expectedBytes: expectedBytes,
        targetBytes: restore.bytes
      )
      load()
      if case .loaded = loadState {
        publishLibraryChange()
        return true
      }
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  func exportRecoveryCopy() {
    guard
      let backupStore,
      failedPrimaryBytes != nil
    else {
      errorMessage = String(
        localized: "No failed library is available to export."
      )
      return
    }

    do {
      let artifact = try recoveryArtifactForCurrentFailure()
      let panel = NSSavePanel()
      panel.nameFieldStringValue = String(
        localized: "Parallax Recovery Library.json"
      )
      panel.allowedContentTypes = [.json]
      guard panel.runModal() == .OK, let destination = panel.url else {
        return
      }
      try backupStore.export(artifact, to: destination)
      launchStatusMessage = String(
        localized: "Exported a verified recovery copy."
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func revealRecoveryArtifacts() {
    guard
      backupStore != nil,
      failedPrimaryBytes != nil
    else {
      errorMessage = String(
        localized: "No failed library is available to inspect."
      )
      return
    }

    do {
      let artifact = try recoveryArtifactForCurrentFailure()
      NSWorkspace.shared.activateFileViewerSelecting([
        artifact.libraryURL
      ])
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func recoveryArtifactForCurrentFailure() throws
    -> LibraryRecoveryArtifact
  {
    guard
      let backupStore,
      let originalBytes = failedPrimaryBytes
    else {
      throw LibraryBackupStoreError.invalidArtifact
    }
    let expectedSHA256 = LibraryPersistence.sha256(originalBytes)
    if let exactQuarantine = try backupStore.inspectArtifacts(
      kind: .quarantine
    ).first(where: {
      $0.isVerified
        && $0.artifact.sha256 == expectedSHA256
        && $0.artifact.byteCount == originalBytes.count
    }) {
      return exactQuarantine.artifact
    }
    return try backupStore.quarantine(originalBytes)
  }

  @discardableResult
  func confirmStartOver(_ authorization: StartOverAuthorization) -> Bool {
    // Quarantining runs before the reload, so returning here is what keeps a
    // healthy library from being put aside for a failure it cannot resolve.
    guard infrastructureFailureMessage == nil else {
      errorMessage = String(
        localized:
          "Parallax cannot start over while a startup problem is blocking it. Quit and reopen Parallax, then try again."
      )
      return false
    }
    guard
      let backupStore,
      let libraryPrimaryURL,
      let expectedBytes = failedPrimaryBytes,
      LibraryPersistence.sha256(expectedBytes)
        == authorization.failedPrimarySHA256
    else {
      errorMessage = String(
        localized: "The failed library changed before start-over confirmation."
      )
      return false
    }

    do {
      let preparation = try backupStore.prepareQuarantineAndStartOver(
        primaryAt: libraryPrimaryURL
      )
      guard
        preparation.originalSHA256
          == authorization.failedPrimarySHA256
      else {
        throw LibraryRepositoryError.staleWriter(
          expected: LibraryVersionToken(
            revision: .initial,
            primarySHA256: authorization.failedPrimarySHA256
          ),
          actual: LibraryVersionToken(
            revision: .initial,
            primarySHA256: preparation.originalSHA256
          )
        )
      }
      try replaceFailedPrimary(
        expectedBytes: expectedBytes,
        targetBytes: preparation.emptyLibraryBytes
      )
      load()
      if case .loaded = loadState {
        publishLibraryChange()
        return true
      }
      return false
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  var selectedApplicationIndex: Int? {
    guard let selectedApplicationID else { return nil }
    return applications.firstIndex { $0.id == selectedApplicationID }
  }

  var failedPrimaryBytes: Data? {
    switch loadState {
    case .recoveryRequired(let bytes, _),
      .unsupportedNewerVersion(let bytes, _),
      .unrecoverable(let bytes, _):
      bytes
    case .loading, .loaded:
      nil
    }
  }

  func replaceFailedPrimary(
    expectedBytes: Data,
    targetBytes: Data
  ) throws {
    guard let libraryPrimaryURL else {
      throw CocoaError(.fileNoSuchFile)
    }
    _ = try LibraryPersistence.decodeCurrentDocument(from: targetBytes)
    let parent = libraryPrimaryURL.deletingLastPathComponent()
    let lock = LibraryAdvisoryLock(
      url: parent.appendingPathComponent(
        ".library.lock",
        isDirectory: false
      )
    )
    try lock.withExclusiveLock {
      guard try fileSystem.readData(at: libraryPrimaryURL) == expectedBytes else {
        throw LibraryRepositoryError.staleWriter(
          expected: LibraryVersionToken(
            revision: .initial,
            primarySHA256: LibraryPersistence.sha256(expectedBytes)
          ),
          actual: LibraryVersionToken(
            revision: .initial,
            primarySHA256: try? LibraryPersistence.sha256(
              fileSystem.readData(at: libraryPrimaryURL)
            )
          )
        )
      }
      let temporary = parent.appendingPathComponent(
        ".library.recovery-\(UUID().uuidString.lowercased()).tmp",
        isDirectory: false
      )
      do {
        try fileSystem.writeData(targetBytes, to: temporary)
        try fileSystem.setPOSIXPermissions(0o600, at: temporary)
        try fileSystem.synchronize(at: temporary)
        try fileSystem.replaceItem(
          at: libraryPrimaryURL,
          withItemAt: temporary
        )
        try fileSystem.synchronize(at: libraryPrimaryURL)
        try fileSystem.synchronize(at: parent)
      } catch {
        if fileSystem.fileExists(at: temporary) {
          try? fileSystem.removeItem(at: temporary)
        }
        throw error
      }
      guard try fileSystem.readData(at: libraryPrimaryURL) == targetBytes else {
        throw CocoaError(.fileReadCorruptFile)
      }
    }
  }

  func isDirectory(at url: URL) -> Bool {
    guard let attributes = try? fileSystem.attributesOfItem(at: url) else {
      return false
    }
    return attributes.kind == .directory
  }
}
