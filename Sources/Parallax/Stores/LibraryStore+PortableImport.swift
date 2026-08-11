import AppKit
import Foundation
import Observation

extension LibraryStore {
  func importLibrary() {
    guard canMutateLibrary() else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK, let url = panel.url else { return }

    _ = prepareImport(at: url)
  }

  @discardableResult
  func prepareImport(at url: URL) -> Bool {
    do {
      let attributes = try fileSystem.attributesOfItem(at: url)
      guard
        attributes.kind == .regularFile,
        let size = attributes.size,
        size
          <= UInt64(
            LibraryImportLimits().maximumBytes
          )
      else {
        throw LibraryImportStoreError.invalidImportFile
      }
      let data = try fileSystem.readData(at: url)
      return prepareImport(data: data)
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }

  @discardableResult
  func prepareImport(data: Data) -> Bool {
    guard canMutateLibrary() else { return false }
    let decodedArtifact: DecodedLibraryImportArtifact
    do {
      decodedArtifact = try LibraryImportArtifactDecoder(
        validator: importValidator,
        portableConfiguration: portableConfiguration
      ).decode(data)
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
    let report = decodedArtifact.validation
    let portableWarning: String? =
      switch decodedArtifact.kind {
      case .portableLibraryMetadata:
        String(
          localized:
            "This metadata export excludes settings, profile data, application binaries, external data, and Keychain secret values."
        )
      case .portableConfiguration:
        String(
          localized:
            "This import applies library metadata only. Review and import settings separately; profile data and Keychain secret values are not included."
        )
      case .libraryDocument, nil:
        nil
      }
    guard
      report.isValid,
      let document = report.document
    else {
      errorMessage = report.issues
        .map { "\($0.path): \($0.message)" }
        .joined(separator: "\n")
      return false
    }
    var importedApplications = document.applications
    for applicationIndex in importedApplications.indices {
      for profileIndex in importedApplications[
        applicationIndex
      ].profiles.indices {
        importedApplications[applicationIndex]
          .profiles[profileIndex]
          .markLaunchConfigurationImported()
        importedApplications[applicationIndex]
          .profiles[profileIndex].lastLaunchedAt = nil
      }
    }
    var warningMessages = report.issues
      .filter { $0.severity == .warning }
      .map { "\($0.path): \($0.message)" }
    if let portableWarning {
      warningMessages.append(portableWarning)
    }
    let preparedImport = PreparedLibraryImport(
      sourceSHA256: LibraryPersistence.sha256(data),
      expectedVersion: libraryVersionToken,
      applications: importedApplications,
      canonicalApplications: importedApplications.map {
        LibraryImportApplication(
          application: $0,
          canonicalApplicationPath: URL(
            fileURLWithPath: $0.appPath
          ).standardizedFileURL.path
        )
      },
      warnings: warningMessages
    )
    libraryImportFlowState = .choosing(preparedImport)
    errorMessage = nil
    return true
  }

  func confirmImport(replacing: Bool) {
    guard case .choosing(let pending) = libraryImportFlowState else {
      return
    }
    guard canMutateLibrary() else { return }
    do {
      try validatePendingImportVersion(pending)
      if replacing {
        guard
          let coordinator = importReplacementCoordinator
        else {
          throw LibraryImportStoreError
            .replacementUnavailable
        }
        let data = try encodedImportApplications(
          pending.applications
        )
        let preview = try coordinator.preview(
          importData: data,
          expectedVersion: pending.expectedVersion
        )
        let result = try coordinator.replace(using: preview)
        applications = result.snapshot.applications
        libraryVersionToken = result.snapshot.versionToken
        selectedApplicationID = applications.first?.id
        selectedProfileID =
          applications.first?.profiles.first?.id
        loadState = .loaded
        lastImportReplacement = result
        publishLibraryChange()
        finishImport()
        launchStatusMessage = String(
          localized:
            "Replaced library metadata. Existing profile data was preserved."
        )
      } else {
        try continueMergeImport(pending, resolutions: [:])
      }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func cancelImport() {
    finishImport()
  }

  func resolvePendingImportConflict(
    _ choice: LibraryImportConflictChoice,
    target: LibraryImportConflictTarget? = nil,
    expectedPrompt: LibraryImportConflictPrompt? = nil
  ) {
    guard
      case .resolving(let session) = libraryImportFlowState
    else { return }
    if let expectedPrompt {
      guard
        expectedPrompt.sessionID == session.preparedImport.sessionID,
        expectedPrompt.conflictID == session.conflict.id
      else { return }
    }
    let pending = session.preparedImport
    let conflict = session.conflict
    do {
      try validatePendingImportVersion(pending)
      let resolution: LibraryImportConflictResolution
      switch choice {
      case .keepExisting:
        guard let target else {
          throw LibraryImportStoreError
            .conflictTargetRequired
        }
        resolution = .keepExisting(
          applicationID: target.applicationID,
          profileID: target.profileID
        )
      case .useImported:
        guard let target else {
          throw LibraryImportStoreError
            .conflictTargetRequired
        }
        resolution = .useImported(
          applicationID: target.applicationID,
          profileID: target.profileID
        )
      case .keepBoth:
        resolution = try keepBothResolution(
          for: conflict,
          pending: pending,
          resolutions: session.resolutions
        )
      case .skip:
        resolution = .skip
      }
      var resolutions = session.resolutions
      resolutions[conflict.id] = resolution
      try continueMergeImport(pending, resolutions: resolutions)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  @discardableResult
  func undoLastImportReplacement() -> Bool {
    guard
      let replacement = lastImportReplacement,
      let coordinator = importReplacementCoordinator
    else {
      errorMessage = String(
        localized:
          "No import replacement is available to undo."
      )
      return false
    }
    do {
      let result = try coordinator.undo(
        replacement: replacement
      )
      applications = result.snapshot.applications
      libraryVersionToken = result.snapshot.versionToken
      selectedApplicationID = applications.first?.id
      selectedProfileID = applications.first?.profiles.first?.id
      lastImportReplacement = nil
      publishLibraryChange()
      launchStatusMessage = String(
        localized:
          "Undid the library metadata replacement. Profile data was unchanged."
      )
      return true
    } catch {
      errorMessage = error.localizedDescription
      return false
    }
  }
}
