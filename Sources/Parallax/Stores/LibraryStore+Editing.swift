import AppKit
import Foundation
import Observation

// MARK: - Editing and destructive actions

extension LibraryStore {
  @discardableResult
  func applyApplicationEdit(
    draft: ManagedApplication,
    baseline: ManagedApplication,
    baselineVersion: LibraryVersionToken
  ) -> Bool {
    guard
      let latest = applications.first(where: {
        $0.id == baseline.id
      }),
      let currentVersion = libraryVersionToken
    else {
      errorMessage = String(
        localized:
          "The application no longer exists. Your draft was kept."
      )
      return false
    }
    let session = ManagedApplicationEditSession(
      application: baseline,
      libraryVersion: baselineVersion
    )
    session.draft = ManagedApplicationEditDraft(
      application: draft
    )
    if !session.dirtyFields.isEmpty {
      let validation = DisplayNameValidator.validate(
        session.draft.displayName
      )
      guard let normalizedName = validation.normalized else {
        errorMessage = validation.issue?.message(
          for: .application
        )
        return false
      }
      session.draft.displayName = normalizedName
    }
    let result = session.apply(
      to: latest,
      libraryVersion: currentVersion
    ) { [self] merged, expectedVersion in
      try persistApplicationEdit(
        merged,
        expectedVersion: expectedVersion
      )
    }
    return handleApplicationEditResult(result)
  }

  func presetChangePreview(
    for application: ManagedApplication,
    targetPreset: AppPreset
  ) -> PresetChangePreview? {
    do {
      let generatedPaths = try application.profiles.map { profile in
        let paths = try managedPaths(
          for: application,
          profile: profile
        )
        return PresetGeneratedPaths(
          profileID: profile.id,
          profileStorageID: profile.storageID,
          userDataDirectory: paths.userData.url.path,
          codexHome: paths.codexHome.url.path
        )
      }
      return try PresetChangePreviewService().preview(
        application: application,
        targetPreset: targetPreset,
        generatedPaths: generatedPaths
      )
    } catch {
      errorMessage = error.localizedDescription
      return nil
    }
  }

  @discardableResult
  func applyApplicationPresetEdit(
    draft: ManagedApplication,
    baseline: ManagedApplication,
    baselineVersion: LibraryVersionToken,
    preview: PresetChangePreview,
    refreshGeneratedValues: Bool
  ) -> Bool {
    guard
      let latest = applications.first(where: {
        $0.id == baseline.id
      }),
      let currentVersion = libraryVersionToken
    else {
      errorMessage = String(
        localized:
          "The application no longer exists. Your draft was kept."
      )
      return false
    }
    let session = ManagedApplicationEditSession(
      application: baseline,
      libraryVersion: baselineVersion
    )
    session.draft = ManagedApplicationEditDraft(
      application: draft
    )
    if !session.dirtyFields.isEmpty {
      let validation = DisplayNameValidator.validate(
        session.draft.displayName
      )
      guard let normalizedName = validation.normalized else {
        errorMessage = validation.issue?.message(
          for: .application
        )
        return false
      }
      session.draft.displayName = normalizedName
    }
    let service = PresetChangePreviewService()
    if refreshGeneratedValues, session.dirtyFields.isEmpty {
      do {
        let authorization = service.authorizeRefresh(
          preview,
          acknowledging:
            .applyListedGeneratedValueChanges
        )
        let final = try service.applyingAuthorizedRefresh(
          preview,
          authorization: authorization,
          to: latest
        )
        _ = try persistApplicationEdit(
          final,
          expectedVersion: currentVersion
        )
        errorMessage = nil
        return true
      } catch {
        errorMessage = error.localizedDescription
        return false
      }
    }
    let result = session.apply(
      to: latest,
      libraryVersion: currentVersion
    ) { [self] merged, expectedVersion in
      var source = merged
      source.preset = preview.sourcePreset
      let final: ManagedApplication
      if refreshGeneratedValues {
        let authorization = service.authorizeRefresh(
          preview,
          acknowledging:
            .applyListedGeneratedValueChanges
        )
        final = try service.applyingAuthorizedRefresh(
          preview,
          authorization: authorization,
          to: source
        )
      } else {
        final = try service.applyingPresetMetadata(
          preview,
          to: source
        )
      }
      return try persistApplicationEdit(
        final,
        expectedVersion: expectedVersion
      )
    }
    return handleApplicationEditResult(result)
  }

  @discardableResult
  func applyProfileEdit(
    draft: LaunchProfile,
    baseline: LaunchProfile,
    applicationID: UUID,
    baselineVersion: LibraryVersionToken
  ) -> Bool {
    guard
      let application = applications.first(where: {
        $0.id == applicationID
      }),
      let latest = application.profiles.first(where: {
        $0.id == baseline.id
      }),
      let currentVersion = libraryVersionToken
    else {
      errorMessage = String(
        localized:
          "The space no longer exists. Your draft was kept."
      )
      return false
    }
    let session = LaunchProfileEditSession(
      applicationID: applicationID,
      profile: baseline,
      libraryVersion: baselineVersion
    )
    session.draft = LaunchProfileEditDraft(profile: draft)
    if !session.dirtyFields.isEmpty {
      let validation = DisplayNameValidator.validate(
        session.draft.name
      )
      guard let normalizedName = validation.normalized else {
        errorMessage = validation.issue?.message(for: .space)
        return false
      }
      session.draft.name = normalizedName
    }
    let result = session.apply(
      to: latest,
      in: applicationID,
      libraryVersion: currentVersion
    ) { [self] merged, expectedVersion in
      try persistProfileEdit(
        merged,
        applicationID: applicationID,
        expectedVersion: expectedVersion
      )
    }
    return handleProfileEditResult(result)
  }

  var pendingImportConflictMessage: String? {
    guard let conflict = pendingImportConflict else { return nil }
    let importedName: String
    if let profileID = conflict.importedProfileID {
      importedName =
        pendingLibraryImport?.applications
        .flatMap(\.profiles)
        .first { $0.id == profileID }?.name
        ?? String(localized: "Imported profile")
    } else {
      importedName =
        pendingLibraryImport?.applications
        .first { $0.id == conflict.importedApplicationID }?
        .displayName
        ?? String(localized: "Imported application")
    }
    return String(
      localized:
        "“\(importedName)” conflicts with existing library content. Choose how to resolve this exact item."
    )
  }

  var pendingImportConflictTargets: [LibraryImportConflictTarget] {
    guard case .resolving(let session) = libraryImportFlowState else {
      return []
    }
    let conflict = session.conflict
    let projectedApplications = session.projectedApplications
    if conflict.scope == .application {
      return conflict.existingApplicationIDs.compactMap {
        applicationID in
        guard
          let application = projectedApplications.first(where: {
            $0.id == applicationID
          })
        else { return nil }
        return LibraryImportConflictTarget(
          applicationID: applicationID,
          profileID: nil,
          label: application.displayName
        )
      }
    }
    return conflict.existingProfileIDs.compactMap { profileID in
      for application in projectedApplications {
        if let profile = application.profiles.first(where: {
          $0.id == profileID
        }) {
          return LibraryImportConflictTarget(
            applicationID: application.id,
            profileID: profileID,
            label:
              "\(application.displayName) / \(profile.name)"
          )
        }
      }
      return nil
    }
  }

  var pendingImportConflictPrompt: LibraryImportConflictPrompt? {
    guard case .resolving(let session) = libraryImportFlowState else {
      return nil
    }
    return LibraryImportConflictPrompt(
      sessionID: session.preparedImport.sessionID,
      conflictID: session.conflict.id,
      message:
        pendingImportConflictMessage
        ?? String(
          localized:
            "Choose how to resolve this imported item."
        ),
      targets: pendingImportConflictTargets
    )
  }

  var canUndoLastImportReplacement: Bool {
    lastImportReplacement != nil
  }

  var importReplacementCoordinator: LibraryImportReplacementCoordinator? {
    guard let repository, let backupStore else { return nil }
    return LibraryImportReplacementCoordinator(
      repository: repository,
      backupStore: backupStore,
      validator: importValidator
    )
  }

  var selectedApplication: ManagedApplication? {
    guard let selectedApplicationID else { return nil }
    return applications.first { $0.id == selectedApplicationID }
  }

  var selectedProfile: LaunchProfile? {
    guard
      let application = selectedApplication,
      let selectedProfileID
    else {
      return nil
    }

    return application.profiles.first { $0.id == selectedProfileID }
  }

}
