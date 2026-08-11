import AppKit
import Foundation
import Observation

// MARK: - Import, export, and recovery

extension LibraryStore {
  func exportLibrary() {
    exportPortable(.libraryMetadata)
  }

  func exportPortable(_ kind: LibraryPortableExportKind) {
    var sensitivePolicy = SensitiveLiteralExportPolicy.omit
    if portableExportContainsSensitiveLiterals(kind: kind) {
      let alert = NSAlert()
      alert.alertStyle = .warning
      alert.messageText = String(
        localized:
          "Export plaintext sensitive environment values?"
      )
      alert.informativeText = String(
        localized:
          "This library contains environment values classified as sensitive. Choose whether to omit, redact, or explicitly include those literals. Keychain-backed secrets remain references."
      )
      alert.addButton(
        withTitle: String(localized: "Omit Sensitive Values")
      )
      alert.addButton(
        withTitle: String(localized: "Redact Sensitive Values")
      )
      alert.addButton(
        withTitle: String(localized: "Include Sensitive Values")
      )
      alert.addButton(withTitle: String(localized: "Cancel"))
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        sensitivePolicy = .omit
      case .alertSecondButtonReturn:
        sensitivePolicy = .redact
      case .alertThirdButtonReturn:
        sensitivePolicy =
          .includeAfterExplicitConfirmation
      default:
        return
      }
    }
    let panel = NSSavePanel()
    panel.nameFieldStringValue =
      switch kind {
      case .libraryMetadata:
        String(localized: "Parallax Library Metadata.json")
      case .settingsAndTemplates:
        String(
          localized:
            "Parallax Settings and Templates.json"
        )
      case .portableConfiguration:
        String(
          localized:
            "Parallax Portable Configuration.json"
        )
      }
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url else { return }

    do {
      let data = try portableExportData(
        kind: kind,
        sensitivePolicy: sensitivePolicy
      )
      try fileSystem.writeDataAtomically(data, to: url)
      launchStatusMessage =
        switch kind {
        case .libraryMetadata:
          String(localized: "Exported library metadata")
        case .settingsAndTemplates:
          String(localized: "Exported settings and templates")
        case .portableConfiguration:
          String(localized: "Exported portable configuration")
        }
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func portableExportData(
    kind: LibraryPortableExportKind,
    sensitivePolicy: SensitiveLiteralExportPolicy
  ) throws -> Data {
    let settingsSnapshot = PortableSettingsSnapshot(
      profileTemplates: settings.profileTemplates,
      defaultBaseStoragePath:
        settings.defaultBaseStoragePath,
      confirmBeforeLaunch:
        settings.confirmBeforeLaunch,
      appearance: settings.appearance
    )
    let library = LibraryDocument(
      applications: applications
    )
    return switch kind {
    case .libraryMetadata:
      try portableConfiguration.encode(
        portableConfiguration.makeLibraryMetadataExport(
          library: library,
          sensitiveLiteralPolicy: sensitivePolicy
        )
      )
    case .settingsAndTemplates:
      try portableConfiguration.encode(
        portableConfiguration
          .makeSettingsAndTemplatesExport(
            settings: settingsSnapshot,
            sensitiveLiteralPolicy:
              sensitivePolicy
          )
      )
    case .portableConfiguration:
      try portableConfiguration.encode(
        portableConfiguration
          .makePortableConfigurationExport(
            library: library,
            settings: settingsSnapshot,
            sensitiveLiteralPolicy:
              sensitivePolicy
          )
      )
    }
  }

  func portableExportContainsSensitiveLiterals(
    kind: LibraryPortableExportKind
  ) -> Bool {
    let includesLibrary = kind != .settingsAndTemplates
    let includesSettings = kind != .libraryMetadata
    return
      (includesLibrary
      && libraryExportContainsSensitiveLiterals())
      || (includesSettings
        && settings.profileTemplates.contains {
          Self.environmentContainsSensitiveLiterals(
            $0.environmentText,
            explicitSensitiveKeys: []
          )
        })
  }

  func libraryExportContainsSensitiveLiterals() -> Bool {
    applications.contains { application in
      application.profiles.contains { profile in
        Self.environmentContainsSensitiveLiterals(
          profile.environmentText,
          explicitSensitiveKeys:
            Set(profile.sensitiveEnvironmentKeys)
        )
      }
    }
  }

  static func environmentContainsSensitiveLiterals(
    _ environmentText: String,
    explicitSensitiveKeys: Set<String>
  ) -> Bool {
    let classifier = SensitiveEnvironmentKeyClassifier(
      explicitSensitiveKeys: explicitSensitiveKeys
    )
    return LaunchEnvironmentParser.parse(
      environmentText
    ).entries.contains { entry in
      guard
        case .set(let storedText) = entry.operation,
        classifier.isSensitive(entry.name),
        case .literal =
          StoredEnvironmentValue(storedText: storedText)
      else {
        return false
      }
      return true
    }
  }

  func libraryDocumentForExport(
    sensitivePolicy: LibraryExportSensitivePolicy
  ) -> LibraryDocument {
    guard sensitivePolicy != .include else {
      return LibraryDocument(applications: applications)
    }
    let exportedApplications = applications.map { application in
      var exported = application
      exported.profiles = application.profiles.map { profile in
        var exportedProfile = profile
        exportedProfile.environmentText =
          Self.exportEnvironmentText(
            profile,
            sensitivePolicy: sensitivePolicy
          )
        return exportedProfile
      }
      return exported
    }
    return LibraryDocument(applications: exportedApplications)
  }

  static func exportEnvironmentText(
    _ profile: LaunchProfile,
    sensitivePolicy: LibraryExportSensitivePolicy
  ) -> String {
    let classifier = SensitiveEnvironmentKeyClassifier(
      explicitSensitiveKeys:
        Set(profile.sensitiveEnvironmentKeys)
    )
    let replacements: [(range: NSRange, text: String)] =
      LaunchEnvironmentParser.parse(
        profile.environmentText
      ).entries.compactMap { entry in
        guard
          case .set(let storedText) = entry.operation,
          classifier.isSensitive(entry.name),
          case .literal =
            StoredEnvironmentValue(storedText: storedText)
        else {
          return nil
        }
        switch sensitivePolicy {
        case .include:
          return nil
        case .redact:
          guard let valueRange = entry.valueRange else {
            return nil
          }
          return (
            NSRange(
              location: valueRange.start.utf16Offset,
              length:
                valueRange.end.utf16Offset
                - valueRange.start.utf16Offset
            ),
            "<redacted>"
          )
        case .omit:
          return (
            NSRange(
              location: entry.range.start.utf16Offset,
              length:
                entry.range.end.utf16Offset
                - entry.range.start.utf16Offset
            ),
            "# Omitted sensitive value: \(entry.name)"
          )
        }
      }
    let result = NSMutableString(string: profile.environmentText)
    for replacement in replacements.sorted(by: {
      $0.range.location > $1.range.location
    }) {
      result.replaceCharacters(
        in: replacement.range,
        with: replacement.text
      )
    }
    return result as String
  }

  func importLibrary() {
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
    pendingLibraryImport = PendingLibraryImport(
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
    pendingImportResolutions = [:]
    pendingImportConflict = nil
    pendingImportSummary = LibraryImportSummary(
      applicationCount: importedApplications.count,
      profileCount: importedApplications.reduce(into: 0) {
        $0 += $1.profiles.count
      },
      warnings: warningMessages
    )
    isShowingImportConflictResolution = false
    isShowingImportChoice = true
    errorMessage = nil
    return true
  }

  func confirmImport(replacing: Bool) {
    guard canMutateLibrary() else { return }
    guard let pending = pendingLibraryImport else { return }
    isShowingImportChoice = false

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
        try continueMergeImport()
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
    target: LibraryImportConflictTarget? = nil
  ) {
    guard
      let pending = pendingLibraryImport,
      let conflict = pendingImportConflict
    else { return }
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
          pending: pending
        )
      case .skip:
        resolution = .skip
      }
      pendingImportResolutions[conflict.id] = resolution
      pendingImportConflict = nil
      isShowingImportConflictResolution = false
      try continueMergeImport()
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

  func startOverAuthorization() -> StartOverAuthorization? {
    guard let bytes = failedPrimaryBytes else { return nil }
    return StartOverAuthorization(
      failedPrimarySHA256: LibraryPersistence.sha256(bytes)
    )
  }

  @discardableResult
  func restoreLatestVerifiedBackup() -> Bool {
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
