import Darwin
import Foundation

// MARK: - Preparation and execution

extension StorageRelocationCoordinator {
  func prepare(
    application: ManagedApplication,
    destinationBaseRoot: String,
    expectedVersion: LibraryVersionToken
  ) throws -> StorageRelocationPreview {
    let source = try pathResolver.resolveApplication(
      configuredBaseRoot: configuredBaseRoot(for: application),
      applicationStorageID: application.storageID
    )
    let destination = try pathResolver.resolveApplication(
      configuredBaseRoot: destinationBaseRoot,
      applicationStorageID: application.storageID
    )
    let sourceEstimate = try estimateApplicationStorage(source)
    let destinationAvailableBytes = availableCapacity(
      at: destination.applicationRoot.validationContext.identityAnchorURL
    )
    let strategy: StorageRelocationStrategy =
      source.applicationRoot.validationContext.identityAnchor.volumeID
        == destination.applicationRoot.validationContext.identityAnchor.volumeID
      ? .sameVolume
      : .crossVolume
    let rewrite = try relocatedApplication(
      application,
      sourceBaseRoot: source.canonicalBaseRootURL.path,
      destinationBaseRoot: destination.canonicalBaseRootURL.path
    )

    var blockers: [StorageRelocationBlocker] = []
    if source.canonicalBaseRootURL.standardizedFileURL
      == destination.canonicalBaseRootURL.standardizedFileURL
    {
      blockers.append(.sameStorageLocation)
    }
    if pathsOverlap(
      source.applicationRoot.url,
      destination.applicationRoot.url
    )
      || pathsOverlap(
        source.applicationArchiveRoot.url,
        destination.applicationArchiveRoot.url
      )
    {
      blockers.append(.overlappingStorageLocations)
    }
    if fileSystem.fileExists(at: destination.applicationRoot.url)
      || fileSystem.fileExists(at: destination.applicationArchiveRoot.url)
    {
      blockers.append(.unexpectedDestination)
    }
    if sourceEstimate.allocatedBytes > 0 {
      if let destinationAvailableBytes {
        if destinationAvailableBytes < sourceEstimate.allocatedBytes {
          blockers.append(
            .insufficientSpace(
              required: sourceEstimate.allocatedBytes,
              available: destinationAvailableBytes
            )
          )
        }
      } else {
        blockers.append(.capacityUnavailable)
      }
    }
    let active = activeProfileIDs(in: application)
    if !active.isEmpty {
      blockers.append(.activeProfiles(active))
    }

    return StorageRelocationPreview(
      requestID: makeTransactionID(),
      applicationID: application.id,
      applicationStorageID: application.storageID,
      expectedVersion: expectedVersion,
      originalApplication: application,
      relocatedApplication: rewrite.application,
      source: source,
      destination: destination,
      sourceEstimate: sourceEstimate,
      sourceApplicationFingerprint: try fingerprintIfPresent(
        source.applicationRoot
      ),
      sourceArchiveFingerprint: try fingerprintIfPresent(
        source.applicationArchiveRoot
      ),
      sourceApplicationSnapshot: try ownedSnapshotIfPresent(
        source.applicationRoot
      ),
      sourceArchiveSnapshot: try ownedSnapshotIfPresent(
        source.applicationArchiveRoot
      ),
      destinationAvailableBytes: destinationAvailableBytes,
      strategy: strategy,
      generatedRewrites: rewrite.generated,
      preservedExternalPaths: rewrite.external,
      blockers: blockers
    )
  }

  func execute(
    _ preview: StorageRelocationPreview,
    preparedCommit: PreparedLibraryCommit,
    repository: any LibraryRepositoryPersisting,
    cancellation: StorageRelocationCancellation = StorageRelocationCancellation(),
    progress: ((StorageRelocationProgress) -> Void)? = nil
  ) throws -> StorageRelocationOutcome {
    guard preview.blockers.isEmpty else {
      throw StorageRelocationError(.blocked)
    }
    guard
      preparedCommit.priorVersion == preview.expectedVersion,
      preview.expectedVersion.revision.rawValue < UInt64.max,
      preparedCommit.targetVersion.revision.rawValue
        == preview.expectedVersion.revision.rawValue + 1,
      preparedCommit.targetVersion.primarySHA256
        == LibraryPersistence.sha256(preparedCommit.targetBytes)
    else {
      throw StorageRelocationError(.stalePreview)
    }
    guard activeProfileIDs(in: preview.originalApplication).isEmpty else {
      throw StorageRelocationError(.activeProfile)
    }
    try checkCancellation(cancellation)
    progress?(.preparing)
    let plan = try makeControlPlan(
      preview: preview,
      preparedCommit: preparedCommit
    )

    do {
      return try repository.withExclusiveMutation(
        expectedVersion: preview.expectedVersion
      ) { capability in
        let currentApplication = try validatePreparedTransition(
          preview: preview,
          preparedCommit: preparedCommit,
          currentApplications: capability.applications
        )
        guard activeProfileIDs(in: currentApplication).isEmpty else {
          throw StorageRelocationError(.activeProfile)
        }
        try checkCancellation(cancellation)

        let source = try pathResolver.resolveApplication(
          configuredBaseRoot: configuredBaseRoot(
            for: currentApplication
          ),
          applicationStorageID: currentApplication.storageID
        )
        let destination = try pathResolver.resolveApplication(
          configuredBaseRoot:
            preview.destination.canonicalBaseRootURL.path,
          applicationStorageID: currentApplication.storageID
        )
        guard
          source.applicationRoot.url
            == preview.source.applicationRoot.url,
          source.applicationArchiveRoot.url
            == preview.source.applicationArchiveRoot.url,
          destination.applicationRoot.url
            == preview.destination.applicationRoot.url,
          destination.applicationArchiveRoot.url
            == preview.destination.applicationArchiveRoot.url,
          try estimateApplicationStorage(source)
            == preview.sourceEstimate,
          try fingerprintIfPresent(source.applicationRoot)
            == preview.sourceApplicationFingerprint,
          try fingerprintIfPresent(source.applicationArchiveRoot)
            == preview.sourceArchiveFingerprint,
          try ownedSnapshotIfPresent(source.applicationRoot)
            == preview.sourceApplicationSnapshot,
          try ownedSnapshotIfPresent(
            source.applicationArchiveRoot
          ) == preview.sourceArchiveSnapshot
        else {
          throw StorageRelocationError(.sourceChanged)
        }
        try requireDestinationAbsent(destination)
        guard activeProfileIDs(in: currentApplication).isEmpty else {
          throw StorageRelocationError(.activeProfile)
        }
        try writeControlPlan(plan)
        do {
          try transactionBoundary?(
            .afterPlanDurable(preview.requestID)
          )
        } catch {
          throw StorageRelocationError(
            .rollbackRequired,
            path: controlURL(
              for: try controlPlanPath(preview.requestID)
            ).path,
            detail: error.localizedDescription
          )
        }

        let transactionID = preview.requestID
        let destinationStaging = destination.stagingRoot(
          transactionID: transactionID
        )
        let stagedApplication = child(
          "Application",
          in: destinationStaging
        )
        let stagedArchives = child(
          "Archives",
          in: destinationStaging
        )
        var applicationStaged = false
        var archivesStaged = false
        var applicationPublished = false
        var archivesPublished = false
        var commitState = LibraryCommitPrimaryState.prior

        do {
          try createDirectory(destinationStaging)

          if exists(source.applicationRoot) {
            progress?(.stagingApplication)
            try copy(
              source.applicationRoot,
              to: stagedApplication
            )
            applicationStaged = true
            try checkCancellation(cancellation)
          }
          if exists(source.applicationArchiveRoot) {
            progress?(.stagingArchives)
            try copy(
              source.applicationArchiveRoot,
              to: stagedArchives
            )
            archivesStaged = true
            try checkCancellation(cancellation)
          }
          try transactionBoundary?(
            .afterStaging(transactionID)
          )
          try checkCancellation(cancellation)

          if applicationStaged {
            try requireFingerprint(
              stagedApplication,
              expected: preview.sourceApplicationFingerprint
            )
            progress?(.publishingApplication)
            try move(
              stagedApplication,
              to: destination.applicationRoot
            )
            applicationPublished = true
            applicationStaged = false
          }
          if archivesStaged {
            try requireFingerprint(
              stagedArchives,
              expected: preview.sourceArchiveFingerprint
            )
            progress?(.publishingArchives)
            try move(
              stagedArchives,
              to: destination.applicationArchiveRoot
            )
            archivesPublished = true
            archivesStaged = false
          }
          try checkCancellation(cancellation)
          guard
            activeProfileIDs(in: currentApplication).isEmpty
          else {
            throw StorageRelocationError(.activeProfile)
          }

          progress?(.committingMetadata)
          guard
            try fingerprintIfPresent(source.applicationRoot)
              == preview.sourceApplicationFingerprint,
            try fingerprintIfPresent(
              source.applicationArchiveRoot
            ) == preview.sourceArchiveFingerprint
          else {
            throw StorageRelocationError(.sourceChanged)
          }
          do {
            let result = try capability.commit(
              preparedCommit,
              backupReason: .destructiveRewrite
            )
            commitState = result.primaryState
          } catch let repositoryError as LibraryRepositoryError {
            if case .commitFailed(let state, _) = repositoryError {
              commitState = state
            }
            throw repositoryError
          }
          guard commitState == .target else {
            throw StorageRelocationError(
              .metadataCommitFailed
            )
          }
          progress?(.cleaningSource)
          try removeOriginalOwned(
            source.applicationRoot,
            snapshot: preview.sourceApplicationSnapshot
          )
          try removeOriginalOwned(
            source.applicationArchiveRoot,
            snapshot: preview.sourceArchiveSnapshot
          )

          try removeIfPresent(destinationStaging)
          let receiptURL = try writeControlReceipt(
            plan: plan,
            completion: .committed
          )
          progress?(.completed)
          return StorageRelocationOutcome(
            transactionID: transactionID,
            application: preview.relocatedApplication,
            versionToken: preparedCommit.targetVersion,
            receiptURL: receiptURL
          )
        } catch {
          if commitState == .target {
            throw StorageRelocationError(
              .rollbackRequired,
              path: controlURL(
                for: try controlPlanPath(transactionID)
              ).path,
              detail: error.localizedDescription
            )
          }
          if commitState == .neither {
            throw StorageRelocationError(
              .ambiguousLibraryState,
              path: controlURL(
                for: try controlPlanPath(transactionID)
              ).path,
              detail: error.localizedDescription
            )
          }

          progress?(.rollingBack)
          do {
            if applicationPublished {
              try removePublishedIfUnchanged(
                destination.applicationRoot,
                expected:
                  preview.sourceApplicationFingerprint
              )
              applicationPublished = false
            }
            if archivesPublished {
              try removePublishedIfUnchanged(
                destination.applicationArchiveRoot,
                expected: preview.sourceArchiveFingerprint
              )
              archivesPublished = false
            }
            if applicationStaged {
              try removePublishedIfUnchanged(
                stagedApplication,
                expected:
                  preview.sourceApplicationFingerprint
              )
              applicationStaged = false
            }
            if archivesStaged {
              try removePublishedIfUnchanged(
                stagedArchives,
                expected: preview.sourceArchiveFingerprint
              )
              archivesStaged = false
            }
            try removeIfPresent(destinationStaging)
            _ = try writeControlReceipt(
              plan: plan,
              completion: .rolledBack
            )
          } catch let rollbackError {
            throw StorageRelocationError(
              .rollbackRequired,
              path: controlURL(
                for: try controlPlanPath(transactionID)
              ).path,
              detail: rollbackError.localizedDescription
            )
          }
          if error is LibraryRepositoryError {
            throw StorageRelocationError(
              .metadataCommitFailed,
              detail: error.localizedDescription
            )
          }
          throw error
        }
      }
    } catch LibraryRepositoryError.staleWriter {
      throw StorageRelocationError(.stalePreview)
    } catch LibraryRepositoryError.preparedVersionMismatch {
      throw StorageRelocationError(.stalePreview)
    } catch LibraryRepositoryError.mutationSessionExpired {
      throw StorageRelocationError(.stalePreview)
    } catch LibraryRepositoryError.mutationAlreadyPublished {
      throw StorageRelocationError(.stalePreview)
    }
  }

  func validatePreparedTransition(
    preview: StorageRelocationPreview,
    preparedCommit: PreparedLibraryCommit,
    currentApplications: [ManagedApplication]
  ) throws -> ManagedApplication {
    guard
      let index = currentApplications.firstIndex(where: {
        $0.id == preview.applicationID
      }),
      currentApplications.filter({
        $0.id == preview.applicationID
      }).count == 1,
      currentApplications[index] == preview.originalApplication,
      currentApplications[index].storageID
        == preview.applicationStorageID
    else {
      throw StorageRelocationError(.stalePreview)
    }
    var expectedApplications = currentApplications
    expectedApplications[index] = preview.relocatedApplication
    guard preparedCommit.applications == expectedApplications else {
      throw StorageRelocationError(.stalePreview)
    }
    return currentApplications[index]
  }

}
